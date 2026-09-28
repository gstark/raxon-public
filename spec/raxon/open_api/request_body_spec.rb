# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::RequestBody do
  describe "strict options" do
    it "rejects an unknown option instead of silently dropping it" do
      expect { described_class.new(type: :object, requird: true) }
        .to raise_error(ArgumentError, /unknown option for .*RequestBody: :requird/)
    end
  end

  describe "enum" do
    it "surfaces a declared enum" do
      body = described_class.new(type: :string, enum: %w[a b])

      expect(body.enum).to eq(%w[a b])
    end

    it "resolves a callable enum lazily on each read" do
      calls = 0
      body = described_class.new(type: :string, allowable_values: -> {
        calls += 1
        %w[x y]
      })

      expect(calls).to eq(0)
      expect(body.allowable_values).to eq(%w[x y])
      expect(calls).to eq(1)
    end
  end
end
