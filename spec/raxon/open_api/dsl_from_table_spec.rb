# frozen_string_literal: true

require "spec_helper"
require "alba"
require "active_record"

# A minimal stand-in for a connection column: from_table reads name, sql_type,
# comment, null, and (optionally) array from the connection's column list.
FakeTableColumn = Struct.new(:name, :sql_type, :comment, :null, :array, keyword_init: true)

RSpec.describe Raxon::OpenApi::DSL, ".from_table" do
  def stub_table(table_name, columns)
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
    allow(connection).to receive(:columns).with(table_name.to_s).and_return(columns)
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
  end

  def column(name, sql_type, comment: nil, null: false, array: false)
    FakeTableColumn.new(name: name, sql_type: sql_type, comment: comment, null: null, array: array)
  end

  def properties_for(name, resource, table_name, &block)
    component = described_class.from_table(name, resource, table_name, &block)
    component.properties
  end

  describe "database column type mapping" do
    {
      "integer" => "integer",
      "bigint" => "integer",
      "double precision" => "number",
      "numeric(8,2)" => "number",
      "string" => "string",
      "character varying(255)" => "string",
      "text" => "string",
      "boolean" => "boolean",
      "timestamp(6) without time zone" => "datetime",
      "date" => "date",
      "jsonb" => "object"
    }.each do |sql_type, expected_type|
      it "maps #{sql_type} columns to :#{expected_type}" do
        resource = Class.new do
          include Alba::Resource

          attributes :value
        end
        stub_table(:records, [column("value", sql_type)])

        properties = properties_for(:Record, resource, :records)

        expect(properties[:value].type).to eq(expected_type)
      end
    end
  end

  describe "array columns" do
    it "maps array columns to arrays of the scalar type" do
      resource = Class.new do
        include Alba::Resource

        attributes :values
      end
      stub_table(:records, [column("values", "text", array: true)])

      properties = properties_for(:Record, resource, :records)

      expect(properties[:values].type).to eq("array")
      expect(properties[:values].of).to eq(:string)
    end
  end

  describe "column metadata" do
    it "uses column comments as descriptions and null flags as nullable" do
      resource = Class.new do
        include Alba::Resource

        attributes :name, :nickname
      end
      stub_table(:users, [
        column("name", "text", comment: "Full legal name"),
        column("nickname", "text", null: true)
      ])

      properties = properties_for(:User, resource, :users)

      expect(properties[:name].description).to eq("Full legal name")
      expect(properties[:name].nullable).to be(false)
      expect(properties[:nickname].description).to eq("")
      expect(properties[:nickname].nullable).to be(true)
    end

    it "skips resource attributes that have no matching database column" do
      resource = Class.new do
        include Alba::Resource

        attributes :name, :computed_field
      end
      stub_table(:users, [column("name", "text")])

      properties = properties_for(:User, resource, :users)

      expect(properties.keys).to eq([:name])
    end
  end

  describe "table name handling" do
    it "accepts a String table name" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      stub_table("users", [column("name", "text")])

      properties = properties_for(:User, resource, "users")

      expect(properties[:name].type).to eq("string")
    end
  end

  describe "associations" do
    it "maps Alba associations to arrays referencing the associated component" do
      stub_const("PostResource", Class.new do
        include Alba::Resource

        attributes :id, :title
      end)
      resource = Class.new do
        include Alba::Resource

        attributes :name
        many :posts, resource: PostResource
      end
      stub_table(:users, [column("name", "text")])

      properties = properties_for(:User, resource, :users)

      expect(properties[:posts].type).to eq("array")
      expect(properties[:posts].of).to eq("Post")
    end
  end

  describe "block overrides" do
    it "prefers properties defined in the block over database introspection" do
      resource = Class.new do
        include Alba::Resource

        attributes :name, :age
      end
      stub_table(:users, [
        column("name", "text", comment: "From the database"),
        column("age", "integer")
      ])

      properties = properties_for(:User, resource, :users) do |component|
        component.property :name, type: :string, description: "Overridden"
      end

      expect(properties[:name].description).to eq("Overridden")
      expect(properties[:age].type).to eq("integer")
    end

    it "orders block properties before introspected properties" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      stub_table(:users, [column("name", "text")])

      properties = properties_for(:User, resource, :users) do |component|
        component.property :extra, type: :string
      end

      expect(properties.keys).to eq([:extra, :name])
    end
  end

  describe "Sequel introspection" do
    it "builds properties through a Sequel database when ActiveRecord is absent" do
      resource = Class.new do
        include Alba::Resource

        attributes :name, :created_at
      end
      hide_const("ActiveRecord")
      db = double("db")
      allow(db).to receive(:schema).with(:users).and_return([
        [:name, {db_type: "text", allow_null: false}],
        [:created_at, {db_type: "timestamp without time zone", allow_null: false}]
      ])
      stub_const("Sequel::DATABASES", [db])

      properties = properties_for(:User, resource, :users)

      expect(properties[:name].type).to eq("string")
      expect(properties[:name].description).to eq("")
      expect(properties[:created_at].type).to eq("datetime")
    end
  end

  describe "no persistence library" do
    it "generates only block properties" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      hide_const("ActiveRecord")

      properties = properties_for(:User, resource, :users) do |component|
        component.property :name, type: :string
      end

      expect(properties.keys).to eq([:name])
    end
  end

  describe "configured adapter" do
    it "uses the adapter from configuration over detection" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      adapter = double("adapter")
      column = Raxon::OpenApi::SchemaIntrospection::Column.new(name: "name", sql_type: "text", comment: "From custom adapter", null: false, array: false)
      allow(adapter).to receive(:table_columns).with(:users).and_return("name" => column)
      Raxon.configuration.schema_adapter = adapter

      properties = properties_for(:User, resource, :users)

      expect(properties[:name].type).to eq("string")
      expect(properties[:name].description).to eq("From custom adapter")
    end
  end

  describe "database availability" do
    it "generates only block properties when the database is unreachable" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      properties = properties_for(:User, resource, :users) do |component|
        component.property :name, type: :string
      end

      expect(properties.keys).to eq([:name])
    end

    it "generates no database properties when the table is missing" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(connection).to receive(:columns)
        .and_raise(ActiveRecord::StatementInvalid, "relation does not exist")
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)

      properties = properties_for(:User, resource, :users)

      expect(properties).to be_empty
    end
  end

  it "skips Alba block attributes since their type cannot be introspected" do
    resource = Class.new do
      include Alba::Resource

      attributes :name
      attribute :computed do |_record|
        "derived"
      end
    end
    stub_table(:users, [column("name", "text")])

    properties = properties_for(:User, resource, :users)

    expect(properties.keys).to eq([:name])
  end

  it "registers the component on the default specification" do
    resource = Class.new do
      include Alba::Resource

      attributes :name
    end
    stub_table(:users, [column("name", "text")])

    described_class.from_table(:User, resource, :users)

    expect(described_class.components.map(&:name)).to include("User")
  end
end
