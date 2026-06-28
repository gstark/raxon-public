require "spec_helper"

RSpec.describe Raxon::OpenApi::Parameter do
  describe "#initialize" do
    it "sets the name" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.name).to eq(:id)
    end

    it "sets the in location" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.in).to eq(:path)
    end

    it "sets the type" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.type).to eq("number")
    end

    it "raises ArgumentError on an unknown option" do
      expect { described_class.new(:id, in: :path, type: :number, bogus: true) }
        .to raise_error(ArgumentError, /unknown option for .*Parameter: :bogus/)
    end

    it "sets the description" do
      parameter = described_class.new(:id, in: :path, type: :number, description: "ID of the post")
      expect(parameter.description).to eq("ID of the post")
    end

    it "defaults path parameters to required" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.required).to be true
    end

    it "defaults query parameters to optional" do
      parameter = described_class.new(:page, in: :query, type: :integer)
      expect(parameter.required).to be false
    end

    it "defaults header parameters to optional" do
      parameter = described_class.new(:authorization, in: :header, type: :string)
      expect(parameter.required).to be false
    end

    it "defaults cookie parameters to optional" do
      parameter = described_class.new(:session_id, in: :cookie, type: :string)
      expect(parameter.required).to be false
    end

    it "defaults parameters without a location to optional query parameters" do
      parameter = described_class.new(:filter, type: :string)
      expect(parameter.in).to eq(:query)
      expect(parameter.required).to be false
    end

    it "sets required to false when specified" do
      parameter = described_class.new(:id, in: :path, type: :string, required: false)
      expect(parameter.required).to be false
    end

    it "sets required to true when specified" do
      parameter = described_class.new(:filter, in: :query, type: :string, required: true)
      expect(parameter.required).to be true
    end

    it "sets the enum values" do
      parameter = described_class.new(:format, in: :path, type: :string, enum: ["pdf", "png"])
      expect(parameter.enum).to eq(["pdf", "png"])
    end

    it "sets the allowable values" do
      parameter = described_class.new(:state, in: :query, type: :string, allowable_values: ["active", "inactive"])
      expect(parameter.allowable_values).to eq(["active", "inactive"])
    end

    it "resolves a callable enum lazily on each read" do
      calls = 0
      parameter = described_class.new(:format, in: :path, type: :string, enum: -> {
        calls += 1
        ["docx", "pdf"]
      })

      expect(calls).to eq(0)
      expect(parameter.enum).to eq(["docx", "pdf"])
      expect(parameter.enum).to eq(["docx", "pdf"])
      expect(calls).to eq(2)
    end

    it "returns nil when no enum is set" do
      parameter = described_class.new(:id, in: :path, type: :integer)
      expect(parameter.enum).to be_nil
      expect(parameter.allowable_values).to be_nil
    end
  end
end
