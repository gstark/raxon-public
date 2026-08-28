# frozen_string_literal: true

require "spec_helper"
require "alba"
require "active_record"

# A minimal stand-in for an ActiveRecord column: from_resource only reads
# sql_type, comment, null, and (optionally) array from the columns_hash.
FakeColumn = Struct.new(:sql_type, :comment, :null, :array, keyword_init: true)

RSpec.describe Raxon::OpenApi::DSL, ".from_resource" do
  def fake_model(columns)
    Class.new do
      include ActiveModel::Validations

      define_singleton_method(:columns_hash) { columns }
    end
  end

  def column(sql_type, comment: nil, null: false, array: false)
    FakeColumn.new(sql_type: sql_type, comment: comment, null: null, array: array)
  end

  def properties_for(name, resource, model, &block)
    component = described_class.from_resource(name, resource, model, &block)
    component.properties
  end

  describe "database column type mapping" do
    {
      "integer" => "integer",
      "bigint" => "integer",
      "smallint" => "integer",
      "double precision" => "number",
      "real" => "number",
      "numeric" => "number",
      "numeric(8,2)" => "number",
      "string" => "string",
      "character varying(255)" => "string",
      "text" => "string",
      "boolean" => "boolean",
      "timestamp(6) without time zone" => "datetime",
      "timestamp without time zone" => "datetime",
      "timestamp with time zone" => "datetime",
      "date" => "date",
      "uuid" => "uuid",
      "json" => "object",
      "jsonb" => "object"
    }.each do |sql_type, expected_type|
      it "maps #{sql_type} columns to :#{expected_type}" do
        resource = Class.new do
          include Alba::Resource

          attributes :value
        end
        model = fake_model("value" => column(sql_type))

        properties = properties_for(:Record, resource, model)

        expect(properties[:value].type).to eq(expected_type)
      end
    end

    it "maps an unknown sql type to :string rather than raising" do
      resource = Class.new do
        include Alba::Resource

        attributes :value
      end
      model = fake_model("value" => column("geography"))

      properties = properties_for(:Record, resource, model)

      expect(properties[:value].type).to eq("string")
    end
  end

  describe "array columns" do
    {
      "integer" => :integer,
      "numeric(8,2)" => :number,
      "text" => :string,
      "boolean" => :boolean,
      "timestamp(6) without time zone" => :datetime,
      "date" => :date
    }.each do |sql_type, expected_of|
      it "maps #{sql_type}[] columns to arrays of :#{expected_of}" do
        resource = Class.new do
          include Alba::Resource

          attributes :values
        end
        model = fake_model("values" => column(sql_type, array: true))

        properties = properties_for(:Record, resource, model)

        expect(properties[:values].type).to eq("array")
        expect(properties[:values].of).to eq(expected_of)
      end
    end
  end

  describe "column metadata" do
    it "uses column comments as descriptions and null flags as nullable" do
      resource = Class.new do
        include Alba::Resource

        attributes :name, :nickname
      end
      model = fake_model(
        "name" => column("text", comment: "Full legal name"),
        "nickname" => column("text", null: true)
      )

      properties = properties_for(:User, resource, model)

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
      model = fake_model("name" => column("text"))

      properties = properties_for(:User, resource, model)

      expect(properties.keys).to eq([:name])
    end
  end

  describe "inclusion validators" do
    it "extracts inclusion validator values as allowable values" do
      resource = Class.new do
        include Alba::Resource

        attributes :status
      end
      model = fake_model("status" => column("text"))
      model.validates :status, inclusion: {in: %w[active archived]}

      properties = properties_for(:User, resource, model)

      expect(properties[:status].allowable_values).to eq(%w[active archived])
    end

    it "converts range-based inclusion validators to arrays" do
      resource = Class.new do
        include Alba::Resource

        attributes :priority
      end
      model = fake_model("priority" => column("integer"))
      model.validates :priority, inclusion: {in: 1..3}

      properties = properties_for(:Task, resource, model)

      expect(properties[:priority].allowable_values).to eq([1, 2, 3])
    end

    it "leaves allowable values nil when the attribute has no inclusion validator" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      model = fake_model("name" => column("text"))
      model.validates :name, presence: true

      properties = properties_for(:User, resource, model)

      expect(properties[:name].allowable_values).to be_nil
    end

    it "leaves allowable values nil when the model does not support validators_on" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      columns = {"name" => column("text")}
      model = Class.new do
        define_singleton_method(:columns_hash) { columns }
      end

      properties = properties_for(:User, resource, model)

      expect(properties[:name].allowable_values).to be_nil
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
      model = fake_model("name" => column("text"))

      properties = properties_for(:User, resource, model)

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
      model = fake_model(
        "name" => column("text", comment: "From the database"),
        "age" => column("integer")
      )

      properties = properties_for(:User, resource, model) do |component|
        component.property :name, type: :string, description: "Overridden"
      end

      expect(properties[:name].description).to eq("Overridden")
      expect(properties[:age].type).to eq("integer")
    end
  end

  describe "read-only inference" do
    it "marks server-managed columns read_only and leaves the rest writable" do
      resource = Class.new do
        include Alba::Resource

        attributes :id, :name, :created_at, :updated_at, :deleted_at
      end
      model = fake_model(
        "id" => column("bigint"),
        "name" => column("text"),
        "created_at" => column("timestamp(6) without time zone"),
        "updated_at" => column("timestamp(6) without time zone"),
        "deleted_at" => column("timestamp(6) without time zone", null: true)
      )

      properties = properties_for(:User, resource, model)

      expect(properties.filter_map { |name, property| name if property.read_only })
        .to contain_exactly(:id, :created_at, :updated_at, :deleted_at)
    end

    it "lets a block declaration opt a column back out of read_only" do
      resource = Class.new do
        include Alba::Resource

        attributes :id
      end
      model = fake_model("id" => column("bigint"))

      properties = properties_for(:User, resource, model) do |component|
        component.property :id, type: :integer
      end

      expect(properties[:id].read_only).to be(false)
    end
  end

  describe "database availability" do
    it "generates no database properties when the table is missing" do
      resource = Class.new do
        include Alba::Resource

        attributes :name
      end
      model = Class.new do
        def self.columns_hash
          raise ActiveRecord::StatementInvalid, "relation does not exist"
        end
      end

      properties = properties_for(:User, resource, model)

      expect(properties).to be_empty
    end
  end

  it "registers the component on the default specification" do
    resource = Class.new do
      include Alba::Resource

      attributes :name
    end
    model = fake_model("name" => column("text"))

    described_class.from_resource(:User, resource, model)

    expect(described_class.components.map(&:name)).to include("User")
  end
end

RSpec.describe Raxon::OpenApi::DSL, ".from_resource edge cases" do
  it "skips Alba block attributes since their type cannot be introspected" do
    resource = Class.new do
      include Alba::Resource

      attributes :name
      attribute :computed do |_record|
        "derived"
      end
    end
    columns = {"name" => FakeColumn.new(sql_type: "text", comment: nil, null: false, array: false)}
    model = Class.new do
      include ActiveModel::Validations

      define_singleton_method(:columns_hash) { columns }
    end

    component = described_class.from_resource(:User, resource, model)

    expect(component.properties.keys).to eq([:name])
  end

  it "ignores proc-based inclusion validators that cannot enumerate values" do
    resource = Class.new do
      include Alba::Resource

      attributes :status
    end
    columns = {"status" => FakeColumn.new(sql_type: "text", comment: nil, null: false, array: false)}
    model = Class.new do
      include ActiveModel::Validations

      define_singleton_method(:columns_hash) { columns }
    end
    model.validates :status, inclusion: {in: ->(_record) { %w[a b] }}

    component = described_class.from_resource(:User, resource, model)

    expect(component.properties[:status].allowable_values).to be_nil
  end
end
