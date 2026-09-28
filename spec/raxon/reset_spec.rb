# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon reset API" do
  describe ".reset_configuration!" do
    it "replaces the configuration with a fresh instance" do
      Raxon.configure { |c| c.openapi_title = "Custom" }

      Raxon.reset_configuration!

      expect(Raxon.configuration.openapi_title).to eq("API")
    end

    it "clears accumulated global before/after/around blocks and handlers" do
      Raxon.configure do |c|
        c.before {}
        c.after {}
        c.around {}
        c.rescue_from(StandardError) {}
        c.not_found {}
      end

      Raxon.reset_configuration!

      config = Raxon.configuration
      expect(config.before_blocks).to be_empty
      expect(config.after_blocks).to be_empty
      expect(config.around_blocks).to be_empty
      expect(config.exception_handlers).to be_empty
      expect(config.not_found_handler).to be_nil
    end

    it "resets the loaded-helpers flag so helpers load again" do
      Raxon.instance_variable_set(:@helpers_loaded, true)

      Raxon.reset_configuration!

      expect(Raxon.instance_variable_get(:@helpers_loaded)).to be(false)
    end

    it "leaves the route registry untouched", load_routes: true do
      expect(Raxon::RouteLoader.routes).not_to be_empty

      Raxon.reset_configuration!

      expect(Raxon::RouteLoader.routes).not_to be_empty
    end
  end

  describe "RouteLoader.reset!" do
    it "does not add a copy of each route endpoint on every reset and load", load_routes: true do
      count = Raxon::OpenApi::DSL.endpoints.size
      expect(count).to be > 0

      2.times do
        Raxon::RouteLoader.reset!
        Raxon::RouteLoader.load!
      end

      expect(Raxon::OpenApi::DSL.endpoints.size).to eq(count)
    end

    it "keeps endpoints declared outside a route file" do
      declared = Raxon::OpenApi::DSL.endpoint do |endpoint|
        endpoint.path "/declared"
        endpoint.operation :get
      end

      Raxon::RouteLoader.reset!

      expect(Raxon::OpenApi::DSL.endpoints).to eq([declared])
    end
  end

  describe ".reset!" do
    it "empties the route and OpenAPI registries", load_routes: true do
      Raxon::OpenApi::DSL.component(:Thing, type: :object) { |c| c.property :id, type: :integer }
      expect(Raxon::RouteLoader.routes).not_to be_empty
      expect(Raxon::OpenApi::DSL.components).not_to be_empty

      Raxon.reset!

      expect(Raxon::RouteLoader.routes).to be_empty
      expect(Raxon::OpenApi::DSL.components).to be_empty
    end

    it "also resets the configuration" do
      Raxon.configure { |c| c.openapi_title = "Custom" }

      Raxon.reset!

      expect(Raxon.configuration.openapi_title).to eq("API")
    end
  end
end
