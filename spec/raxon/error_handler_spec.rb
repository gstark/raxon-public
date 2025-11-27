# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

RSpec.describe Raxon::ErrorHandler do
  describe "#call" do
    context "when no error occurs" do
      it "passes the request through to the app" do
        app = lambda { |env|
          [200, {"content-type" => "application/json"}, [{success: true}.to_json]]
        }
        middleware = Raxon::ErrorHandler.new(app)

        env = Rack::MockRequest.env_for("/test")
        status, headers, _ = middleware.call(env)

        expect(status).to eq(200)
        expect(headers["content-type"]).to eq("application/json")
      end
    end

    context "when an error occurs" do
      it "catches the error and returns 500" do
        app = lambda { |env|
          raise StandardError, "Something went wrong"
        }
        middleware = Raxon::ErrorHandler.new(app)

        env = Rack::MockRequest.env_for("/test")
        status, headers, _ = middleware.call(env)

        expect(status).to eq(500)
        expect(headers["content-type"]).to eq("application/json")
      end

      it "returns a JSON error response" do
        app = lambda { |env|
          raise StandardError, "Something went wrong"
        }
        middleware = Raxon::ErrorHandler.new(app)

        env = Rack::MockRequest.env_for("/test")
        _status, _headers, body = middleware.call(env)

        parsed_body = JSON.parse(body.first)
        expect(parsed_body).to eq({"error" => "Internal Server Error"})
      end

      it "does not leak exception details to the client" do
        app = lambda { |env|
          raise StandardError, "Secret database credentials: password123"
        }
        middleware = Raxon::ErrorHandler.new(app)

        env = Rack::MockRequest.env_for("/test")
        _status, _headers, body = middleware.call(env)

        parsed_body = JSON.parse(body.first)
        expect(parsed_body["error"]).to eq("Internal Server Error")
        expect(body.first).not_to include("password123")
        expect(body.first).not_to include("Secret")
      end

      it "handles different exception types" do
        exceptions = [
          StandardError.new("Standard error"),
          RuntimeError.new("Runtime error"),
          ArgumentError.new("Argument error"),
          NoMethodError.new("No method error")
        ]

        exceptions.each do |exception|
          app = lambda { |env| raise exception }
          middleware = Raxon::ErrorHandler.new(app)

          env = Rack::MockRequest.env_for("/test")
          status, _headers, _body = middleware.call(env)

          expect(status).to eq(500)
        end
      end
    end

    context "with logger" do
      it "logs the error details" do
        log_output = StringIO.new
        logger = Logger.new(log_output)

        app = lambda { |env|
          raise StandardError, "Test error"
        }
        middleware = Raxon::ErrorHandler.new(app, logger: logger)

        env = Rack::MockRequest.env_for("/test")
        middleware.call(env)

        log_content = log_output.string
        expect(log_content).to include("StandardError: Test error")
        expect(log_content).to include("Request: GET /test")
        expect(log_content).to include("Backtrace:")
      end

      it "includes request details in logs" do
        log_output = StringIO.new
        logger = Logger.new(log_output)

        app = lambda { |env|
          raise StandardError, "Test error"
        }
        middleware = Raxon::ErrorHandler.new(app, logger: logger)

        env = Rack::MockRequest.env_for("/api/v1/users?id=42", method: "POST")
        middleware.call(env)

        log_content = log_output.string
        expect(log_content).to include("POST /api/v1/users")
      end

      it "does not log when logger is not provided" do
        app = lambda { |env|
          raise StandardError, "Test error"
        }
        middleware = Raxon::ErrorHandler.new(app)

        env = Rack::MockRequest.env_for("/test")
        expect {
          middleware.call(env)
        }.not_to raise_error
      end
    end

    context "with on_error callback" do
      it "calls the error callback with request, response, error, and env" do
        request_captured = nil
        response_captured = nil
        error_captured = nil
        env_captured = nil

        on_error = lambda { |request, response, error, env|
          request_captured = request
          response_captured = response
          error_captured = error
          env_captured = env
        }

        app = lambda { |env|
          # Simulate Raxon router setting up request/response
          endpoint = Raxon::OpenApi::Endpoint.new
          rack_request = Rack::Request.new(env)
          wrapper_request = Raxon::Request.new(rack_request, endpoint)
          wrapper_response = Raxon::Response.new(endpoint)

          env["raxon.request"] = wrapper_request
          env["raxon.response"] = wrapper_response

          raise StandardError, "Test error"
        }
        middleware = Raxon::ErrorHandler.new(app, on_error: on_error)

        env = Rack::MockRequest.env_for("/test")
        middleware.call(env)

        expect(request_captured).to be_a(Raxon::Request)
        expect(response_captured).to be_a(Raxon::Response)
        expect(error_captured).to be_a(StandardError)
        expect(error_captured.message).to eq("Test error")
        expect(env_captured).to eq(env)
      end

      it "continues processing even if callback fails" do
        on_error = lambda { |request, response, error, env|
          raise "Callback error"
        }

        app = lambda { |env|
          raise StandardError, "Original error"
        }
        middleware = Raxon::ErrorHandler.new(app, on_error: on_error)

        env = Rack::MockRequest.env_for("/test")
        status, _headers, body = middleware.call(env)

        expect(status).to eq(500)
        parsed_body = JSON.parse(body.first)
        expect(parsed_body).to eq({"error" => "Internal Server Error"})
      end

      it "logs callback failures when logger is present" do
        log_output = StringIO.new
        logger = Logger.new(log_output)

        on_error = lambda { |request, response, error, env|
          raise "Callback failure"
        }

        app = lambda { |env|
          raise StandardError, "Original error"
        }
        middleware = Raxon::ErrorHandler.new(app, logger: logger, on_error: on_error)

        env = Rack::MockRequest.env_for("/test")
        middleware.call(env)

        log_content = log_output.string
        expect(log_content).to include("Error notification failed: Callback failure")
      end
    end

    context "integration with actual endpoint" do
      it "catches errors from endpoint handlers" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.handler do |request, response|
          raise StandardError, "Handler error"
        end

        app = lambda { |env|
          rack_request = Rack::Request.new(env)
          request = Raxon::Request.new(rack_request, endpoint)
          response = Raxon::Response.new
          endpoint.call(request, response)
        }

        middleware = Raxon::ErrorHandler.new(app)
        env = Rack::MockRequest.env_for("/test")
        status, headers, body = middleware.call(env)

        expect(status).to eq(500)
        expect(headers["content-type"]).to eq("application/json")
        parsed_body = JSON.parse(body.first)
        expect(parsed_body).to eq({"error" => "Internal Server Error"})
      end
    end
  end
end
