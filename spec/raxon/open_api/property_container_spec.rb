# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::PropertyContainer do
  # A minimal includer standing in for Property/Response/RequestBody/Component/
  # Parameter — anything that carries a @properties hash.
  let(:container_class) do
    Class.new do
      include Raxon::OpenApi::PropertyContainer

      attr_reader :properties

      def initialize
        @properties = {}
      end
    end
  end

  let(:container) { container_class.new }

  it "builds a Property under the given name" do
    container.property(:name, type: :string)

    expect(container.properties[:name]).to be_a(Raxon::OpenApi::Property)
    expect(container.properties[:name].type).to eq("string")
  end

  it "yields the created property for nested configuration" do
    container.property(:address, type: :object) do |address|
      address.property(:street, type: :string)
    end

    nested = container.properties[:address].properties[:street]
    expect(nested).to be_a(Raxon::OpenApi::Property)
    expect(nested.type).to eq("string")
  end

  it "is included by all five property-bearing OpenAPI classes" do
    [
      Raxon::OpenApi::Property,
      Raxon::OpenApi::Response,
      Raxon::OpenApi::RequestBody,
      Raxon::OpenApi::Component,
      Raxon::OpenApi::Parameter
    ].each do |klass|
      expect(klass.include?(described_class)).to be(true)
    end
  end
end
