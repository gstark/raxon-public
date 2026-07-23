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

    it "defaults the content_type to application/json" do
      expect(response.content_type).to eq("application/json")
    end

    it "sets a custom content_type" do
      response = described_class.new(type: :string, content_type: "text/csv")
      expect(response.content_type).to eq("text/csv")
    end

    it "rejects a content_type that is not a media-type string" do
      expect { described_class.new(type: :string, content_type: :json) }
        .to raise_error(Raxon::OpenApi::Error, /Invalid content_type :json/)
    end

    it "sets the enum" do
      response = described_class.new(type: :array, of: :string, enum: %w[a b])
      expect(response.enum).to eq(%w[a b])
    end

    it "resolves a deferred (callable) enum on read" do
      response = described_class.new(type: :array, of: :string, enum: -> { %w[a b] })
      expect(response.enum).to eq(%w[a b])
    end

    it "raises ArgumentError on an unknown option" do
      expect { described_class.new(type: :object, bogus: true) }
        .to raise_error(ArgumentError, /unknown option for .*Response: :bogus/)
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
