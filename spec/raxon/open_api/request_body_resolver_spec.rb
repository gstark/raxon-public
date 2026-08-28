# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::RequestBodyResolver do
  subject(:resolver) { described_class.new }

  def build_body(**options, &block)
    body = Raxon::OpenApi::RequestBody.new(type: :object, **options)
    yield body if block
    body
  end

  it "returns nil for a nil body" do
    expect(resolver.call(nil)).to be_nil
  end

  it "returns the same object when nothing needs resolution" do
    body = build_body { |b| b.property :name, type: :string }

    expect(resolver.call(body)).to be(body)
  end

  describe "a body declared via as:" do
    before do
      Raxon::OpenApi::DSL.component(:User, type: :object) do |c|
        c.property :name, type: :string
        c.property :age, type: :integer, required: false
      end
    end

    it "inlines the component's properties and clears the reference" do
      body = build_body(as: "User")
      resolved = resolver.call(body)

      expect(resolved).not_to be(body)
      expect(resolved.as).to be_nil
      expect(resolved.properties.keys).to contain_exactly(:name, :age)
      expect(resolved.properties[:name].type).to eq("string")
    end

    it "keeps the declared body untouched for document emission" do
      body = build_body(as: "User")
      resolver.call(body)

      expect(body.as).to eq("User")
      expect(body.properties).to be_empty
    end

    it "lets inline properties win over component properties by name" do
      body = build_body(as: "User") { |b| b.property :name, type: :integer }
      resolved = resolver.call(body)

      expect(resolved.properties[:name].type).to eq("integer")
      expect(resolved.properties[:age].type).to eq("integer")
    end

    it "carries the body's own options onto the resolved copy" do
      body = Raxon::OpenApi::RequestBody.new(type: :object, as: "User", required: false, description: "user data")
      resolved = resolver.call(body)

      expect(resolved.required).to be(false)
      expect(resolved.description).to eq("user data")
    end

    it "raises for an unknown component" do
      body = build_body(as: "Missing")

      expect { resolver.call(body) }.to raise_error(Raxon::OpenApi::Error, /unknown component "Missing"/)
    end

    it "leaves a scalar component reference unresolved" do
      Raxon::OpenApi::DSL.component(:Status, type: :string)
      body = build_body(as: "Status")

      resolved = resolver.call(body)
      expect(resolved.properties).to be_empty
    end
  end

  describe "read-only properties" do
    it "removes them and records their names as read_only_keys" do
      body = build_body do |b|
        b.property :name, type: :string
        b.property :deleted_at, type: :datetime, read_only: true
      end

      resolved = resolver.call(body)

      expect(resolved.properties.keys).to eq([:name])
      expect(resolved.read_only_keys).to eq([:deleted_at])
    end

    it "removes component read-only properties for an as: body" do
      Raxon::OpenApi::DSL.component(:Group, type: :object) do |c|
        c.property :title, type: :string
        c.property :id, type: :integer, read_only: true
        c.property :deleted_at, type: :datetime, read_only: true, nullable: true
      end

      resolved = resolver.call(build_body(as: "Group"))

      expect(resolved.properties.keys).to eq([:title])
      expect(resolved.read_only_keys).to contain_exactly(:id, :deleted_at)
    end

    it "removes nested read-only properties" do
      body = build_body do |b|
        b.property :group, type: :object do |group|
          group.property :title, type: :string
          group.property :id, type: :integer, read_only: true
        end
      end

      resolved = resolver.call(body)

      expect(resolved.properties[:group].properties.keys).to eq([:title])
      expect(body.properties[:group].properties.keys).to contain_exactly(:title, :id)
    end
  end

  describe "nested references" do
    before do
      Raxon::OpenApi::DSL.component(:Address, type: :object) do |c|
        c.property :city, type: :string
      end
    end

    it "inlines a property declared via as:" do
      body = build_body { |b| b.property :address, type: :object, as: "Address", required: false, nullable: true }
      resolved = resolver.call(body)

      address = resolved.properties[:address]
      expect(address.properties.keys).to eq([:city])
      expect(address.required).to be(false)
      expect(address.nullable).to be(true)
    end

    it "inlines array items declared via of: a component" do
      body = build_body { |b| b.property :addresses, type: :array, of: "Address", max_items: 3 }
      resolved = resolver.call(body)

      addresses = resolved.properties[:addresses]
      expect(addresses.type).to eq("array")
      expect(addresses.of.to_s).to eq("object")
      expect(addresses.properties.keys).to eq([:city])
      expect(addresses.max_items).to eq(3)
    end

    it "resolves references nested inside components" do
      Raxon::OpenApi::DSL.component(:Person, type: :object) do |c|
        c.property :name, type: :string
        c.property :address, type: :object, as: "Address"
      end

      resolved = resolver.call(build_body(as: "Person"))

      expect(resolved.properties[:address].properties.keys).to eq([:city])
    end

    it "leaves an array of a scalar element type alone" do
      body = build_body { |b| b.property :tags, type: :array, of: :string }

      expect(resolver.call(body)).to be(body)
    end

    it "leaves an array of an unknown component name unconstrained" do
      body = build_body { |b| b.property :things, type: :array, of: "Nope" }

      resolved = resolver.call(body)
      expect(resolved.properties[:things].properties).to be_empty
    end

    it "raises for a nested as: naming an unknown component" do
      body = build_body { |b| b.property :thing, type: :object, as: "Nope" }

      expect { resolver.call(body) }.to raise_error(Raxon::OpenApi::Error, /unknown component "Nope"/)
    end

    it "stops expanding at a component cycle" do
      Raxon::OpenApi::DSL.component(:Node, type: :object) do |c|
        c.property :value, type: :string
        c.property :parent, type: :object, as: "Node"
      end

      resolved = resolver.call(build_body(as: "Node"))

      expect(resolved.properties[:value].type).to eq("string")
      expect(resolved.properties[:parent].properties).to be_empty
    end
  end
end
