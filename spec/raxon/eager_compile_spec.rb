# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Eager compilation" do
  around do |example|
    original = ENV["RAXON_ENV"]
    example.run
  ensure
    ENV["RAXON_ENV"] = original
  end

  describe "Configuration#eager_compile?" do
    it "is on in production and off elsewhere by default" do
      ENV["RAXON_ENV"] = "production"
      expect(Raxon::Configuration.new.eager_compile?).to be(true)

      ENV["RAXON_ENV"] = "development"
      expect(Raxon::Configuration.new.eager_compile?).to be(false)
    end

    it "honors an explicit setting" do
      ENV["RAXON_ENV"] = "production"
      config = Raxon::Configuration.new
      config.eager_compile = false

      expect(config.eager_compile?).to be(false)
    end
  end

  def define_widget_routes
    define_route("routes/widgets/__id__/get.rb") do |endpoint|
      endpoint.parameters { |params| params.define :id, type: :integer, in: :path }
      endpoint.response 200, type: :object do |response|
        response.property :id, type: :integer
      end
      endpoint.handler { |_request, response, _metadata| response.ok(id: 1) }
    end
  end

  def compiled_schemas(effective)
    request = effective.instance_variable_get(:@request_schema)
    responses = effective.response_schemas.instance_variable_get(:@cache)
    [request.instance_variable_defined?(:@param_resolver), responses.keys]
  end

  it "compiles request schemas, response schemas, and patterns when the router is built" do
    Raxon.configure do |config|
      config.eager_compile = true
      config.response_validation = :error_response
    end
    define_widget_routes

    Raxon::Router.new

    entry = Raxon::RouteLoader.routes.instance_variable_get(:@entries_by_path)["/widgets/{id}"]
    expect(entry[:mustermann]).not_to be_nil
    expect(compiled_schemas(entry[:prepared]["GET"][:effective_endpoint])).to eq([true, [200]])
  end

  it "skips response schemas when response validation cannot run" do
    Raxon.configure { |config| config.eager_compile = true }
    define_widget_routes

    Raxon::Router.new

    entry = Raxon::RouteLoader.routes.instance_variable_get(:@entries_by_path)["/widgets/{id}"]
    expect(compiled_schemas(entry[:prepared]["GET"][:effective_endpoint])).to eq([true, []])
  end

  it "compiles nothing when it is off" do
    Raxon.configure { |config| config.eager_compile = false }
    define_widget_routes

    Raxon::Router.new

    entry = Raxon::RouteLoader.routes.instance_variable_get(:@entries_by_path)["/widgets/{id}"]
    expect(entry[:mustermann]).to be_nil
    expect(compiled_schemas(entry[:prepared]["GET"][:effective_endpoint])).to eq([false, []])
  end

  it "fails at boot for a body that names an unknown component" do
    Raxon.configure { |config| config.eager_compile = true }
    define_route("routes/things/post.rb") do |endpoint|
      endpoint.body type: :object, as: :Missing
      endpoint.handler { |_request, response, _metadata| response.ok }
    end

    expect { Raxon::Router.new }.to raise_error(Raxon::OpenApi::Error, /unknown component/)
  end
end
