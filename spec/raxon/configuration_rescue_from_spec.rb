# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon::Configuration#rescue_from" do
  before do
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
  end

  describe "#rescue_from" do
    it "registers an exception handler" do
      config = Raxon::Configuration.new
      block = proc { |exception, request, response, metadata| }

      config.rescue_from(StandardError, &block)

      expect(config.exception_handlers[StandardError]).to eq(block)
    end

    it "allows multiple handlers for different exception classes" do
      config = Raxon::Configuration.new
      block1 = proc { |exception, request, response, metadata| }
      block2 = proc { |exception, request, response, metadata| }

      config.rescue_from(ArgumentError, &block1)
      config.rescue_from(RuntimeError, &block2)

      expect(config.exception_handlers[ArgumentError]).to eq(block1)
      expect(config.exception_handlers[RuntimeError]).to eq(block2)
    end

    it "overwrites handler when same exception class is registered twice" do
      config = Raxon::Configuration.new
      block1 = proc { :first }
      block2 = proc { :second }

      config.rescue_from(StandardError, &block1)
      config.rescue_from(StandardError, &block2)

      expect(config.exception_handlers[StandardError]).to eq(block2)
    end

    it "ignores calls without a block" do
      config = Raxon::Configuration.new

      config.rescue_from(StandardError)

      expect(config.exception_handlers).to be_empty
    end

    it "raises ArgumentError when exception_class is not a Class" do
      config = Raxon::Configuration.new

      expect {
        config.rescue_from("NotAClass") {}
      }.to raise_error(ArgumentError, /must be a Class/)
    end

    it "raises ArgumentError when exception_class is not an Exception subclass" do
      config = Raxon::Configuration.new

      expect {
        config.rescue_from(String) {}
      }.to raise_error(ArgumentError, /must be an Exception subclass/)
    end
  end

  describe "via Raxon.configure" do
    it "allows registering exception handlers" do
      Raxon.configure do |config|
        config.rescue_from(StandardError) { |exception, request, response, metadata| }
      end

      expect(Raxon.configuration.exception_handlers.keys).to include(StandardError)
    end

    it "allows registering multiple exception handlers" do
      Raxon.configure do |config|
        config.rescue_from(ArgumentError) { |exception, request, response, metadata| }
        config.rescue_from(RuntimeError) { |exception, request, response, metadata| }
      end

      expect(Raxon.configuration.exception_handlers.keys).to include(ArgumentError, RuntimeError)
    end
  end
end
