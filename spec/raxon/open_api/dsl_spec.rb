require "spec_helper"

RSpec.describe Raxon::OpenApi::DSL do
  describe Raxon::OpenApi::Specification do
    it "keeps endpoints and components isolated between instances" do
      first_spec = described_class.new
      second_spec = described_class.new

      first_spec.component("User", type: :object) do |component|
        component.property :id, type: :integer
      end
      first_spec.endpoint do |endpoint|
        endpoint.path "/users"
        endpoint.operation :get
        endpoint.response 200, type: :object, as: "User"
      end

      second_spec.component("Post", type: :object) do |component|
        component.property :id, type: :integer
      end
      second_spec.endpoint do |endpoint|
        endpoint.path "/posts"
        endpoint.operation :get
        endpoint.response 200, type: :object, as: "Post"
      end

      first_openapi = first_spec.to_open_api
      second_openapi = second_spec.to_open_api

      expect(first_openapi["paths"].keys).to eq(["/users"])
      expect(first_openapi["components"]["schemas"].keys).to eq(["User"])
      expect(second_openapi["paths"].keys).to eq(["/posts"])
      expect(second_openapi["components"]["schemas"].keys).to eq(["Post"])
    end

    it "resets only that specification instance" do
      first_spec = described_class.new
      second_spec = described_class.new

      first_spec.component("User", type: :object)
      second_spec.component("Post", type: :object)

      first_spec.reset!

      expect(first_spec.components).to eq([])
      expect(second_spec.components.map(&:name)).to eq(["Post"])
    end
  end

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
      expect(described_class.components).to include(an_instance_of(Raxon::OpenApi::Component))
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
      expect(described_class.endpoints).to include(an_instance_of(Raxon::OpenApi::Endpoint))
    end
  end

  describe ".process_type" do
    it "converts symbol types to strings" do
      expect(described_class.process_type(:string)).to eq("string")
      expect(described_class.process_type(:number)).to eq("number")
      expect(described_class.process_type(:integer)).to eq("integer")
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
      described_class.reset!
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
            "description" => "Fetches the list of posts",
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

    it "outputs standard OpenAPI date and date-time formats" do
      described_class.component("Event", type: :object) do |event|
        event.property(:starts_at, type: :datetime)
        event.property(:birthday, type: :date)
        event.property(:legacy_at, type: "Dayjs")
        event.property(:published_at, type: :string, format: :date_time)
        event.property(:event_ids, type: :array, of: :uuid)
        event.property(:email_addresses, type: :array, of: :email)
      end

      spec = described_class.to_open_api
      properties = spec["components"]["schemas"]["Event"]["properties"]

      expect(properties["starts_at"]).to include("type" => "string", "format" => "date-time")
      expect(properties["birthday"]).to include("type" => "string", "format" => "date")
      expect(properties["legacy_at"]).to include("type" => "string", "format" => "date-time")
      expect(properties["published_at"]).to include("type" => "string", "format" => "date-time")
      expect(properties["event_ids"]["items"]).to include("type" => "string", "format" => "uuid")
      expect(properties["email_addresses"]["items"]).to include("type" => "string", "format" => "email")
    end

    it "maps database date/time columns to standard OpenAPI date formats" do
      timestamp_options = described_class.send(:build_property_options, "timestamp(6) without time zone", false, "Created at", false, nil)
      date_options = described_class.send(:build_property_options, "date", false, "Birthday", true, nil)
      timestamp_array_options = described_class.send(:build_property_options, "timestamp(6) without time zone", true, "Event times", false, nil)

      expect(timestamp_options).to include(type: :datetime, format: :date_time)
      expect(date_options).to include(type: :date, format: :date)
      expect(timestamp_array_options).to include(type: :array, of: :datetime)
    end

    it "maps database integer columns to integer OpenAPI type" do
      integer_options = described_class.send(:build_property_options, "integer", false, "ID", false, nil)
      bigint_array_options = described_class.send(:build_property_options, "bigint", true, "IDs", false, nil)
      numeric_options = described_class.send(:build_property_options, "numeric(10,2)", false, "Price", false, nil)

      expect(integer_options).to include(type: :integer)
      expect(bigint_array_options).to include(type: :array, of: :integer)
      expect(numeric_options).to include(type: :number)
    end

    it "includes schema metadata in the OpenAPI specification" do
      described_class.component("User", type: :object) do |user|
        user.property(:email, type: :string, format: :email, example: "user@example.com", default: "unknown@example.com", min_length: 3, max_length: 255, pattern: "^[^@]+@[^@]+$")
        user.property(:username, type: :string, pattern: /^[a-z]+$/)
        user.property(:age, type: :integer, minimum: 0, maximum: 130)
        user.property(:tags, type: :array, of: :string, min_items: 1, max_items: 5, unique_items: true)
        user.property(:scores, type: :array, of: :integer)
      end

      spec = described_class.to_open_api
      properties = spec["components"]["schemas"]["User"]["properties"]

      expect(properties["email"]).to include(
        "type" => "string",
        "format" => "email",
        "example" => "user@example.com",
        "default" => "unknown@example.com",
        "minLength" => 3,
        "maxLength" => 255,
        "pattern" => "^[^@]+@[^@]+$"
      )
      expect(properties["username"]).to include("pattern" => "^[a-z]+$")
      expect(properties["age"]).to include(
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 130
      )
      expect(properties["tags"]).to include(
        "minItems" => 1,
        "maxItems" => 5,
        "uniqueItems" => true
      )
      expect(properties["scores"]["items"]).to include("type" => "integer")
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

    it "includes operation metadata in the OpenAPI specification" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/posts")
        endpoint.summary("List posts")
        endpoint.description("Fetches posts")
        endpoint.operation_id("listPosts")
        endpoint.tags("Posts", "Public")
        endpoint.deprecated(true)
        endpoint.security(:api_key)

        endpoint.response(200, type: :array, of: :object)
      end

      spec = described_class.to_open_api
      operation = spec["paths"]["/api/v1/posts"]["get"]

      expect(operation).to include(
        "summary" => "List posts",
        "description" => "Fetches posts",
        "operationId" => "listPosts",
        "tags" => ["Posts", "Public"],
        "deprecated" => true,
        "security" => [{"api_key" => []}]
      )
    end

    it "omits unset optional operation metadata from the OpenAPI specification" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/posts")
        endpoint.response(200, type: :array, of: :object)
      end

      spec = described_class.to_open_api
      operation = spec["paths"]["/api/v1/posts"]["get"]

      expect(operation).not_to have_key("summary")
      expect(operation).not_to have_key("description")
      expect(operation).not_to have_key("operationId")
      expect(operation).not_to have_key("tags")
      expect(operation).not_to have_key("deprecated")
      expect(operation).not_to have_key("security")
    end

    it "includes standard error response helpers in the OpenAPI specification" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/users/{id}")
        endpoint.response(200, type: :object)
        endpoint.validation_error_response
        endpoint.unauthorized_response
        endpoint.not_found_response
        endpoint.error_response 500, description: "Server error"
      end

      spec = described_class.to_open_api
      responses = spec["paths"]["/api/v1/users/{id}"]["get"]["responses"]

      expect(responses.keys).to include("400", "401", "404", "500")
      expect(responses["400"]["description"]).to eq("Validation error")
      expect(responses["400"]["content"]["application/json"]["schema"]["properties"]).to include(
        "error" => include("type" => "string"),
        "details" => include("type" => "object")
      )
      expect(responses["401"]["description"]).to eq("Unauthorized")
      expect(responses["401"]["content"]["application/json"]["schema"]["properties"].keys).to eq(["error"])
      expect(responses["404"]["description"]).to eq("Not found")
      expect(responses["500"]["description"]).to eq("Server error")
    end

    it "includes endpoint parameter shorthands in the OpenAPI specification" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/users/{id}")

        endpoint.path_param :id, type: :string, description: "User ID"
        endpoint.query_param :include, type: :string, min_length: 3, max_length: 20, pattern: "^[a-z_]+$"
        endpoint.header_param :authorization, type: :string, required: true
        endpoint.cookie_param :session_id, type: :string

        endpoint.response(200, type: :object)
      end

      spec = described_class.to_open_api
      parameters = spec["paths"]["/api/v1/users/{id}"]["get"]["parameters"]

      expect(parameters).to include(
        include("name" => "id", "in" => "path", "required" => true, "description" => "User ID"),
        include(
          "name" => "include",
          "in" => "query",
          "required" => false,
          "schema" => include("minLength" => 3, "maxLength" => 20, "pattern" => "^[a-z_]+$")
        ),
        include("name" => "authorization", "in" => "header", "required" => true),
        include("name" => "session_id", "in" => "cookie", "required" => false)
      )
    end

    it "includes a parameter enum in the OpenAPI specification" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/files/{format}")
        endpoint.path_param :format, type: :string, enum: ["pdf", "png"], description: "File format"
        endpoint.response(200, type: :object)
      end

      spec = described_class.to_open_api
      parameter = spec["paths"]["/api/v1/files/{format}"]["get"]["parameters"].first

      expect(parameter["schema"]).to include("type" => "string", "enum" => ["pdf", "png"])
    end

    it "resolves a deferred (callable) parameter enum at OpenAPI generation time" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/files/{format}")
        endpoint.path_param :format, type: :string, enum: -> { ["docx", "html", "pdf", "png"] }
        endpoint.response(200, type: :object)
      end

      spec = described_class.to_open_api
      parameter = spec["paths"]["/api/v1/files/{format}"]["get"]["parameters"].first

      expect(parameter["schema"]).to include("enum" => ["docx", "html", "pdf", "png"])
    end

    it "resolves a deferred (callable) property enum at OpenAPI generation time" do
      described_class.component("Status", type: :object) do |status|
        status.property(:state, type: :string, enum: -> { ["active", "inactive"] })
      end

      spec = described_class.to_open_api

      expect(spec["components"]["schemas"]["Status"]["properties"]["state"]).to include(
        "enum" => ["active", "inactive"]
      )
    end

    it "creates requestBody using the body shorthand" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:post)
        endpoint.path("/api/v1/users")

        endpoint.body type: :object, description: "User data", required: true do |body|
          body.property(:name, type: :string)
        end

        endpoint.response(201, type: :object)
      end

      spec = described_class.to_open_api
      request_body = spec["paths"]["/api/v1/users"]["post"]["requestBody"]

      expect(request_body).not_to be_nil
      expect(request_body["required"]).to eq(true)
      expect(request_body["description"]).to eq("User data")
      expect(request_body["content"]["application/json"]["schema"]["properties"]).to include(
        "name" => include("type" => "string")
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

    it "creates multipart requestBody with OpenAPI binary file properties" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:post)
        endpoint.path("/api/v1/photos")

        endpoint.request_body type: :multipart, description: "Photo upload", required: true do |body|
          body.property(:photo, type: :file, description: "Photo file")
          body.property(:caption, type: :string, required: false)
        end

        endpoint.response(201, type: :object)
      end

      spec = described_class.to_open_api
      request_body = spec["paths"]["/api/v1/photos"]["post"]["requestBody"]

      expect(request_body["content"]).to have_key("multipart/form-data")
      expect(request_body["content"]).not_to have_key("application/json")

      schema = request_body["content"]["multipart/form-data"]["schema"]
      expect(schema["properties"]["photo"]).to include(
        "type" => "string",
        "format" => "binary",
        "description" => "Photo file"
      )
      expect(schema["properties"]["caption"]).to include("type" => "string")
    end

    it "keeps object request bodies as application/json" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:post)
        endpoint.path("/api/v1/widgets")

        endpoint.request_body type: :object, required: true do |body|
          body.property(:name, type: :string)
        end

        endpoint.response(201, type: :object)
      end

      spec = described_class.to_open_api
      request_body = spec["paths"]["/api/v1/widgets"]["post"]["requestBody"]

      expect(request_body["content"]).to have_key("application/json")
      expect(request_body["content"]).not_to have_key("multipart/form-data")
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

    it "generates array response with inline item properties" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/users")

        endpoint.response(:ok, type: :array) do |response|
          response.property(:id, type: :number)
          response.property(:name, type: :string)
        end
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/users"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["type"]).to eq("array")
      expect(response_schema["items"]["type"]).to eq("object")
      expect(response_schema["items"]["required"]).to eq(["id", "name"])
      expect(response_schema["items"]["properties"]["id"]["type"]).to eq("number")
      expect(response_schema["items"]["properties"]["name"]["type"]).to eq("string")
    end

    it "emits an array response enum on the items schema" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/states")

        endpoint.response(:ok, type: :array, of: :string, enum: %w[draft published archived])
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/states"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["type"]).to eq("array")
      expect(response_schema["items"]).to include("type" => "string", "enum" => %w[draft published archived])
    end

    it "resolves a deferred (callable) array response enum at OpenAPI generation time" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/formats")

        endpoint.response(:ok, type: :array, of: :string, enum: -> { %w[pdf png] })
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/formats"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["items"]).to include("enum" => %w[pdf png])
    end

    it "emits a custom response content_type as the content media-type key" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/export")

        endpoint.response(200, type: :string, content_type: "text/csv")
      end

      spec = described_class.to_open_api
      content = spec["paths"]["/api/v1/export"]["get"]["responses"]["200"]["content"]

      expect(content.keys).to eq(["text/csv"])
      expect(content["text/csv"]["schema"]).to include("type" => "string")
    end

    it "puts nullable on array schemas instead of array items" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/tags")

        endpoint.response(:ok, type: :array, of: :string, nullable: true)
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/tags"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["nullable"]).to eq(true)
      expect(response_schema["items"]).to eq({"type" => "string"})
    end

    it "puts nullable on component-backed array schemas" do
      described_class.component("User", type: :object) do |component|
        component.property(:id, type: :number)
      end

      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/component-users")

        endpoint.response(:ok, type: :array, as: :User, nullable: true)
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/component-users"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["nullable"]).to eq(true)
      expect(response_schema["items"]).to eq({"$ref" => "#/components/schemas/User"})
    end

    it "puts nullable on inline array response schemas instead of inline item schemas" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/nullable-users")

        endpoint.response(:ok, type: :array, nullable: true) do |response|
          response.property(:id, type: :number)
        end
      end

      spec = described_class.to_open_api
      response_schema = spec["paths"]["/api/v1/nullable-users"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(response_schema["nullable"]).to eq(true)
      expect(response_schema["items"]).not_to have_key("nullable")
      expect(response_schema["items"]["type"]).to eq("object")
    end

    it "puts an array-property enum on the items schema instead of the array schema" do
      described_class.component("Artifact", type: :object) do |component|
        component.property(:rendition_formats, type: :array, of: :string, enum: %w[pdf png webp])
      end

      spec = described_class.to_open_api
      formats = spec["components"]["schemas"]["Artifact"]["properties"]["rendition_formats"]

      expect(formats["type"]).to eq("array")
      expect(formats).not_to have_key("enum")
      expect(formats["items"]).to eq({"type" => "string", "enum" => %w[pdf png webp]})
    end

    it "resolves a deferred (callable) array-property enum on read" do
      formats = %w[pdf png]

      described_class.component("Artifact", type: :object) do |component|
        component.property(:rendition_formats, type: :array, of: :string, enum: -> { formats })
      end

      spec = described_class.to_open_api
      items = spec["components"]["schemas"]["Artifact"]["properties"]["rendition_formats"]["items"]

      expect(items).to eq({"type" => "string", "enum" => %w[pdf png]})
    end

    it "puts an array-parameter enum on the items schema" do
      described_class.endpoint do |endpoint|
        endpoint.operation(:get)
        endpoint.path("/api/v1/renditions")
        endpoint.query_param(:formats, type: :array, of: :string, enum: %w[pdf png])
        endpoint.response(200, type: :object)
      end

      spec = described_class.to_open_api
      schema = spec["paths"]["/api/v1/renditions"]["get"]["parameters"].first["schema"]

      expect(schema["type"]).to eq("array")
      expect(schema).not_to have_key("enum")
      expect(schema["items"]).to eq({"type" => "string", "enum" => %w[pdf png]})
    end

    it "omits enum on component-backed array items where a sibling enum would be invalid" do
      described_class.component("Task", type: :object) do |c|
        c.property(:title, type: :string)
      end

      described_class.component("TaskList", type: :object) do |component|
        component.property(:tasks, type: :array, of: "Task", enum: %w[a b])
      end

      spec = described_class.to_open_api
      items = spec["components"]["schemas"]["TaskList"]["properties"]["tasks"]["items"]

      expect(items).to eq({"$ref" => "#/components/schemas/Task"})
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
      expect(schemas[200]).to respond_to(:call)
      expect(schemas[404]).to respond_to(:call)
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

    it "generates schema for array responses with inline item properties" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :array do |response|
        response.property :id, type: :number, required: true
        response.property :name, type: :string, required: true
      end

      schema = endpoint.response_schemas[200]
      result = schema.call([{id: "1", name: "Alice"}])

      expect(result.success?).to be true
      expect(result.to_h).to eq([{id: 1.0, name: "Alice"}])
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
      define_route("routes/test/get.rb") do |endpoint|
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
      define_route("routes/test/get.rb") do |endpoint|
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

    it "hides response validation details when configured" do
      Raxon.configure { |config| config.expose_validation_details = false }

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      status, _, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))

      expect(status).to eq(500)
      json_body = JSON.parse(body.first)
      expect(json_body["error"]).to eq("Response validation failed")
      expect(json_body).not_to have_key("details")
    end

    it "skips response validation when configured false" do
      Raxon.configure { |config| config.response_validation = false }

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      status, _, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq("status" => "ok")
    end

    it "logs response validation failures without exposing them when configured to log" do
      Raxon.configure do |config|
        config.response_validation = :log
        config.expose_validation_details = false
      end

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      expect {
        status, _, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))
        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq("status" => "ok")
      }.to output(/Response validation failed/).to_stderr
    end

    it "raises response validation failures when configured to raise" do
      Raxon.configure { |config| config.response_validation = :raise }

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      expect {
        Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))
      }.to raise_error(Raxon::ResponseValidationError, /Response validation failed/)
    end

    it "allows endpoints to disable response validation" do
      define_route("routes/test/get.rb") do |endpoint|
        endpoint.validate_response false
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      status, _, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq("status" => "ok")
    end

    it "allows endpoints to force response validation when global validation is disabled" do
      Raxon.configure { |config| config.response_validation = false }

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.validate_response true
        endpoint.response 200, type: :object do |response|
          response.property :status, type: :string, required: true
          response.property :id, type: :integer, required: true
        end

        endpoint.handler do |_request, response|
          response.ok(status: "ok")
        end
      end

      status, _, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/test"))

      expect(status).to eq(500)
      expect(JSON.parse(body.first)["error"]).to eq("Response validation failed")
    end

    it "skips validation when no schema defined for status code" do
      define_route("routes/test/get.rb") do |endpoint|
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
      define_route("routes/test/get.rb") do |endpoint|
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

    it "validates array responses with inline item properties" do
      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :array do |response|
          response.property :id, type: :number, required: true
          response.property :name, type: :string, required: true
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = [{id: 1, name: "Alice"}, {id: 2, name: "Bob"}]
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      json_body = JSON.parse(body.first)
      expect(json_body).to eq([
        {"id" => 1, "name" => "Alice"},
        {"id" => 2, "name" => "Bob"}
      ])
    end

    it "returns 500 when array response item validation fails" do
      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response 200, type: :array do |response|
          response.property :id, type: :number, required: true
          response.property :name, type: :string, required: true
        end

        endpoint.handler do |request, response|
          response.code = :ok
          response.body = [{id: 1, name: "Alice"}, {id: 2}]
        end
      end

      env = Rack::MockRequest.env_for("/test")
      status, _, body = Raxon::Router.new.call(env)

      expect(status).to eq(500)
      json_body = JSON.parse(body.first)
      expect(json_body["error"]).to eq("Response validation failed")
      expect(json_body["details"]).to have_key("1")
      expect(json_body["details"]["1"]).to have_key("name")
    end

    it "fails validation when nested properties are missing" do
      define_route("routes/test/get.rb") do |endpoint|
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
