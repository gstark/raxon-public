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

    it "sets the description" do
      parameter = described_class.new(:id, in: :path, type: :number, description: "ID of the post")
      expect(parameter.description).to eq("ID of the post")
    end

    it "defaults required to true" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.required).to be true
    end

    it "sets required to false when specified" do
      parameter = described_class.new(:filter, in: :query, type: :string, required: false)
      expect(parameter.required).to be false
    end
  end
end
