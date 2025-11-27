require "spec_helper"

RSpec.describe Raxon::OpenApi::Parameters do
  let(:parameters) { described_class.new }

  describe "#initialize" do
    it "initializes an empty parameters array" do
      expect(parameters.parameters).to eq([])
    end
  end

  describe "#define" do
    it "adds a parameter with options" do
      parameters.define(:id, in: :path, type: :number, description: "ID of the post")
      parameter = parameters.parameters.first

      expect(parameter).to be_a(Raxon::OpenApi::Parameter)
      expect(parameter.name).to eq(:id)
      expect(parameter.in).to eq(:path)
      expect(parameter.type).to eq("number")
      expect(parameter.description).to eq("ID of the post")
      expect(parameter.required).to be true
    end

    it "sets required to false when specified" do
      parameters.define(:filter, in: :query, type: :string, required: false)
      parameter = parameters.parameters.first

      expect(parameter.required).to be false
    end
  end
end
