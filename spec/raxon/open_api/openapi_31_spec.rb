# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::DSL, "OpenAPI 3.1 output" do
  it "emits 3.1.0 by default" do
    expect(described_class.to_open_api["openapi"]).to eq("3.1.0")
  end

  it "emits 3.0.0 when configured" do
    Raxon.configuration.openapi_spec_version = "3.0"

    expect(described_class.to_open_api["openapi"]).to eq("3.0.0")
  end

  it "accepts full version strings" do
    Raxon.configuration.openapi_spec_version = "3.1.0"
    expect(described_class.to_open_api["openapi"]).to eq("3.1.0")

    Raxon.configuration.openapi_spec_version = "3.0.0"
    expect(described_class.to_open_api["openapi"]).to eq("3.0.0")
  end

  it "raises for an unsupported version" do
    Raxon.configuration.openapi_spec_version = "2.0"

    expect { described_class.to_open_api }.to raise_error(ArgumentError, /Unsupported openapi_spec_version/)
  end

  describe "nullable conversion" do
    it "converts nullable typed properties to type arrays" do
      described_class.component("User", type: :object) do |component|
        component.property(:nickname, type: :string, nullable: true)
        component.property(:id, type: :number)
      end

      properties = described_class.to_open_api.dig("components", "schemas", "User", "properties")

      expect(properties["nickname"]["type"]).to eq(["string", "null"])
      expect(properties["nickname"]).not_to have_key("nullable")
      expect(properties["id"]["type"]).to eq("number")
    end

    it "converts nullable array schemas without touching their items" do
      described_class.endpoint do |endpoint|
        endpoint.path("/tags")
        endpoint.operation(:get)
        endpoint.response(:ok, type: :array, of: :string, nullable: true)
      end

      schema = described_class.to_open_api.dig("paths", "/tags", "get", "responses", "200", "content", "application/json", "schema")

      expect(schema["type"]).to eq(["array", "null"])
      expect(schema["items"]).to eq({"type" => "string"})
      expect(schema).not_to have_key("nullable")
    end

    it "adds a null branch to nullable union (anyOf) properties" do
      described_class.component("Metric", type: :object) do |component|
        component.property(:value, type: [:string, :number], nullable: true)
      end

      schema = described_class.to_open_api.dig("components", "schemas", "Metric", "properties", "value")

      expect(schema["anyOf"]).to eq([{"type" => "string"}, {"type" => "number"}, {"type" => "null"}])
      expect(schema).not_to have_key("nullable")
    end

    it "wraps nullable $ref properties in anyOf" do
      described_class.component("Address", type: :object) do |component|
        component.property(:street, type: :string)
      end
      described_class.component("User", type: :object) do |component|
        component.property(:address, type: :object, as: :Address, nullable: true)
      end

      schema = described_class.to_open_api.dig("components", "schemas", "User", "properties", "address")

      expect(schema).to eq(
        "anyOf" => [
          {"$ref" => "#/components/schemas/Address"},
          {"type" => "null"}
        ]
      )
    end

    it "leaves non-schema hashes carrying a nullable key untouched" do
      described_class.component("Config", type: :object) do |component|
        component.property(:settings, type: :object, example: {nullable: true})
      end

      schema = described_class.to_open_api.dig("components", "schemas", "Config", "properties", "settings")

      expect(schema["example"]).to eq({"nullable" => true})
    end

    it "keeps nullable: true keywords when emitting 3.0" do
      Raxon.configuration.openapi_spec_version = "3.0"
      described_class.component("User", type: :object) do |component|
        component.property(:nickname, type: :string, nullable: true)
      end

      schema = described_class.to_open_api.dig("components", "schemas", "User", "properties", "nickname")

      expect(schema["type"]).to eq("string")
      expect(schema["nullable"]).to be(true)
    end
  end
end
