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

  describe "#parameters" do
    it "yields the parameters object" do
      endpoint = described_class.new
      expect { |b| endpoint.parameters(&b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Parameters))
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
      before_called = false
      handler_called = false

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response(200, type: :object)
        endpoint.before do |request, response|
          before_called = true
          expect(handler_called).to be false
        end
        endpoint.handler do |request, response|
          handler_called = true
          expect(before_called).to be true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test")
      Raxon::Router.new.call(env)

      expect(before_called).to be true
      expect(handler_called).to be true
    end

    it "allows the before block to access the request" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.response(200, type: :object)
      end

      env = Rack::MockRequest.env_for("/test")
      status, _headers, _body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
    end
  end
end
