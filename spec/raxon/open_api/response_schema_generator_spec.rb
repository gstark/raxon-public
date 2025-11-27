# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::ResponseSchemaGenerator do
  describe "#to_dry_schema" do
    context "with no properties" do
      it "returns nil" do
        response = Raxon::OpenApi::Response.new(type: :object)
        generator = described_class.new(response)

        expect(generator.to_dry_schema).to be_nil
      end
    end

    context "with simple scalar properties" do
      it "generates schema for string properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "generates schema for number properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :id, type: :number, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(id: "42")
        expect(result.success?).to be true
        expect(result.to_h[:id]).to eq(42.0)
      end

      it "generates schema for boolean properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :success, type: :boolean, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(success: "true")
        expect(result.success?).to be true
        expect(result.to_h[:success]).to be true
      end
    end

    context "with optional properties" do
      it "allows missing optional properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :message, type: :string, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "validates optional properties when present" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :message, type: :string, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok", message: "Success")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok", message: "Success"})
      end

      it "handles optional boolean properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :success, type: :boolean, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "validates optional boolean properties when present" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :success, type: :boolean, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok", success: "true")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok", success: true})
      end

      it "handles optional number properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :count, type: :number, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "validates optional number properties when present" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :count, type: :number, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok", count: "42")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok", count: 42.0})
      end
    end

    context "with required properties missing" do
      it "fails validation" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({})
        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:status)
      end
    end

    context "with nested object properties" do
      it "generates schema for object with properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :data, type: :object, required: true do |data|
          data.property :name, type: :string, required: true
          data.property :count, type: :number, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({
          status: "ok",
          data: {
            name: "Test",
            count: "42"
          }
        })

        expect(result.success?).to be true
        expect(result.to_h).to eq({
          status: "ok",
          data: {
            name: "Test",
            count: 42.0
          }
        })
      end

      it "validates nested object properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :data, type: :object, required: true do |data|
          data.property :name, type: :string, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({data: {}})
        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:data)
      end

      it "handles optional nested properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :data, type: :object, required: true do |data|
          data.property :name, type: :string, required: true
          data.property :description, type: :string, required: false
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({data: {name: "Test"}})
        expect(result.success?).to be true
        expect(result.to_h).to eq({data: {name: "Test"}})
      end
    end

    context "with deeply nested objects" do
      it "generates schema for multi-level nesting" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :result, type: :object, required: true do |result|
          result.property :user, type: :object, required: true do |user|
            user.property :name, type: :string, required: true
            user.property :address, type: :object, required: true do |address|
              address.property :city, type: :string, required: true
            end
          end
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({
          result: {
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
          result: {
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

    context "with array properties" do
      it "generates schema for array of items" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :tags, type: :array, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(tags: ["ruby", "rails"])
        expect(result.success?).to be true
        expect(result.to_h).to eq({tags: ["ruby", "rails"]})
      end
    end

    context "with multiple properties of different types" do
      it "generates schema correctly" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :id, type: :number, required: true
        response.property :name, type: :string, required: true
        response.property :active, type: :boolean, required: true
        response.property :tags, type: :array, required: false
        response.property :metadata, type: :object, required: false do |meta|
          meta.property :created_at, type: :string, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({
          id: "123",
          name: "Test Item",
          active: "true",
          tags: ["tag1", "tag2"],
          metadata: {
            created_at: "2025-01-01"
          }
        })

        expect(result.success?).to be true
        expect(result.to_h).to eq({
          id: 123.0,
          name: "Test Item",
          active: true,
          tags: ["tag1", "tag2"],
          metadata: {
            created_at: "2025-01-01"
          }
        })
      end
    end

    context "with unknown/custom types" do
      it "generates schema for required unknown types using default behavior" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :custom_field, type: :custom, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(custom_field: "value")
        expect(result.success?).to be true
        expect(result.to_h).to eq({custom_field: "value"})
      end

      it "generates schema for optional unknown types" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :custom_field, type: :custom, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "validates optional unknown types when present" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :custom_field, type: :custom, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok", custom_field: "custom_value")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok", custom_field: "custom_value"})
      end
    end

    context "with optional array properties" do
      it "allows missing optional array" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :tags, type: :array, required: false

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end
    end

    context "with optional object properties" do
      it "allows missing optional objects" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :metadata, type: :object, required: false do |meta|
          meta.property :key, type: :string, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok")
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok"})
      end

      it "validates optional objects when present" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :status, type: :string, required: true
        response.property :metadata, type: :object, required: false do |meta|
          meta.property :key, type: :string, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(status: "ok", metadata: {key: "value"})
        expect(result.success?).to be true
        expect(result.to_h).to eq({status: "ok", metadata: {key: "value"}})
      end
    end
  end

  describe "#map_type_to_dry" do
    it "maps string type" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("string")).to eq("params.string")
    end

    it "maps number type to integer" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("number")).to eq("params.integer")
    end

    it "maps boolean type" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("boolean")).to eq("params.bool")
    end

    it "maps object type" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("object")).to eq("params.hash")
    end

    it "maps array type" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("array")).to eq("params.array")
    end

    it "defaults unknown types to string" do
      response = Raxon::OpenApi::Response.new(type: :object)
      generator = described_class.new(response)

      expect(generator.map_type_to_dry("unknown")).to eq("params.string")
    end
  end
end
