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

      it "validates response array item object properties" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :users, type: :array, of: :object, required: true do |user|
          user.property :id, type: :number, required: true
        end

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call(users: [{}])

        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(:users)
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

    context "with an array of a component reference" do
      # A component name is not a dry-schema type, so array elements fall back to
      # loose string validation. (Unknown scalar `type:` values are now rejected
      # at definition, so this of: path is what still exercises that fallback.)
      it "validates unknown element types loosely" do
        response = Raxon::OpenApi::Response.new(type: :object)
        response.property :tags, type: :array, of: :Widget, required: true

        schema = described_class.new(response).to_dry_schema

        expect(schema.call(tags: ["a", "b"]).success?).to be true
      end
    end

    context "with array response type" do
      it "validates each array item against inline response properties" do
        response = Raxon::OpenApi::Response.new(type: :array)
        response.property :id, type: :number, required: true
        response.property :name, type: :string, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call([{id: "1", name: "Alice"}, {id: "2", name: "Bob"}])

        expect(result.success?).to be true
        expect(result.to_h).to eq([{id: 1.0, name: "Alice"}, {id: 2.0, name: "Bob"}])
      end

      it "reports array item validation errors by index" do
        response = Raxon::OpenApi::Response.new(type: :array)
        response.property :id, type: :number, required: true
        response.property :name, type: :string, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call([{id: "1", name: "Alice"}, {id: "2"}])

        expect(result.success?).to be false
        expect(result.errors.to_h).to have_key(1)
        expect(result.errors.to_h[1]).to have_key(:name)
      end

      it "rejects non-array response bodies" do
        response = Raxon::OpenApi::Response.new(type: :array)
        response.property :id, type: :number, required: true

        generator = described_class.new(response)
        schema = generator.to_dry_schema

        result = schema.call({id: "1"})

        expect(result.success?).to be false
        expect(result.errors.to_h).to eq({_self: ["must be an array"]})
      end

      it "returns nil for array responses without properties" do
        response = Raxon::OpenApi::Response.new(type: :array)

        generator = described_class.new(response)

        expect(generator.to_dry_schema).to be_nil
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
end

RSpec.describe Raxon::OpenApi::ResponseSchemaGenerator, "array-root validation results" do
  def validator_for(response)
    described_class.new(response).to_dry_schema
  end

  let(:response) do
    Raxon::OpenApi::Response.new(type: :array, of: :object).tap do |r|
      r.property :id, type: :integer
    end
  end

  it "returns the coerced array on success" do
    result = validator_for(response).call([{id: "1"}, {id: "2"}])

    expect(result.success?).to be(true)
    expect(result.to_h).to eq([{id: 1}, {id: 2}])
  end

  it "returns the original value and indexed errors on failure" do
    original = [{id: 1}, {id: "not-a-number"}]

    result = validator_for(response).call(original)

    expect(result.success?).to be(false)
    expect(result.to_h).to eq(original)
    expect(result.errors.to_h.keys).to include(1)
  end
end
