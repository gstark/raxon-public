# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Raxon::LimitedInput do
  def wrap(content, limit)
    described_class.new(StringIO.new(content), limit)
  end

  describe "#read" do
    it "returns the data when within the limit" do
      expect(wrap("hello", 10).read).to eq("hello")
    end

    it "raises once the cumulative bytes read exceed the limit" do
      input = wrap("x" * 20, 10)
      expect { input.read }.to raise_error(Raxon::RequestBodyTooLarge)
    end

    it "counts across successive partial reads" do
      input = wrap("x" * 20, 10)
      input.read(6)
      expect { input.read(6) }.to raise_error(Raxon::RequestBodyTooLarge)
    end

    it "returns nil at EOF without tripping the limit" do
      input = wrap("hi", 10)
      input.read
      expect(input.read(5)).to be_nil
    end
  end

  describe "#gets" do
    it "counts bytes and raises when the limit is exceeded" do
      input = wrap("x" * 20, 10)
      expect { input.gets }.to raise_error(Raxon::RequestBodyTooLarge)
    end
  end

  describe "#each" do
    it "returns an enumerator without a block" do
      expect(wrap("hi", 10).each).to be_a(Enumerator)
    end

    it "yields chunks and enforces the limit while iterating" do
      yielded = []
      input = wrap("hello", 10)
      input.each { |chunk| yielded << chunk }
      expect(yielded.join).to eq("hello")
    end

    it "raises mid-iteration once the limit is exceeded" do
      input = wrap("x" * 20, 10)
      expect { input.each { |_| } }.to raise_error(Raxon::RequestBodyTooLarge)
    end
  end

  describe "#rewind" do
    it "resets the counter so a bounded re-read is allowed" do
      input = wrap("x" * 8, 10)
      input.read
      input.rewind
      expect(input.read).to eq("x" * 8)
    end
  end

  describe "#close" do
    it "delegates to the underlying stream" do
      io = StringIO.new("hi")
      described_class.new(io, 10).close
      expect(io).to be_closed
    end

    it "is a no-op when the underlying stream cannot be closed" do
      io = Object.new.tap { |o| def o.read(*) = nil }
      expect { described_class.new(io, 10).close }.not_to raise_error
    end
  end
end
