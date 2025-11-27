# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon.configuration.on_error", load_routes: true do
  before do
    # Reset configuration before each test
    Raxon.configuration.on_error = nil
  end

  after do
    # Clean up after tests
    Raxon.configuration.on_error = nil
  end

  it "allows setting on_error callback via configuration" do
    callback = lambda { |request, response, error, env|
      # noop
    }

    Raxon.configure do |config|
      config.on_error = callback
    end

    expect(Raxon.configuration.on_error).to eq(callback)
  end

  it "automatically uses configured on_error when ErrorHandler is added to Server" do
    request_captured = nil
    response_captured = nil
    error_captured = nil
    env_captured = nil

    Raxon.configure do |config|
      config.on_error = lambda { |request, response, error, env|
        request_captured = request
        response_captured = response
        error_captured = error
        env_captured = env
      }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    status, _headers, _body = server.call(env)

    expect(status).to eq(500)
    expect(request_captured).to be_a(Raxon::Request)
    expect(response_captured).to be_a(Raxon::Response)
    expect(error_captured).to be_a(StandardError)
    expect(error_captured.message).to eq("Intentional test error")
    expect(env_captured).to be_a(Hash)
    expect(env_captured).to have_key("REQUEST_METHOD")
  end

  it "allows manual on_error to override configured on_error" do
    manual_callback_called = false
    config_callback_called = false

    Raxon.configure do |config|
      config.on_error = lambda { |request, response, error, env|
        config_callback_called = true
      }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler, on_error: lambda { |request, response, error, env|
        manual_callback_called = true
      }
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    server.call(env)

    expect(manual_callback_called).to be(true)
    expect(config_callback_called).to be(false)
  end

  it "provides access to request parameters in on_error callback" do
    params_captured = nil

    Raxon.configure do |config|
      config.on_error = lambda { |request, response, error, env|
        params_captured = request.params
      }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test?foo=bar", method: "GET")
    server.call(env)

    expect(params_captured).to be_a(Hash)
    expect(params_captured[:foo]).to eq("bar")
  end

  it "provides access to response object for potential modification" do
    response_captured = nil

    Raxon.configure do |config|
      config.on_error = lambda { |request, response, error, env|
        response_captured = response
      }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    server.call(env)

    expect(response_captured).to be_a(Raxon::Response)
    expect(response_captured).to respond_to(:code)
    expect(response_captured).to respond_to(:code=)
    expect(response_captured).to respond_to(:body)
    expect(response_captured).to respond_to(:status_code)
  end

  it "does not fail when on_error is not configured" do
    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    expect {
      status, _headers, _body = server.call(env)
      expect(status).to eq(500)
    }.not_to raise_error
  end

  it "handles exceptions in configured on_error callback gracefully" do
    Raxon.configure do |config|
      config.on_error = lambda { |request, response, error, env|
        raise "Callback failure"
      }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    status, _headers, body = server.call(env)

    # Should still return proper error response even if callback fails
    expect(status).to eq(500)
    parsed_body = JSON.parse(body.first)
    expect(parsed_body).to eq({"error" => "Internal Server Error"})
  end
end
