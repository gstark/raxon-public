# frozen_string_literal: true

require "spec_helper"

# Guards the structural validity of the generated document against the class of
# emitter bugs the review flagged (M-1..M-5): "type": null, "items": {"type":
# ""}, empty path keys, nullable siblings of $ref in 3.0, and content on a
# body-less response. A single generated document exercising every case is
# walked for those invariants, so any regression trips here.
RSpec.describe "Generated OpenAPI document validity" do
  before { Raxon::OpenApi::DSL.reset! }

  # Recursively collect every schema-shaped Hash reachable from the document.
  def each_schema(node, &block)
    case node
    when Hash
      block.call(node)
      node.each_value { |value| each_schema(value, &block) }
    when Array
      node.each { |value| each_schema(value, &block) }
    end
  end

  def build_document
    Raxon::OpenApi::DSL.component(:User, type: :object) do |user|
      user.property :id, type: :integer
      user.property :untyped, description: "no declared type" # M-1
    end

    Raxon::OpenApi::DSL.endpoint do |endpoint|
      endpoint.path "/users/{id}"
      endpoint.operation :get
      endpoint.response 200, type: :object, as: :User, nullable: true # M-4
      endpoint.response 204 # M-5 (body-less)
      endpoint.response 206, type: :array # M-2 (unspecified items)
    end

    # A multipart body: its schema must describe the form fields as an object,
    # not repeat the DSL-level "multipart" marker as a schema type.
    Raxon::OpenApi::DSL.endpoint do |endpoint|
      endpoint.path "/users/{id}/avatar"
      endpoint.operation :post
      endpoint.request_body(type: :multipart, required: true) do |body|
        body.property :avatar, type: :file, max_size: 1024
      end
      endpoint.response 201, type: :object
    end

    Raxon::OpenApi::DSL.to_open_api
  end

  # The complete set of JSON Schema types. Anything else in a "type" keyword is
  # not a schema a validator or client generator can act on.
  def json_schema_types
    %w[null boolean object array number string integer]
  end

  it "never emits a null or empty type" do
    doc = build_document

    each_schema(doc) do |schema|
      next unless schema.key?("type")

      expect(schema["type"]).not_to be_nil
      expect(schema["type"]).not_to eq("")
    end
  end

  it "only ever emits real JSON Schema types" do
    # The weaker "not nil, not empty" check above passed while every multipart
    # request body emitted "type": "multipart" — a Raxon-level marker for
    # selecting the media type, not a schema type. Assert against the actual
    # vocabulary so a DSL-level name cannot leak into the document again.
    doc = build_document

    each_schema(doc) do |schema|
      next unless schema.key?("type")

      Array(schema["type"]).each do |type|
        expect(json_schema_types).to include(type),
          "emitted #{type.inspect} as a schema type; valid types are #{json_schema_types.join(", ")}"
      end
    end
  end

  it "describes a multipart body as an object of form fields" do
    schema = build_document
      .dig("paths", "/users/{id}/avatar", "post", "requestBody", "content", "multipart/form-data", "schema")

    expect(schema["type"]).to eq("object")
    expect(schema["properties"]["avatar"]).to include("type" => "string", "format" => "binary")
  end

  it "never emits an empty path key" do
    doc = build_document

    expect(doc["paths"].keys).to all(satisfy { |path| !path.to_s.empty? })
  end

  it "emits an untyped property without a type key rather than type: null" do
    doc = build_document
    untyped = doc.dig("components", "schemas", "User", "properties", "untyped")

    expect(untyped).not_to have_key("type")
  end

  it "emits an unspecified array's items as an empty schema, not type: \"\"" do
    doc = build_document
    items = doc.dig("paths", "/users/{id}", "get", "responses", "206",
      "content", "application/json", "schema", "items")

    expect(items).to eq({})
  end

  it "omits the content object for a body-less response" do
    doc = build_document
    response = doc.dig("paths", "/users/{id}", "get", "responses", "204")

    expect(response).not_to have_key("content")
    expect(response).to include("description" => "No Content")
  end

  it "raises rather than emitting an operation under an empty path" do
    Raxon::OpenApi::DSL.endpoint do |endpoint|
      endpoint.operation :get
      endpoint.response 200, type: :object
    end

    expect { Raxon::OpenApi::DSL.to_open_api }
      .to raise_error(Raxon::OpenApi::Error, /has no path/)
  end

  describe "nullable component reference" do
    it "wraps the $ref in anyOf with a null branch in 3.1" do
      Raxon.configuration.openapi_spec_version = "3.1"
      schema = build_document.dig("paths", "/users/{id}", "get", "responses", "200",
        "content", "application/json", "schema")

      expect(schema).to eq(
        "anyOf" => [
          {"$ref" => "#/components/schemas/User"},
          {"type" => "null"}
        ]
      )
    end

    it "wraps the $ref in allOf with a sibling nullable in 3.0" do
      Raxon.configuration.openapi_spec_version = "3.0"
      schema = build_document.dig("paths", "/users/{id}", "get", "responses", "200",
        "content", "application/json", "schema")

      expect(schema).to eq(
        "allOf" => [{"$ref" => "#/components/schemas/User"}],
        "nullable" => true
      )
    end

    it "never leaves a $ref with a sibling nullable in either version" do
      %w[3.0 3.1].each do |version|
        Raxon::OpenApi::DSL.reset!
        Raxon.configuration.openapi_spec_version = version
        doc = build_document

        each_schema(doc) do |schema|
          next unless schema.key?("$ref")

          expect(schema.keys).to eq(["$ref"]),
            "expected a bare $ref in #{version}, got #{schema.keys.inspect}"
        end
      end
    end
  end
end
