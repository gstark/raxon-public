# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ErrorHandler integration", load_routes: true do
  it "catches errors from endpoints and returns proper JSON response" do
    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    status, headers, body = server.call(env)

    expect(status).to eq(500)
    expect(headers["content-type"]).to eq("application/json")

    parsed_body = JSON.parse(body.first)
    expect(parsed_body).to eq({"error" => "Internal Server Error"})
    expect(body.first).not_to include("Intentional test error")
  end

  it "does not interfere with successful requests" do
    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
    status, _headers, _body = server.call(env)

    expect(status).to eq(200)
  end

  it "works with logger configuration" do
    require "stringio"
    log_output = StringIO.new
    logger = Logger.new(log_output)

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler, logger: logger
    end

    env = Rack::MockRequest.env_for("/api/v1/error_test", method: "GET")
    status, _headers, _body = server.call(env)

    expect(status).to eq(500)
    log_content = log_output.string
    expect(log_content).to include("StandardError: Intentional test error")
    expect(log_content).to include("GET /api/v1/error_test")
  end
end
