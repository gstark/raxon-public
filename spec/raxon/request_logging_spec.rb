# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Request logging" do
  before do
    define_route("routes/ping/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| response.ok ping: "pong" }
    end
  end

  it "logs each request through Rack::CommonLogger when a logger is configured" do
    log = StringIO.new
    Raxon.configuration.logger = log

    server = Raxon::Server.new
    env = Rack::MockRequest.env_for("/ping", method: "GET")
    status, _, body = server.call(env)
    # CommonLogger writes the log line when the server closes the body
    body.close if body.respond_to?(:close)

    expect(status).to eq(200)
    expect(log.string).to include("GET /ping")
    expect(log.string).to include(" 200 ")
  end

  it "does not log requests when no logger is configured" do
    server = Raxon::Server.new
    env = Rack::MockRequest.env_for("/ping", method: "GET")

    expect(server.call(env)[0]).to eq(200)
  end

  it "auto-injects the configured logger into ErrorHandler" do
    log = StringIO.new
    logger = Logger.new(log)
    Raxon.configuration.logger = logger

    define_route("routes/boom/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| raise "kaboom" }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler
    end

    env = Rack::MockRequest.env_for("/boom", method: "GET")
    status, = server.call(env)

    expect(status).to eq(500)
    expect(log.string).to include("RuntimeError: kaboom")
  end

  it "does not inject the logger into other middleware" do
    Raxon.configuration.logger = StringIO.new

    tagging_middleware = Class.new do
      def initialize(app, **kwargs)
        @app = app
        @kwargs = kwargs
        raise "unexpected logger injection" if kwargs.key?(:logger)
      end

      def call(env)
        status, headers, body = @app.call(env)
        [status, headers.merge("x-tagged" => "yes"), body]
      end
    end

    server = Raxon::Server.new do |app|
      app.use tagging_middleware
    end

    env = Rack::MockRequest.env_for("/ping", method: "GET")
    _, headers, = server.call(env)

    expect(headers["x-tagged"]).to eq("yes")
  end

  it "does not override an explicitly passed ErrorHandler logger" do
    configured_log = StringIO.new
    explicit_log = StringIO.new
    Raxon.configuration.logger = configured_log

    define_route("routes/boom/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| raise "kaboom" }
    end

    server = Raxon::Server.new do |app|
      app.use Raxon::ErrorHandler, logger: Logger.new(explicit_log)
    end

    env = Rack::MockRequest.env_for("/boom", method: "GET")
    server.call(env)

    expect(explicit_log.string).to include("RuntimeError: kaboom")
  end
end
