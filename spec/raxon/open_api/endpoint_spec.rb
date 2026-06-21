require "spec_helper"

RSpec.describe Raxon::OpenApi::Endpoint do
  describe "#path" do
    it "sets the path" do
      endpoint = described_class.new
      endpoint.path("/api/v1/posts")
      expect(endpoint.path).to eq("/api/v1/posts")
    end
  end

  describe "#operation" do
    it "adds a single operation" do
      endpoint = described_class.new
      endpoint.operation(:get)
      endpoint.operation(:get)
      expect(endpoint.operations).to eq([:get])
    end

    it "adds multiple operations" do
      endpoint = described_class.new
      endpoint.operation([:get, :post])
      expect(endpoint.operations).to eq([:get, :post])
    end
  end

  describe "#description" do
    it "sets the description" do
      endpoint = described_class.new
      endpoint.description("Fetches the list of posts")
      expect(endpoint.description).to eq("Fetches the list of posts")
    end
  end

  describe "operation metadata" do
    it "sets summary" do
      endpoint = described_class.new
      endpoint.summary("List posts")
      expect(endpoint.summary).to eq("List posts")
    end

    it "sets operation_id" do
      endpoint = described_class.new
      endpoint.operation_id("listPosts")
      expect(endpoint.operation_id).to eq("listPosts")
    end

    it "sets tags from varargs" do
      endpoint = described_class.new
      endpoint.tags("Posts", "Public")
      expect(endpoint.tags).to eq(["Posts", "Public"])
    end

    it "sets tags from an array" do
      endpoint = described_class.new
      endpoint.tags(["Posts", "Public"])
      expect(endpoint.tags).to eq(["Posts", "Public"])
    end

    it "sets deprecated flag" do
      endpoint = described_class.new
      endpoint.deprecated(true)
      expect(endpoint.deprecated).to be(true)
    end

    it "defaults deprecated to false" do
      endpoint = described_class.new
      expect(endpoint.deprecated).to be(false)
    end

    it "sets security from a scheme name" do
      endpoint = described_class.new
      endpoint.security(:api_key)
      expect(endpoint.security).to eq([{api_key: []}])
    end

    it "sets security from a scheme name with scopes" do
      endpoint = described_class.new
      endpoint.security(:oauth2, scopes: ["read:posts"])
      expect(endpoint.security).to eq([{oauth2: ["read:posts"]}])
    end

    it "sets security from an explicit OpenAPI security requirement array" do
      endpoint = described_class.new
      requirements = [{api_key: []}, {oauth2: ["read"]}]
      endpoint.security(requirements)
      expect(endpoint.security).to eq(requirements)
    end
  end

  describe "#parameters" do
    it "yields the parameters object" do
      endpoint = described_class.new
      expect { |b| endpoint.parameters(&b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Parameters))
    end
  end

  describe "parameter shorthands" do
    it "defines a required path parameter" do
      endpoint = described_class.new

      result = endpoint.path_param :id, type: :string, description: "User ID"

      parameter = endpoint.parameters.parameters.first
      expect(result).to eq(parameter)
      expect(parameter.name).to eq(:id)
      expect(parameter.type).to eq("string")
      expect(parameter.in).to eq(:path)
      expect(parameter.required).to be(true)
      expect(parameter.description).to eq("User ID")
    end

    it "allows path parameter required to be overridden" do
      endpoint = described_class.new

      endpoint.path_param :id, type: :string, required: false

      expect(endpoint.parameters.parameters.first.required).to be(false)
    end

    it "defines an optional query parameter by default" do
      endpoint = described_class.new

      endpoint.query_param :page, type: :number

      parameter = endpoint.parameters.parameters.first
      expect(parameter.name).to eq(:page)
      expect(parameter.in).to eq(:query)
      expect(parameter.required).to be(false)
      expect(parameter.type).to eq("number")
    end

    it "allows query parameters to be required" do
      endpoint = described_class.new

      endpoint.query_param :search, type: :string, required: true

      expect(endpoint.parameters.parameters.first.required).to be(true)
    end

    it "defines an optional header parameter by default" do
      endpoint = described_class.new

      endpoint.header_param :authorization, type: :string

      parameter = endpoint.parameters.parameters.first
      expect(parameter.name).to eq(:authorization)
      expect(parameter.in).to eq(:header)
      expect(parameter.required).to be(false)
    end

    it "defines an optional cookie parameter by default" do
      endpoint = described_class.new

      endpoint.cookie_param :session_id, type: :string

      parameter = endpoint.parameters.parameters.first
      expect(parameter.name).to eq(:session_id)
      expect(parameter.in).to eq(:cookie)
      expect(parameter.required).to be(false)
    end

    it "yields the created parameter for nested property definitions" do
      endpoint = described_class.new

      endpoint.query_param :filter, type: :object do |filter|
        filter.property :active, type: :boolean
      end

      parameter = endpoint.parameters.parameters.first
      expect(parameter.properties).to include(:active)
    end
  end

  describe "#body" do
    it "aliases request_body definition" do
      endpoint = described_class.new

      endpoint.body type: :object, description: "User data" do |body|
        body.property :name, type: :string
      end

      expect(endpoint.request_body).to be_a(Raxon::OpenApi::RequestBody)
      expect(endpoint.request_body.description).to eq("User data")
      expect(endpoint.request_body.properties).to include(:name)
    end

    it "returns the request body when called without arguments" do
      endpoint = described_class.new
      endpoint.request_body type: :object

      expect(endpoint.body).to eq(endpoint.request_body)
    end

    it "invalidates the memoized request schema when request body changes" do
      endpoint = described_class.new
      endpoint.query_param :name, type: :string, required: true
      expect(endpoint.request_schema.call(name: "Ada")).to be_success

      endpoint.request_body type: :object do |body|
        body.property :age, type: :integer
      end

      result = endpoint.request_schema.call(name: "Ada")
      expect(result.errors.to_h).to include(:age)
    end
  end

  describe "#response" do
    it "adds a response with options" do
      endpoint = described_class.new
      endpoint.response(200, type: :array, of: "Post")
      expect(endpoint.responses[200]).to be_a(Raxon::OpenApi::Response)
      expect(endpoint.responses[200].type).to eq("array")
      expect(endpoint.responses[200].of).to eq("Post")
    end

    it "yields the response object" do
      endpoint = described_class.new
      expect { |b| endpoint.response(200, type: :object, &b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Response))
    end

    it "invalidates the memoized response schemas when responses change" do
      endpoint = described_class.new
      expect(endpoint.response_schemas).to eq({})

      endpoint.response 200, type: :object do |response|
        response.property :success, type: :boolean
      end

      expect(endpoint.response_schemas).to include(200)
    end
  end

  describe "#exception_error" do
    it "adds a standard error response with default status" do
      endpoint = described_class.new
      endpoint.exception_error

      response = endpoint.responses[:unprocessable_entity]
      expect(response).to be_a(Raxon::OpenApi::Response)
      expect(response.type).to eq("object")
      expect(response.description).to eq("Validation error")
      expect(response.properties.keys).to contain_exactly(:status, :error_message, :errors)
    end

    it "accepts custom status code" do
      endpoint = described_class.new
      endpoint.exception_error :bad_request

      expect(endpoint.responses[:bad_request]).to be_a(Raxon::OpenApi::Response)
      expect(endpoint.responses[:unprocessable_entity]).to be_nil
    end

    it "accepts custom description" do
      endpoint = described_class.new
      endpoint.exception_error description: "Invalid request format"

      response = endpoint.responses[:unprocessable_entity]
      expect(response.description).to eq("Invalid request format")
    end
  end

  describe "standard error response helpers" do
    it "adds a validation error response" do
      endpoint = described_class.new

      result = endpoint.validation_error_response

      response = endpoint.responses[400]
      expect(result).to eq(response)
      expect(response.description).to eq("Validation error")
      expect(response.properties.keys).to contain_exactly(:error, :details)
      expect(response.properties[:error].type).to eq("string")
      expect(response.properties[:details].type).to eq("object")
      expect(response.properties[:details].required).to be(false)
    end

    it "adds an unauthorized response" do
      endpoint = described_class.new

      response = endpoint.unauthorized_response

      expect(endpoint.responses[401]).to eq(response)
      expect(response.description).to eq("Unauthorized")
      expect(response.properties.keys).to contain_exactly(:error)
    end

    it "adds a not found response" do
      endpoint = described_class.new

      response = endpoint.not_found_response

      expect(endpoint.responses[404]).to eq(response)
      expect(response.description).to eq("Not found")
      expect(response.properties.keys).to contain_exactly(:error)
    end

    it "adds a generic error response with default status" do
      endpoint = described_class.new

      response = endpoint.error_response

      expect(endpoint.responses[500]).to eq(response)
      expect(response.description).to eq("Error")
      expect(response.properties.keys).to contain_exactly(:error, :details)
      expect(response.properties[:details].required).to be(false)
    end

    it "adds a generic error response with custom status and description" do
      endpoint = described_class.new

      response = endpoint.error_response 418, description: "Teapot error"

      expect(endpoint.responses[418]).to eq(response)
      expect(response.description).to eq("Teapot error")
    end

    it "allows customizing standard error response properties with a block" do
      endpoint = described_class.new

      response = endpoint.error_response 409 do |resp|
        resp.property :code, type: :string, required: false
      end

      expect(response.properties).to include(:error, :details, :code)
      expect(response.properties[:code].type).to eq("string")
    end
  end

  describe "#before" do
    it "stores the before block in the before_blocks array" do
      endpoint = described_class.new
      block = proc { |request, response| response.header "X-Test", "value" }
      endpoint.before(&block)
      expect(endpoint.before_blocks).to eq([block])
    end

    it "allows multiple before blocks to be added" do
      endpoint = described_class.new
      block1 = proc { |request, response| response.header "X-First", "1" }
      block2 = proc { |request, response| response.header "X-Second", "2" }
      endpoint.before(&block1)
      endpoint.before(&block2)
      expect(endpoint.before_blocks).to eq([block1, block2])
    end

    it "executes the before block before the handler" do
      call_order = []

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response(200, type: :object)
        endpoint.before do |request, response|
          call_order << :before
        end
        endpoint.handler do |request, response|
          call_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      Raxon::Router.new.call(env)

      expect(call_order).to eq([:before, :handler])
    end

    it "allows the before block to access the request" do
      define_route("routes/test/get.rb") do |endpoint|
        endpoint.operation(:get)
        endpoint.before do |request, response|
          response.rack_response["X-Method"] = request.method
        end
        endpoint.handler do |request, response|
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      _status, headers, _body = Raxon::Router.new.call(env)

      expect(headers["X-Method"]).to eq("GET")
    end

    it "executes multiple before blocks in the order they were defined" do
      execution_order = []

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.operation(:get)
        endpoint.before do |request, response|
          execution_order << :first
          response.rack_response["X-First"] = "1"
        end
        endpoint.before do |request, response|
          execution_order << :second
          response.rack_response["X-Second"] = "2"
        end
        endpoint.before do |request, response|
          execution_order << :third
          response.rack_response["X-Third"] = "3"
        end
        endpoint.handler do |request, response|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      _status, headers, _body = Raxon::Router.new.call(env)

      expect(execution_order).to eq([:first, :second, :third, :handler])
      expect(headers["X-First"]).to eq("1")
      expect(headers["X-Second"]).to eq("2")
      expect(headers["X-Third"]).to eq("3")
    end
  end

  describe "#has_before?" do
    it "returns true if endpoint has a before block" do
      endpoint = described_class.new
      endpoint.before do |request, response|
        response.header "X-Test", "value"
      end

      expect(endpoint.has_before?).to be true
    end

    it "returns false if endpoint does not have a before block" do
      endpoint = described_class.new
      expect(endpoint.has_before?).to be false
    end
  end

  describe "#after" do
    it "stores the after block in the after_blocks array" do
      endpoint = described_class.new
      block = proc { |request, response| response.header "X-Test", "value" }
      endpoint.after(&block)
      expect(endpoint.after_blocks).to eq([block])
    end

    it "allows multiple after blocks to be added" do
      endpoint = described_class.new
      block1 = proc { |request, response| response.header "X-First", "1" }
      block2 = proc { |request, response| response.header "X-Second", "2" }
      endpoint.after(&block1)
      endpoint.after(&block2)
      expect(endpoint.after_blocks).to eq([block1, block2])
    end

    it "executes multiple after blocks in the order they were defined" do
      execution_order = []

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.operation(:get)
        endpoint.after do |request, response|
          execution_order << :first
          response.rack_response["X-First"] = "1"
        end
        endpoint.after do |request, response|
          execution_order << :second
          response.rack_response["X-Second"] = "2"
        end
        endpoint.after do |request, response|
          execution_order << :third
          response.rack_response["X-Third"] = "3"
        end
        endpoint.handler do |request, response|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      _status, headers, _body = Raxon::Router.new.call(env)

      expect(execution_order).to eq([:handler, :first, :second, :third])
      expect(headers["X-First"]).to eq("1")
      expect(headers["X-Second"]).to eq("2")
      expect(headers["X-Third"]).to eq("3")
    end
  end

  describe "#has_after?" do
    it "returns true if endpoint has an after block" do
      endpoint = described_class.new
      endpoint.after do |request, response|
        response.header "X-Test", "value"
      end

      expect(endpoint.has_after?).to be true
    end

    it "returns false if endpoint does not have an after block" do
      endpoint = described_class.new
      expect(endpoint.has_after?).to be false
    end
  end

  describe "#metadata" do
    it "stores the metadata block in the metadata_blocks array" do
      endpoint = described_class.new
      block = proc { |request, response, metadata| metadata[:key] = "value" }
      endpoint.metadata(&block)
      expect(endpoint.metadata_blocks).to eq([block])
    end

    it "allows multiple metadata blocks to be added" do
      endpoint = described_class.new
      block1 = proc { |request, response, metadata| metadata[:first] = 1 }
      block2 = proc { |request, response, metadata| metadata[:second] = 2 }
      endpoint.metadata(&block1)
      endpoint.metadata(&block2)
      expect(endpoint.metadata_blocks).to eq([block1, block2])
    end

    it "passes metadata to the handler as the third argument" do
      received_metadata = nil

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.metadata do |request, response, metadata|
          metadata[:x] = 42
        end
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata).to eq({x: 42})
    end

    it "executes multiple metadata blocks in order, with later values overriding" do
      received_metadata = nil

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.metadata do |request, response, metadata|
          metadata[:value] = "first"
          metadata[:only_first] = true
        end
        endpoint.metadata do |request, response, metadata|
          metadata[:value] = "second"
          metadata[:only_second] = true
        end
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata[:value]).to eq("second")
      expect(received_metadata[:only_first]).to be true
      expect(received_metadata[:only_second]).to be true
    end

    it "allows metadata blocks to access request information" do
      received_metadata = nil

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.metadata do |request, response, metadata|
          metadata[:method] = request.method
        end
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata[:method]).to eq("GET")
    end
  end

  describe "#has_metadata?" do
    it "returns true if endpoint has a metadata block" do
      endpoint = described_class.new
      endpoint.metadata do |request, response, metadata|
        metadata[:key] = "value"
      end

      expect(endpoint.has_metadata?).to be true
    end

    it "returns false if endpoint does not have a metadata block" do
      endpoint = described_class.new
      expect(endpoint.has_metadata?).to be false
    end
  end

  describe "#has_handler?" do
    it "returns true if endpoint has a handler" do
      endpoint = described_class.new
      endpoint.response(200, type: :object)
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {}
      end
      expect(endpoint.has_handler?).to be true
    end

    it "returns false if endpoint does not have a handler" do
      endpoint = described_class.new
      expect(endpoint.has_handler?).to be false
    end
  end

  describe "#call without handler" do
    it "executes before block without handler" do
      before_called = false

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.before do |request, response|
          before_called = true
          response.rack_response["X-Before"] = "executed"
        end
      end

      env = Rack::MockRequest.env_for("/test")
      _status, headers, _body = Raxon::Router.new.call(env)

      expect(before_called).to be true
      expect(headers["X-Before"]).to eq("executed")
    end

    it "returns empty response if no handler and no before block" do
      define_route("routes/test/get.rb") do |endpoint|
        endpoint.response(200, type: :object)
      end

      env = Rack::MockRequest.env_for("/test")
      status, _headers, _body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
    end
  end
end
