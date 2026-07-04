# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Raxon::RouteReloader do
  def write_route(dir, relative_path, body, mtime: nil)
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.utime(mtime, mtime, path) if mtime
    path
  end

  def ping_route(value)
    <<~RUBY
      Raxon.route do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok value: "#{value}"
        end
      end
    RUBY
  end

  def get_value(router, path = "/ping")
    env = Rack::MockRequest.env_for(path, method: "GET")
    status, _, body = router.call(env)
    [status, body.first && JSON.parse(body.first)]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @routes_dir = dir
      example.run
    end
  end

  let(:past) { Time.now - 60 }

  def build_router
    Raxon.configure do |config|
      config.routes_directory = @routes_dir
      config.reload_routes = true
    end
    Raxon::Router.new
  end

  it "reloads a modified route file" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    router = build_router

    expect(get_value(router)).to eq([200, {"value" => "v1"}])

    write_route(@routes_dir, "ping/get.rb", ping_route("v2"))

    expect(get_value(router)).to eq([200, {"value" => "v2"}])
  end

  it "picks up newly added route files" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    router = build_router

    expect(get_value(router, "/pong")[0]).to eq(404)

    write_route(@routes_dir, "pong/get.rb", ping_route("pong"))

    expect(get_value(router, "/pong")).to eq([200, {"value" => "pong"}])
  end

  it "drops deleted route files" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    write_route(@routes_dir, "pong/get.rb", ping_route("pong"), mtime: past)
    router = build_router

    expect(get_value(router, "/pong")[0]).to eq(200)

    File.delete(File.join(@routes_dir, "pong", "get.rb"))

    expect(get_value(router, "/pong")[0]).to eq(404)
    expect(get_value(router, "/ping")[0]).to eq(200)
  end

  it "reloads when an ERB template changes" do
    template_path = File.join(@routes_dir, "page", "get.html.erb")
    write_route(@routes_dir, "page/get.html.erb", "<h1>v1</h1>", mtime: past)
    write_route(@routes_dir, "page/get.rb", <<~RUBY, mtime: past)
      Raxon.route do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.html_body = response.html
        end
      end
    RUBY
    router = build_router

    _, _, body = router.call(Rack::MockRequest.env_for("/page", method: "GET"))
    expect(body.first).to include("v1")

    File.write(template_path, "<h1>v2</h1>")

    _, _, body = router.call(Rack::MockRequest.env_for("/page", method: "GET"))
    expect(body.first).to include("v2")
  end

  it "reloads helpers from helpers_path" do
    helpers_dir = File.join(@routes_dir, "..", "helpers_#{File.basename(@routes_dir)}")
    FileUtils.mkdir_p(helpers_dir)
    helper_path = File.join(helpers_dir, "greeting.rb")
    File.write(helper_path, <<~RUBY)
      module Raxon::HandlerHelpers
        def reloader_greeting = "hello"
      end
    RUBY
    File.utime(past, past, helper_path)

    write_route(@routes_dir, "greet/get.rb", <<~RUBY, mtime: past)
      Raxon.route do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.ok greeting: reloader_greeting
        end
      end
    RUBY

    Raxon.configure { |config| config.helpers_path = helpers_dir }
    router = build_router

    expect(get_value(router, "/greet")).to eq([200, {"greeting" => "hello"}])

    File.write(helper_path, <<~RUBY)
      module Raxon::HandlerHelpers
        def reloader_greeting = "goodbye"
      end
    RUBY

    expect(get_value(router, "/greet")).to eq([200, {"greeting" => "goodbye"}])
  ensure
    FileUtils.rm_rf(helpers_dir) if helpers_dir
  end

  it "preserves a programmatically registered catchall across reloads" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    Raxon::RouteLoader.register_catchall do |endpoint|
      endpoint.handler do |request, response, metadata|
        response.not_found error: "catchall"
      end
    end
    router = build_router

    write_route(@routes_dir, "ping/get.rb", ping_route("v2"))

    expect(get_value(router)).to eq([200, {"value" => "v2"}])
    expect(get_value(router, "/missing")).to eq([404, {"error" => "catchall"}])
  end

  it "does not accumulate duplicate OpenAPI endpoints across reloads" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    router = build_router
    get_value(router)
    baseline = Raxon::OpenApi::DSL.endpoints.size

    write_route(@routes_dir, "ping/get.rb", ping_route("v2"))
    get_value(router)

    expect(Raxon::OpenApi::DSL.endpoints.size).to eq(baseline)
  end

  it "keeps boot-registered OpenAPI endpoints without route files" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    Raxon::OpenApi::DSL.endpoint do |endpoint|
      endpoint.path "/external"
      endpoint.operation :get
    end
    router = build_router

    write_route(@routes_dir, "ping/get.rb", ping_route("v2"))
    get_value(router)

    expect(Raxon::OpenApi::DSL.endpoints.map(&:path)).to include("/external")
  end

  it "does not reload when nothing changed" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    router = build_router
    get_value(router)

    # A programmatic route would be wiped by a reload; surviving the next
    # request proves the fast path took no reset.
    Raxon::RouteLoader.routes.register("GET", "/manual", Raxon::OpenApi::Endpoint.new.tap { |endpoint|
      endpoint.handler { |request, response, metadata| response.ok source: "manual" }
    })

    expect(get_value(router, "/manual")).to eq([200, {"source" => "manual"}])
  end

  it "skips files deleted between glob and stat" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    allow(File).to receive(:mtime).and_raise(Errno::ENOENT)

    reloader = described_class.new

    expect { reloader.reload_if_changed }.not_to raise_error
  end

  it "does not watch the filesystem when disabled" do
    write_route(@routes_dir, "ping/get.rb", ping_route("v1"), mtime: past)
    Raxon.configure do |config|
      config.routes_directory = @routes_dir
      config.reload_routes = false
    end
    router = Raxon::Router.new

    write_route(@routes_dir, "ping/get.rb", ping_route("v2"))

    expect(get_value(router)).to eq([200, {"value" => "v1"}])
  end
end

RSpec.describe Raxon::Configuration, "#reload_routes?" do
  around do |example|
    original = ENV["RAXON_ENV"]
    example.run
  ensure
    ENV["RAXON_ENV"] = original
  end

  it "defaults to true in development" do
    ENV["RAXON_ENV"] = "development"

    expect(Raxon::Configuration.new.reload_routes?).to be(true)
  end

  it "defaults to false outside development" do
    ENV["RAXON_ENV"] = "production"

    expect(Raxon::Configuration.new.reload_routes?).to be(false)
  end

  it "honors an explicit override in either direction" do
    ENV["RAXON_ENV"] = "production"
    config = Raxon::Configuration.new
    config.reload_routes = true
    expect(config.reload_routes?).to be(true)

    ENV["RAXON_ENV"] = "development"
    config = Raxon::Configuration.new
    config.reload_routes = false
    expect(config.reload_routes?).to be(false)
  end
end
