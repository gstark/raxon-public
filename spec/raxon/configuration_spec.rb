# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Configuration do
  describe "#initialize" do
    it "sets default routes_directory" do
      config = Raxon::Configuration.new
      expect(config.routes_directory).to eq("routes")
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

    it "sets root to nil by default" do
      config = Raxon::Configuration.new
      expect(config.root).to be_nil
    end

    it "sets rails_compatible_instrumentation to false by default" do
      config = Raxon::Configuration.new
      expect(config.rails_compatible_instrumentation).to eq(false)
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
      Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
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

  describe "Raxon.root" do
    before do
      Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
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
