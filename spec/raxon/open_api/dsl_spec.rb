require "spec_helper"

RSpec.describe Raxon::OpenApi::DSL do
  describe ".component" do
    it "creates a new component" do
      component = nil
      described_class.component("Post", type: :object, description: "A blog post") do |c|
        component = c
      end

      expect(component).to be_a(Raxon::OpenApi::Component)
      expect(component.name).to eq("Post")
      expect(component.type).to eq("object")
      expect(component.description).to eq("A blog post")
    end

    it "adds the component to the components array" do
      described_class.component("Post", type: :object)
      expect(described_class.class_variable_get(:@@components)).to include(an_instance_of(Raxon::OpenApi::Component))
    end
  end

  describe ".endpoint" do
    it "creates a new endpoint" do
      endpoint = nil
      described_class.endpoint do |e|
        endpoint = e
      end

      expect(endpoint).to be_a(Raxon::OpenApi::Endpoint)
    end

    it "adds the endpoint to the endpoints array" do
      described_class.endpoint
      expect(described_class.class_variable_get(:@@endpoints)).to include(an_instance_of(Raxon::OpenApi::Endpoint))
    end
  end

  describe ".process_type" do
    it "converts symbol types to strings" do
      expect(described_class.process_type(:string)).to eq("string")
      expect(described_class.process_type(:number)).to eq("number")
      expect(described_class.process_type(:boolean)).to eq("boolean")
      expect(described_class.process_type(:object)).to eq("object")
      expect(described_class.process_type(:array)).to eq("array")
    end

    it "returns the type if it is unknown" do
      expect(described_class.process_type(:what_is_this)).to eq("what_is_this")
    end
  end

  describe ".status_to_code" do
    it "returns integers unchanged" do
      expect(described_class.status_to_code(200)).to eq(200)
      expect(described_class.status_to_code(404)).to eq(404)
      expect(described_class.status_to_code(500)).to eq(500)
    end

    it "converts symbol status codes to integers" do
      expect(described_class.status_to_code(:ok)).to eq(200)
      expect(described_class.status_to_code(:created)).to eq(201)
      expect(described_class.status_to_code(:not_found)).to eq(404)
      expect(described_class.status_to_code(:internal_server_error)).to eq(500)
      expect(described_class.status_to_code(:bad_request)).to eq(400)
    end

    it "raises ArgumentError for unknown symbol status codes" do
      expect { described_class.status_to_code(:unknown_status) }.to raise_error(ArgumentError, "Unknown status code symbol: unknown_status")
    end
  end

  describe ".to_open_api" do
    before do
      described_class.class_variable_set(:@@components, [])
      described_class.class_variable_set(:@@endpoints, [])
    end

    it "generates a valid OpenAPI specification" do
      described_class.component("Post", type: :object) do |post|
        post.property(:title, type: :string, description: "The title of the post")
        post.property(:content, type: :string, description: "The content of the post")
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/posts")
        endpoint.description("Fetches the list of posts")

        endpoint.parameters do |parameters|
          parameters.define(:filter, in: :query, type: :string, required: false)
        end

        endpoint.response(200, type: :array, of: "Post")
      end

      spec = described_class.to_open_api

      expect(spec).to include(
        "openapi" => "3.0.0",
        "info" => {
          "title" => "API",
          "description" => "",
          "version" => "1.0"
        }
      )

      expect(spec["paths"]).to include(
        "/api/v1/posts" => {
          "get" => {
            "parameters" => [
              {
                "name" => "filter",
                "in" => "query",
                "required" => false,
                "description" => "",
                "schema" => {
                  "type" => "string"
                }
              }
            ],
            "responses" => {
              "200" => {
                "description" => "",
                "headers" => {},
                "content" => {
                  "application/json" => {
                    "schema" => {
                      "type" => "array",
                      "items" => {
                        "$ref" => "#/components/schemas/Post"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      )

      expect(spec["components"]["schemas"]).to include(
        "Post" => {
          "description" => "",
          "type" => "object",
          "properties" => {
            "title" => {
              "type" => "string",
              "description" => "The title of the post"
            },
            "content" => {
              "type" => "string",
              "description" => "The content of the post"
            }
          },
          "required" => ["title", "content"]
        }
      )
    end

    it "includes allowable_values as enum in the OpenAPI specification" do
      described_class.component("Status", type: :object) do |status|
        status.property(:state, type: :string, description: "The current state", allowable_values: ["active", "inactive", "pending"])
      end

      spec = described_class.to_open_api

      expect(spec["components"]["schemas"]["Status"]["properties"]["state"]).to include(
        "type" => "string",
        "description" => "The current state",
        "enum" => ["active", "inactive", "pending"]
      )
    end

    it "creates requestBody using the request_body method and keeps regular parameters separate" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:post)
        endpoint.path("/api/v1/data")
        endpoint.description("Create data")

        endpoint.parameters do |parameters|
          parameters.define(:api_key, in: :header, type: :string, required: true)
        end

        endpoint.request_body type: :object, description: "Data to create", required: true do |body|
          body.property(:name, type: :string)
          body.property(:value, type: :number)
        end

        endpoint.response(201, type: :object)
      end

      spec = described_class.to_open_api

      post_operation = spec["paths"]["/api/v1/data"]["post"]
      parameters = post_operation["parameters"]
      request_body = post_operation["requestBody"]

      # Regular parameters should only include non-body params
      expect(parameters.length).to eq(1)
      expect(parameters[0]).to include(
        "name" => "api_key",
        "in" => "header",
        "required" => true
      )

      # Request body should be defined
      expect(request_body).not_to be_nil
      expect(request_body["required"]).to eq(true)
      expect(request_body["description"]).to eq("Data to create")
      expect(request_body["content"]["application/json"]["schema"]).to include(
        "type" => "object"
      )
      schema_properties = request_body["content"]["application/json"]["schema"]["properties"]
      expect(schema_properties["name"]).to include("type" => "string")
      expect(schema_properties["value"]).to include("type" => "number")
    end

    it "converts symbol status codes to numeric codes in OpenAPI output" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/items")

        endpoint.response(:ok, type: :object) do |response|
          response.property(:data, type: :string)
        end

        endpoint.response(:not_found, type: :object) do |response|
          response.property(:error, type: :string)
        end

        endpoint.response(:internal_server_error, type: :object) do |response|
          response.property(:error, type: :string)
        end
      end

      spec = described_class.to_open_api
      responses = spec["paths"]["/api/v1/items"]["get"]["responses"]

      expect(responses.keys).to contain_exactly("200", "404", "500")
      expect(responses).to have_key("200")
      expect(responses).to have_key("404")
      expect(responses).to have_key("500")
    end

    it "handles mixed symbol and integer status codes" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:post)
        endpoint.path("/api/v1/things")

        endpoint.response(:created, type: :object)
        endpoint.response(400, type: :object)
        endpoint.response(:unprocessable_entity, type: :object)
      end

      spec = described_class.to_open_api
      responses = spec["paths"]["/api/v1/things"]["post"]["responses"]

      expect(responses.keys).to contain_exactly("201", "400", "422")
    end

    it "generates $ref for object type with of: parameter" do
      described_class.component("Checklist", type: :object) do |c|
        c.property(:name, type: :string)
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/checklists/:id")

        endpoint.response(:ok, type: :object, of: "Checklist")
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/checklists/:id"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema).to eq({"$ref" => "#/components/schemas/Checklist"})
    end

    it "generates $ref for object type with as: parameter" do
      described_class.component("User", type: :object) do |c|
        c.property(:email, type: :string)
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/users/:id")

        endpoint.response(:ok, type: :object, as: "User")
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/users/:id"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema).to eq({"$ref" => "#/components/schemas/User"})
    end

    it "generates $ref for array type with of: parameter" do
      described_class.component("Task", type: :object) do |c|
        c.property(:title, type: :string)
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/tasks")

        endpoint.response(:ok, type: :array, of: "Task")
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/tasks"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema).to eq({
        "type" => "array",
        "items" => {"$ref" => "#/components/schemas/Task"}
      })
    end

    it "prefers as: over of: when both are provided for object type" do
      described_class.component("Primary", type: :object) do |c|
        c.property(:name, type: :string)
      end

      described_class.component("Secondary", type: :object) do |c|
        c.property(:name, type: :string)
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/items/:id")

        endpoint.response(:ok, type: :object, as: "Primary", of: "Secondary")
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/items/:id"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema).to eq({"$ref" => "#/components/schemas/Primary"})
    end
  end

  describe "Endpoint#response_schemas" do
    it "generates schemas for each response status code" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object do |response|
        response.property :status, type: :string, required: true
      end
      endpoint.response 404, type: :object do |response|
        response.property :error, type: :string, required: true
      end

      schemas = endpoint.response_schemas

      expect(schemas.keys).to contain_exactly(200, 404)
      expect(schemas[200]).to be_a(Dry::Schema::Params)
      expect(schemas[404]).to be_a(Dry::Schema::Params)
    end

    it "validates response body matches schema" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object do |response|
        response.property :status, type: :string, required: true
        response.property :id, type: :number, required: true
      end

      schema = endpoint.response_schemas[200]
      result = schema.call(status: "ok", id: "42")

      expect(result.success?).to be true
      expect(result.to_h).to eq({status: "ok", id: 42.0})
    end

    it "fails validation when required properties are missing" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object do |response|
        response.property :status, type: :string, required: true
      end

      schema = endpoint.response_schemas[200]
      result = schema.call({})

      expect(result.success?).to be false
      expect(result.errors.to_h).to have_key(:status)
    end

    it "returns empty hash when no responses have properties" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object

      schemas = endpoint.response_schemas

      expect(schemas).to eq({})
    end
  end

  describe "Endpoint#call with response validation" do
    let(:rack_request) { double("Rack::Request", request_method: "GET", path: "/test") }

    before do
      allow(rack_request).to receive(:params).and_return({})
      allow(rack_request).to receive(:body).and_return(StringIO.new("{}"))
      allow(rack_request).to receive(:content_type).and_return("application/json")
      allow(rack_request).to receive(:path_parameters).and_return({})
      allow(rack_request).to receive(:env).and_return({})
    end

    it "validates successful response body" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {status: "ok"}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      json_body = JSON.parse(body.first)
      expect(json_body).to eq({"status" => "ok"})
    end

    it "returns 500 when response validation fails" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :number, required: true
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {status: "ok"}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(500)
      json_body = JSON.parse(body.first)
      expect(json_body["error"]).to eq("Response validation failed")
      expect(json_body["status_code"]).to eq(200)
      expect(json_body["details"]).to have_key("id")
    end

    it "skips validation when no schema defined for status code" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {anything: "goes"}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      json_body = JSON.parse(body.first)
      expect(json_body).to eq({"anything" => "goes"})
    end

    it "validates nested object responses" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :data, type: :object, required: true do |data|
            data.property :name, type: :string, required: true
            data.property :count, type: :number, required: true
          end
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {
            status: "ok",
            data: {
              name: "Test",
              count: 42
            }
          }
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      json_body = JSON.parse(body.first)
      expect(json_body).to eq({
        "status" => "ok",
        "data" => {
          "name" => "Test",
          "count" => 42
        }
      })
    end

    it "fails validation when nested properties are missing" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :data, type: :object, required: true do |data|
            data.property :name, type: :string, required: true
          end
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {data: {}}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(500)
      json_body = JSON.parse(body.first)
      expect(json_body["error"]).to eq("Response validation failed")
    end
  end
end
