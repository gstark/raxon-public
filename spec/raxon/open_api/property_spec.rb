require "spec_helper"

RSpec.describe Raxon::OpenApi::Property do
  let(:property) { described_class.new(type: :string, description: "The title of the post") }

  describe "#initialize" do
    it "sets the type" do
      expect(property.type).to eq("string")
    end

    it "sets the description" do
      expect(property.description).to eq("The title of the post")
    end

    it "sets the of type" do
      property = described_class.new(type: :array, of: "Post")
      expect(property.of).to eq("Post")
    end

    it "sets the required flag" do
      property = described_class.new(type: :string, required: false)
      expect(property.required).to be false
    end

    it "sets the as type" do
      property = described_class.new(type: :string, as: "Post")
      expect(property.as).to eq("Post")
    end

    it "sets the enum values" do
      property = described_class.new(type: :string, enum: ["draft", "published"])
      expect(property.enum).to eq(["draft", "published"])
    end

    it "sets the allowable values" do
      property = described_class.new(type: :string, allowable_values: ["active", "inactive", "pending"])
      expect(property.allowable_values).to eq(["active", "inactive", "pending"])
    end
  end

  describe "#property" do
    it "adds a nested property" do
      property.property(:nested, type: :string, description: "A nested property")
      expect(property.properties[:nested]).to be_a(Raxon::OpenApi::Property)
      expect(property.properties[:nested].type).to eq("string")
      expect(property.properties[:nested].description).to eq("A nested property")
    end

    it "yields the property object" do
      expect { |b| property.property(:nested, type: :string, &b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Property))
    end
  end
end
