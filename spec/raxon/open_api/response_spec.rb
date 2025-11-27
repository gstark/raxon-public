require "spec_helper"

RSpec.describe Raxon::OpenApi::Response do
  let(:response) { described_class.new(type: :object, description: "A successful response") }

  describe "#initialize" do
    it "sets the type" do
      expect(response.type).to eq("object")
    end

    it "sets the description" do
      expect(response.description).to eq("A successful response")
    end

    it "sets the as type" do
      response = described_class.new(type: :object, as: "Post")
      expect(response.as).to eq("Post")
    end

    it "sets the of type" do
      response = described_class.new(type: :array, of: "Post")
      expect(response.of).to eq("Post")
    end
  end

  describe "#property" do
    it "adds a property with options" do
      response.property(:title, type: :string, description: "The title of the post")
      expect(response.properties[:title]).to be_a(Raxon::OpenApi::Property)
      expect(response.properties[:title].type).to eq("string")
      expect(response.properties[:title].description).to eq("The title of the post")
    end

    it "yields the property object" do
      expect { |b| response.property(:title, type: :string, &b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Property))
    end
  end
end
