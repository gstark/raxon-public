# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::RequestSchemaGenerator do
  describe "#to_dry_schema" do
    context "with no parameters" do
      it "returns nil" do
        parameters = Raxon::OpenApi::Parameters.new
        generator = described_class.new(parameters)

        expect(generator.to_dry_schema).to be_nil
      end
    end

    context "with simple scalar parameters" do
      it "generates schema for string parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John"})
      end

      it "generates schema for number parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :id, type: :number, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(id: "42")
        expect(result.success?).to be true
        expect(result.to_h[:id]).to eq(42.0)
      end

      it "generates schema for boolean parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :active, type: :boolean, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(active: "true")
        expect(result.success?).to be true
        expect(result.to_h[:active]).to be true
      end
    end

    context "with optional parameters" do
      it "allows missing optional parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :age, type: :number, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John"})
      end

      it "validates optional parameters when present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :age, type: :number, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John", age: "30")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John", age: 30.0})
      end

      it "handles optional boolean parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :active, type: :boolean, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John"})
      end

      it "validates optional boolean parameters when present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :active, type: :boolean, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John", active: "false")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John", active: false})
      end
    end

    context "with required parameters missing" do
      it "fails validation" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call({})
        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:name)
      end
    end

    context "with nested object parameters" do
      it "generates schema for object with properties" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :id, type: :number, in: :path, required: true

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :name, type: :string, required: true
        request_body.property :auto_scale, type: :boolean, required: true
        request_body.property :custom_max, type: :number, required: true

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call({
          id: "42",
          name: "My Stat",
          auto_scale: "true",
          custom_max: "100"
        })

        expect(result.success?).to be true
        expect(result.to_h).to eq({
          id: 42.0,
          name: "My Stat",
          auto_scale: true,
          custom_max: 100.0
        })
      end

      it "validates nested object properties" do
        parameters = Raxon::OpenApi::Parameters.new

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :name, type: :string, required: true

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call({})
        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:name)
      end

      it "handles optional nested properties" do
        parameters = Raxon::OpenApi::Parameters.new

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :name, type: :string, required: true
        request_body.property :description, type: :string, required: false

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call({name: "Test"})
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test"})
      end
    end

    context "with deeply nested objects" do
      it "generates schema for multi-level nesting" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :data, type: :object, required: true do |data|
          data.property :user, type: :object, required: true do |user|
            user.property :name, type: :string, required: true
            user.property :address, type: :object, required: true do |address|
              address.property :city, type: :string, required: true
            end
          end
        end

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call({
          data: {
            user: {
              name: "John",
              address: {
                city: "NYC"
              }
            }
          }
        })

        expect(result.success?).to be true
        expect(result.to_h).to eq({
          data: {
            user: {
              name: "John",
              address: {
                city: "NYC"
              }
            }
          }
        })
      end
    end

    context "with array parameters" do
      it "generates schema for array of strings" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :tags, type: :array, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(tags: ["ruby", "rails"])
        expect(result.success?).to be true
        expect(result.to_h).to eq({tags: ["ruby", "rails"]})
      end
    end

    context "with mixed parameter locations" do
      it "generates schema for path, query, and body parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :id, type: :number, in: :path, required: true
        parameters.define :filter, type: :string, in: :query, required: false

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :name, type: :string, required: true

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call({
          id: "123",
          filter: "active",
          name: "Test"
        })

        expect(result.success?).to be true
        expect(result.to_h).to eq({
          id: 123.0,
          filter: "active",
          name: "Test"
        })
      end
    end

    context "with unknown/custom types" do
      it "generates schema for required unknown types using default behavior" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :custom_field, type: :custom, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(custom_field: "value")
        expect(result.success?).to be true
        expect(result.to_h).to eq({custom_field: "value"})
      end

      it "generates schema for optional unknown types" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :custom_field, type: :custom, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test"})
      end

      it "validates optional unknown types when present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :custom_field, type: :custom, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test", custom_field: "custom_value")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test", custom_field: "custom_value"})
      end
    end

    context "with optional array parameters" do
      it "allows missing optional array" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :tags, type: :array, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test"})
      end
    end

    context "with optional object parameters" do
      it "allows missing optional objects" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :metadata, type: :object, required: false do |meta|
          meta.property :key, type: :string, required: true
        end

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test"})
      end

      it "validates optional objects when present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :metadata, type: :object, required: false do |meta|
          meta.property :key, type: :string, required: true
        end

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test", metadata: {key: "value"})
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test", metadata: {key: "value"}})
      end
    end

    context "with request body but no parameters" do
      it "generates schema from request body only" do
        parameters = Raxon::OpenApi::Parameters.new

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :name, type: :string, required: true

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call(name: "Test")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "Test"})
      end
    end

    context "with empty request body" do
      it "returns nil when both parameters and request body are empty" do
        parameters = Raxon::OpenApi::Parameters.new
        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)

        generator = described_class.new(parameters, request_body)

        expect(generator.to_dry_schema).to be_nil
      end
    end

    context "with empty string parameters" do
      it "allows empty strings for required string parameters" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :tagFilter, type: :string, in: :query, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(tagFilter: "")
        expect(result.success?).to be true
        expect(result.to_h).to eq({tagFilter: ""})
      end

      it "allows empty strings for optional string parameters when present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true
        parameters.define :tagFilter, type: :string, in: :query, required: false

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(name: "John", tagFilter: "")
        expect(result.success?).to be true
        expect(result.to_h).to eq({name: "John", tagFilter: ""})
      end

      it "still requires required parameters to be present" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :name, type: :string, required: true

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call({})
        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:name)
      end

      it "allows empty strings in request body properties" do
        parameters = Raxon::OpenApi::Parameters.new

        request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
        request_body.property :description, type: :string, required: true

        generator = described_class.new(parameters, request_body)
        schema = generator.to_dry_schema

        result = schema.call(description: "")
        expect(result.success?).to be true
        expect(result.to_h).to eq({description: ""})
      end

      it "allows empty strings in nested object properties" do
        parameters = Raxon::OpenApi::Parameters.new
        parameters.define :data, type: :object, required: true do |data|
          data.property :name, type: :string, required: true
        end

        generator = described_class.new(parameters)
        schema = generator.to_dry_schema

        result = schema.call(data: {name: ""})
        expect(result.success?).to be true
        expect(result.to_h).to eq({data: {name: ""}})
      end
    end
  end

  describe "#map_type_to_dry" do
    it "maps string type" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("string")).to eq("params.string")
    end

    it "maps number type to integer" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("number")).to eq("params.integer")
    end

    it "maps boolean type" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("boolean")).to eq("params.bool")
    end

    it "maps object type" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("object")).to eq("params.hash")
    end

    it "maps array type" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("array")).to eq("params.array")
    end

    it "defaults unknown types to string" do
      parameters = Raxon::OpenApi::Parameters.new
      generator = described_class.new(parameters)

      expect(generator.map_type_to_dry("unknown")).to eq("params.string")
    end
  end
end
