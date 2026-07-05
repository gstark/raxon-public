# frozen_string_literal: true

require "spec_helper"
require "active_record"

# A stand-in for an ActiveRecord column: the adapter reads name, sql_type,
# comment, null, and (when present) array.
FakeIntrospectionColumn = Struct.new(:name, :sql_type, :comment, :null, :array, keyword_init: true)

RSpec.describe Raxon::OpenApi::SchemaIntrospection do
  def ar_column(name, sql_type, comment: nil, null: false, array: false)
    FakeIntrospectionColumn.new(name: name, sql_type: sql_type, comment: comment, null: null, array: array)
  end

  describe ".adapter" do
    it "returns the configured adapter when one is set" do
      custom = Object.new
      Raxon.configuration.schema_adapter = custom

      expect(described_class.adapter).to be(custom)
    end

    it "detects ActiveRecord when it is loaded" do
      expect(described_class.adapter).to be_a(described_class::ActiveRecordAdapter)
    end

    it "detects Sequel when ActiveRecord is absent" do
      hide_const("ActiveRecord")
      stub_const("Sequel::DATABASES", [])

      expect(described_class.adapter).to be_a(described_class::SequelAdapter)
    end

    it "returns nil when no persistence library is loaded" do
      hide_const("ActiveRecord")

      expect(described_class.adapter).to be_nil
    end
  end

  describe "module-level delegation" do
    it "returns nil from all lookups when no adapter is available" do
      hide_const("ActiveRecord")

      expect(described_class.table_columns(:users)).to be_nil
      expect(described_class.model_columns(Class.new)).to be_nil
      expect(described_class.enum_values(Class.new, :status)).to be_nil
    end

    it "delegates lookups to the adapter" do
      adapter = double("adapter")
      Raxon.configuration.schema_adapter = adapter
      allow(adapter).to receive_messages(table_columns: {"a" => 1}, model_columns: {"b" => 2}, enum_values: %w[x])

      expect(described_class.table_columns(:users)).to eq("a" => 1)
      expect(described_class.model_columns(Class.new)).to eq("b" => 2)
      expect(described_class.enum_values(Class.new, :status)).to eq(%w[x])
    end
  end

  describe Raxon::OpenApi::SchemaIntrospection::ActiveRecordAdapter do
    subject(:adapter) { described_class.new }

    describe ".available?" do
      it "is true when ActiveRecord::Base is defined" do
        expect(described_class.available?).to be(true)
      end

      it "is false when ActiveRecord is absent" do
        hide_const("ActiveRecord")

        expect(described_class.available?).to be(false)
      end
    end

    describe "#table_columns" do
      it "normalizes connection columns keyed by name" do
        connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
        allow(connection).to receive(:columns).with("users").and_return([
          ar_column("name", "text", comment: "Full name", null: true),
          ar_column("tags", "text", array: true)
        ])
        allow(ActiveRecord::Base).to receive(:connection).and_return(connection)

        columns = adapter.table_columns(:users)

        expect(columns.keys).to eq(%w[name tags])
        expect(columns["name"]).to have_attributes(sql_type: "text", comment: "Full name", null: true, array: false)
        expect(columns["tags"]).to have_attributes(array: true)
      end

      it "returns nil when the database is unavailable" do
        allow(ActiveRecord::Base).to receive(:connection)
          .and_raise(ActiveRecord::ConnectionNotEstablished)

        expect(adapter.table_columns(:users)).to be_nil
      end
    end

    describe "#model_columns" do
      it "normalizes columns_hash keyed by name" do
        model = Class.new do
          define_singleton_method(:columns_hash) do
            {"age" => FakeIntrospectionColumn.new(name: "age", sql_type: "integer", comment: nil, null: false, array: false)}
          end
        end

        columns = adapter.model_columns(model)

        expect(columns["age"]).to have_attributes(name: "age", sql_type: "integer", comment: nil, null: false, array: false)
      end

      it "treats columns without an array flag as non-array" do
        plain_column = Struct.new(:sql_type, :comment, :null).new("text", nil, false)
        model = Class.new
        model.define_singleton_method(:columns_hash) { {"name" => plain_column} }

        expect(adapter.model_columns(model)["name"].array).to be(false)
      end

      it "returns nil for objects without columns_hash" do
        expect(adapter.model_columns(Class.new)).to be_nil
      end

      it "returns nil when the table is missing" do
        model = Class.new do
          def self.columns_hash
            raise ActiveRecord::StatementInvalid, "relation does not exist"
          end
        end

        expect(adapter.model_columns(model)).to be_nil
      end
    end

    describe "#enum_values" do
      it "extracts inclusion validator values" do
        model = Class.new do
          include ActiveModel::Validations
        end
        model.validates :status, inclusion: {in: %w[active archived]}

        expect(adapter.enum_values(model, :status)).to eq(%w[active archived])
      end

      it "converts ranges to arrays" do
        model = Class.new do
          include ActiveModel::Validations
        end
        model.validates :priority, inclusion: {in: 1..3}

        expect(adapter.enum_values(model, :priority)).to eq([1, 2, 3])
      end

      it "returns nil without an inclusion validator" do
        model = Class.new do
          include ActiveModel::Validations
        end
        model.validates :name, presence: true

        expect(adapter.enum_values(model, :name)).to be_nil
      end

      it "returns nil for proc-based inclusion that cannot enumerate" do
        model = Class.new do
          include ActiveModel::Validations
        end
        model.validates :status, inclusion: {in: ->(_record) { %w[a b] }}

        expect(adapter.enum_values(model, :status)).to be_nil
      end

      it "returns nil for objects without validators_on" do
        expect(adapter.enum_values(Class.new, :status)).to be_nil
      end
    end
  end

  describe Raxon::OpenApi::SchemaIntrospection::SequelAdapter do
    subject(:adapter) { described_class.new }

    before do
      stub_const("Sequel::Error", Class.new(StandardError))
    end

    describe ".available?" do
      it "is true when Sequel::DATABASES is defined" do
        stub_const("Sequel::DATABASES", [])

        expect(described_class.available?).to be(true)
      end

      it "is false when Sequel is absent" do
        expect(described_class.available?).to be(false)
      end
    end

    describe "#table_columns" do
      it "normalizes Sequel schema entries" do
        db = double("db")
        allow(db).to receive(:schema).with(:users).and_return([
          [:name, {db_type: "text", allow_null: true, comment: "Full name"}],
          [:age, {db_type: "integer", allow_null: false}],
          [:tags, {db_type: "text[]", allow_null: false}]
        ])
        stub_const("Sequel::DATABASES", [db])

        columns = adapter.table_columns("users")

        expect(columns.keys).to eq(%w[name age tags])
        expect(columns["name"]).to have_attributes(sql_type: "text", null: true, comment: "Full name", array: false)
        expect(columns["age"]).to have_attributes(sql_type: "integer", null: false, comment: nil)
        expect(columns["tags"]).to have_attributes(sql_type: "text", array: true)
      end

      it "returns nil when no database is connected" do
        stub_const("Sequel::DATABASES", [])

        expect(adapter.table_columns(:users)).to be_nil
      end

      it "returns nil when schema lookup fails" do
        db = double("db")
        allow(db).to receive(:schema).and_raise(Sequel::Error, "no such table")
        stub_const("Sequel::DATABASES", [db])

        expect(adapter.table_columns(:missing)).to be_nil
      end
    end

    describe "#model_columns" do
      it "normalizes a Sequel model's db_schema" do
        model = double("SequelModel", db_schema: {name: {db_type: "text", allow_null: false}})

        columns = adapter.model_columns(model)

        expect(columns["name"]).to have_attributes(sql_type: "text", null: false, array: false)
      end

      it "returns nil for objects without db_schema" do
        expect(adapter.model_columns(Class.new)).to be_nil
      end

      it "returns nil when db_schema lookup fails" do
        model = double("SequelModel")
        allow(model).to receive(:db_schema).and_raise(Sequel::Error, "no such table")

        expect(adapter.model_columns(model)).to be_nil
      end
    end

    describe "#enum_values" do
      it "always returns nil (Sequel has no validator introspection)" do
        expect(adapter.enum_values(double, :status)).to be_nil
      end
    end
  end
end
