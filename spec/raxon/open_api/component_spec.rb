require "spec_helper"

RSpec.describe Raxon::OpenApi::Component do
  let(:component) { described_class.new("Post", type: :object, description: "A blog post") }

  describe "#initialize" do
    it "sets the name" do
      expect(component.name).to eq("Post")
    end

    it "sets the type" do
      expect(component.type).to eq("object")
    end

    it "sets the description" do
      expect(component.description).to eq("A blog post")
    end

    it "sets the of type" do
      component = described_class.new("Post", type: :array, of: "Post")
      expect(component.of).to eq("Post")
    end
  end

  describe "#property" do
    it "adds a property with options" do
      component.property(:title, type: :string, description: "The title of the post")
      expect(component.properties[:title]).to be_a(Raxon::OpenApi::Property)
      expect(component.properties[:title].type).to eq("string")
      expect(component.properties[:title].description).to eq("The title of the post")
    end

    it "yields the property object" do
      expect { |b| component.property(:title, type: :string, &b) }.to yield_with_args(an_instance_of(Raxon::OpenApi::Property))
    end
  end
end
