# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon::Router exception handling" do
  before do
    Raxon::RouteLoader.reset!
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
  end

  describe "rescue_from" do
    it "invokes registered exception handler on matching exception" do
      handler_called = false

      Raxon.configure do |config|
        config.rescue_from(ArgumentError) do |exception, request, response, metadata|
          handler_called = true
          response.code = :bad_request
          response.body = {error: exception.message}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise ArgumentError, "Invalid argument"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(handler_called).to be true
      expect(status).to eq(400)
      expect(JSON.parse(body.first)["error"]).to eq("Invalid argument")
    end

    it "selects most specific exception handler" do
      selected_handler = nil

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          selected_handler = :standard_error
          response.code = :internal_server_error
          response.body = {error: "General error"}
        end

        config.rescue_from(ArgumentError) do |exception, request, response, metadata|
          selected_handler = :argument_error
          response.code = :bad_request
          response.body = {error: "Argument error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise ArgumentError, "test"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(selected_handler).to eq(:argument_error)
      expect(status).to eq(400)
      expect(JSON.parse(body.first)["error"]).to eq("Argument error")
    end

    it "walks up inheritance chain to find handler" do
      # CustomError inherits from RuntimeError which inherits from StandardError
      custom_error_class = Class.new(RuntimeError)

      handler_called_with = nil

      Raxon.configure do |config|
        config.rescue_from(RuntimeError) do |exception, request, response, metadata|
          handler_called_with = :runtime_error
          response.code = :internal_server_error
          response.body = {error: "Runtime error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise custom_error_class, "Custom error"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(handler_called_with).to eq(:runtime_error)
    end

    it "provides exception to handler" do
      captured_exception = nil

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          captured_exception = exception
          response.code = :internal_server_error
          response.body = {error: "error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise StandardError, "Test error message"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(captured_exception).to be_a(StandardError)
      expect(captured_exception.message).to eq("Test error message")
    end

    it "provides request to handler" do
      captured_request = nil

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          captured_request = request
          response.code = :internal_server_error
          response.body = {error: "error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise StandardError, "test"
        end
      end

      env = Rack::MockRequest.env_for("/test?foo=bar", method: "GET")
      Raxon::Router.new.call(env)

      expect(captured_request).to be_a(Raxon::Request)
      expect(captured_request.path).to eq("/test")
    end

    it "provides response to handler" do
      captured_response = nil

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          captured_response = response
          response.code = :internal_server_error
          response.body = {error: "error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise StandardError, "test"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(captured_response).to be_a(Raxon::Response)
    end

    it "provides metadata to handler" do
      captured_metadata = nil

      Raxon.configure do |config|
        config.before { |request, response, metadata| metadata[:auth_user] = "test_user" }

        config.rescue_from(StandardError) do |exception, request, response, metadata|
          captured_metadata = metadata.dup
          response.code = :internal_server_error
          response.body = {error: "error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise StandardError, "test"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(captured_metadata[:auth_user]).to eq("test_user")
    end

    it "propagates exception when no handler matches" do
      Raxon.configure do |config|
        config.rescue_from(ArgumentError) do |exception, request, response, metadata|
          response.code = :bad_request
          response.body = {error: "Argument error"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise "Not an ArgumentError"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")

      expect {
        Raxon::Router.new.call(env)
      }.to raise_error(RuntimeError, "Not an ArgumentError")
    end

    it "handles exceptions raised in before blocks" do
      handler_called = false

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          handler_called = true
          response.code = :bad_request
          response.body = {error: "Caught in handler"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.before do |request, response, metadata|
          raise StandardError, "Before block error"
        end

        endpoint.handler do |request, response, metadata|
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, _ = Raxon::Router.new.call(env)

      expect(handler_called).to be true
      expect(status).to eq(400)
    end

    it "handles exceptions raised in after blocks" do
      handler_called = false

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          handler_called = true
          response.code = :internal_server_error
          response.body = {error: "After block failed"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :ok
          response.body = {success: true}
        end

        endpoint.after do |request, response, metadata|
          raise StandardError, "After block error"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, _ = Raxon::Router.new.call(env)

      expect(handler_called).to be true
      expect(status).to eq(500)
    end

    it "handles exceptions raised in global before blocks" do
      handler_called = false

      Raxon.configure do |config|
        config.before do |request, response, metadata|
          raise StandardError, "Global before error"
        end

        config.rescue_from(StandardError) do |exception, request, response, metadata|
          handler_called = true
          response.code = :internal_server_error
          response.body = {error: exception.message}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(handler_called).to be true
      expect(status).to eq(500)
      expect(JSON.parse(body.first)["error"]).to eq("Global before error")
    end

    it "does not catch HaltException" do
      exception_handler_called = false

      Raxon.configure do |config|
        config.rescue_from(StandardError) do |exception, request, response, metadata|
          exception_handler_called = true
          response.code = :internal_server_error
          response.body = {error: "Should not reach here"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.before do |request, response, metadata|
          response.code = :forbidden
          response.body = {error: "Forbidden"}
          response.halt
        end

        endpoint.handler do |request, response, metadata|
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(exception_handler_called).to be false
      expect(status).to eq(403)
      expect(JSON.parse(body.first)["error"]).to eq("Forbidden")
    end

    it "allows handler to re-raise exception" do
      Raxon.configure do |config|
        config.rescue_from(ArgumentError) do |exception, request, response, metadata|
          raise # Re-raise
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise ArgumentError, "Original error"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")

      expect {
        Raxon::Router.new.call(env)
      }.to raise_error(ArgumentError, "Original error")
    end

    it "allows handler to raise different exception" do
      Raxon.configure do |config|
        config.rescue_from(ArgumentError) do |exception, request, response, metadata|
          raise "Wrapped: #{exception.message}"
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise ArgumentError, "original"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")

      expect {
        Raxon::Router.new.call(env)
      }.to raise_error(RuntimeError, "Wrapped: original")
    end
  end
end
