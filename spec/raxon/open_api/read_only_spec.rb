# frozen_string_literal: true

require "spec_helper"

RSpec.describe "read_only emission" do
  it "emits readOnly: true on a component property schema" do
    Raxon::OpenApi::DSL.component(:User, type: :object) do |c|
      c.property :id, type: :integer, read_only: true
      c.property :name, type: :string
    end
    Raxon::OpenApi::DSL.endpoint do |e|
      e.path "/users"
      e.operation :get
      e.response 200, type: :object, as: :User
    end

    schema = Raxon::OpenApi::DSL.to_open_api.dig("components", "schemas", "User", "properties")

    expect(schema.dig("id", "readOnly")).to be(true)
    expect(schema["name"]).not_to have_key("readOnly")
  end

  it "keeps an as: request body as a $ref in the document" do
    Raxon::OpenApi::DSL.component(:User, type: :object) do |c|
      c.property :name, type: :string
    end
    endpoint = Raxon::OpenApi::DSL.endpoint do |e|
      e.path "/users"
      e.operation :post
      e.request_body type: :object, as: "User"
      e.response 201, type: :object, as: :User
    end

    # Compiling the runtime schema resolves a copy; the document must still
    # reference the component.
    endpoint.request_schema

    body_schema = Raxon::OpenApi::DSL.to_open_api
      .dig("paths", "/users", "post", "requestBody", "content", "application/json", "schema")

    expect(body_schema).to eq({"$ref" => "#/components/schemas/User"})
  end

  it "emits readOnly on inline request body properties while stripping them at runtime" do
    endpoint = Raxon::OpenApi::DSL.endpoint do |e|
      e.path "/things"
      e.operation :post
      e.request_body type: :object do |body|
        body.property :name, type: :string
        body.property :created_at, type: :datetime, read_only: true
      end
      e.response 201, type: :object
    end

    body_schema = Raxon::OpenApi::DSL.to_open_api
      .dig("paths", "/things", "post", "requestBody", "content", "application/json", "schema")

    expect(body_schema.dig("properties", "created_at", "readOnly")).to be(true)
    expect(endpoint.resolved_request_body.properties.keys).to eq([:name])
    expect(endpoint.resolved_request_body.read_only_keys).to eq([:created_at])
  end
end
