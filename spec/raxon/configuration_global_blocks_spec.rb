# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon::Configuration global blocks" do
  before do
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
  end

  describe "#before" do
    it "registers a before block" do
      config = Raxon::Configuration.new
      block = proc { |request, response, metadata| }

      config.before(&block)

      expect(config.before_blocks).to eq([block])
    end

    it "allows multiple before blocks" do
      config = Raxon::Configuration.new
      block1 = proc { |request, response, metadata| }
      block2 = proc { |request, response, metadata| }

      config.before(&block1)
      config.before(&block2)

      expect(config.before_blocks).to eq([block1, block2])
    end

    it "ignores calls without a block" do
      config = Raxon::Configuration.new

      config.before

      expect(config.before_blocks).to eq([])
    end
  end

  describe "#after" do
    it "registers an after block" do
      config = Raxon::Configuration.new
      block = proc { |request, response, metadata| }

      config.after(&block)

      expect(config.after_blocks).to eq([block])
    end

    it "allows multiple after blocks" do
      config = Raxon::Configuration.new
      block1 = proc { |request, response, metadata| }
      block2 = proc { |request, response, metadata| }

      config.after(&block1)
      config.after(&block2)

      expect(config.after_blocks).to eq([block1, block2])
    end

    it "ignores calls without a block" do
      config = Raxon::Configuration.new

      config.after

      expect(config.after_blocks).to eq([])
    end
  end

  describe "#around" do
    it "registers an around block" do
      config = Raxon::Configuration.new
      block = proc { |request, response, metadata, &inner| inner.call }

      config.around(&block)

      expect(config.around_blocks).to eq([block])
    end

    it "allows multiple around blocks" do
      config = Raxon::Configuration.new
      block1 = proc { |request, response, metadata, &inner| inner.call }
      block2 = proc { |request, response, metadata, &inner| inner.call }

      config.around(&block1)
      config.around(&block2)

      expect(config.around_blocks).to eq([block1, block2])
    end

    it "ignores calls without a block" do
      config = Raxon::Configuration.new

      config.around

      expect(config.around_blocks).to eq([])
    end
  end

  describe "via Raxon.configure" do
    it "allows registering before blocks" do
      Raxon.configure do |config|
        config.before { |request, response, metadata| }
      end

      expect(Raxon.configuration.before_blocks.size).to eq(1)
    end

    it "allows registering after blocks" do
      Raxon.configure do |config|
        config.after { |request, response, metadata| }
      end

      expect(Raxon.configuration.after_blocks.size).to eq(1)
    end

    it "allows registering around blocks" do
      Raxon.configure do |config|
        config.around { |request, response, metadata, &inner| inner.call }
      end

      expect(Raxon.configuration.around_blocks.size).to eq(1)
    end
  end
end
