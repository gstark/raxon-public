# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Configuration do
  describe "#initialize" do
    it "sets default routes_directory" do
      config = Raxon::Configuration.new
      expect(config.routes_directory).to eq("routes")
    end

    it "allows routes_directories as an alias for routes_directory" do
      config = Raxon::Configuration.new
      directories = ["routes", "engines/blog/routes"]

      config.routes_directories = directories

      expect(config.routes_directory).to eq(directories)
      expect(config.routes_directories).to eq(directories)
    end

    it "sets default openapi_title" do
      config = Raxon::Configuration.new
      expect(config.openapi_title).to eq("API")
    end

    it "sets default openapi_description" do
      config = Raxon::Configuration.new
      expect(config.openapi_description).to eq("")
    end

    it "sets default openapi_version" do
      config = Raxon::Configuration.new
      expect(config.openapi_version).to eq("1.0")
    end

    it "sets on_error to nil by default" do
      config = Raxon::Configuration.new
      expect(config.on_error).to be_nil
    end

    it "sets helpers_path to nil by default" do
      config = Raxon::Configuration.new
      expect(config.helpers_path).to be_nil
    end

    it "defaults regexp_timeout to 0.1 second" do
      config = Raxon::Configuration.new
      expect(config.regexp_timeout).to eq(0.1)
    end

    it "sets root to nil by default" do
      config = Raxon::Configuration.new
      expect(config.root).to be_nil
    end

    it "sets rails_compatible_instrumentation to false by default" do
      config = Raxon::Configuration.new
      expect(config.rails_compatible_instrumentation).to eq(false)
    end

    it "leaves response validation off by default, with details exposed outside production" do
      config = Raxon::Configuration.new

      expect(config.response_validation).to be(false)
      expect(config.expose_validation_details).to be(true)
    end

    it "opts in to response validation through configuration" do
      config = Raxon::Configuration.new
      config.response_validation = :error_response

      expect(config.response_validation).to eq(:error_response)
    end

    it "leaves response validation off without details in production by default" do
      original_raxon_env = ENV["RAXON_ENV"]
      original_rack_env = ENV["RACK_ENV"]
      ENV["RAXON_ENV"] = "production"
      ENV.delete("RACK_ENV")

      config = Raxon::Configuration.new

      expect(config.response_validation).to be(false)
      expect(config.expose_validation_details).to be(false)
    ensure
      ENV["RAXON_ENV"] = original_raxon_env
      ENV["RACK_ENV"] = original_rack_env
    end
  end

  describe "#on_error" do
    it "can be set to a lambda" do
      config = Raxon::Configuration.new
      callback = lambda { |request, response, error, env| }

      config.on_error = callback

      expect(config.on_error).to eq(callback)
    end

    it "can be set to a proc" do
      config = Raxon::Configuration.new
      callback = proc { |request, response, error, env| }

      config.on_error = callback

      expect(config.on_error).to eq(callback)
    end

    it "can be set to nil" do
      config = Raxon::Configuration.new
      config.on_error = lambda { |request, response, error, env| }
      config.on_error = nil

      expect(config.on_error).to be_nil
    end
  end

  describe "Raxon.configure" do
    before do
      # Reset configuration before each test
      Raxon.reset_configuration!
    end

    it "allows configuring on_error via configure block" do
      callback = lambda { |request, response, error, env| }

      Raxon.configure do |config|
        config.on_error = callback
      end

      expect(Raxon.configuration.on_error).to eq(callback)
    end

    it "persists on_error configuration" do
      callback = lambda { |request, response, error, env| }

      Raxon.configure do |config|
        config.on_error = callback
      end

      # Access configuration again
      expect(Raxon.configuration.on_error).to eq(callback)
    end
  end

  describe "#parameter_filter" do
    it "returns the same filter while the settings are unchanged" do
      config = Raxon::Configuration.new

      expect(config.parameter_filter).to be(config.parameter_filter)
    end

    it "rebuilds the filter when filter_parameters is reassigned" do
      config = Raxon::Configuration.new
      config.filter_parameters = [:pin]

      expect(config.parameter_filter.filter_key?(:pin)).to be(true)
      config.filter_parameters = [:otp]
      expect(config.parameter_filter.filter_key?(:pin)).to be(false)
      expect(config.parameter_filter.filter_key?(:otp)).to be(true)
    end

    it "rebuilds the filter when filter_parameters changes in place" do
      config = Raxon::Configuration.new
      expect(config.parameter_filter.filter_key?(:pin)).to be(false)

      config.filter_parameters << :pin

      expect(config.parameter_filter.filter_key?(:pin)).to be(true)
    end

    it "rebuilds the filter when regexp_timeout changes" do
      config = Raxon::Configuration.new
      first = config.parameter_filter

      config.regexp_timeout = 1.0

      expect(config.parameter_filter).not_to be(first)
    end

    it "treats a nil filter_parameters as no filters" do
      config = Raxon::Configuration.new
      config.filter_parameters = nil

      expect(config.parameter_filter.filter_key?(:password)).to be(false)
    end
  end

  describe "Raxon.root" do
    before do
      Raxon.reset_configuration!
    end

    it "raises an error when root is not configured" do
      expect { Raxon.root }.to raise_error(Raxon::Error, "Raxon.root has not been configured")
    end

    it "returns a Pathname when root is configured" do
      Raxon.configure do |config|
        config.root = "/path/to/app"
      end

      expect(Raxon.root).to eq(Pathname.new("/path/to/app"))
      expect(Raxon.root).to be_a(Pathname)
    end

    it "allows configuring root via configure block" do
      Raxon.configure do |config|
        config.root = "/my/app"
      end

      expect(Raxon.configuration.root).to eq("/my/app")
    end

    it "converts string path to Pathname" do
      Raxon.configure do |config|
        config.root = "/some/path"
      end

      result = Raxon.root

      expect(result).to be_a(Pathname)
      expect(result.to_s).to eq("/some/path")
    end
  end
end

RSpec.describe Raxon, ".configure" do
  it "leaves the configuration untouched when called without a block" do
    expect { Raxon.configure }.not_to change { Raxon.configuration.routes_directory }
  end
end
