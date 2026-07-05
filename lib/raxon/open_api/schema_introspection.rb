# frozen_string_literal: true

module Raxon
  module OpenApi
    # Database-agnostic schema introspection backing from_resource/from_table.
    #
    # Raxon has no hard dependency on any persistence library. Introspection
    # goes through an adapter chosen at call time: an explicitly configured one
    # (config.schema_adapter), or the first built-in adapter whose library the
    # host application has loaded (ActiveRecord, then Sequel — which also covers
    # ROM, since rom-sql rides a Sequel database). With no adapter available,
    # introspection returns nil and components degrade to their block-declared
    # properties only.
    #
    # An adapter is any object responding to:
    #
    #   table_columns(table_name)          -> Hash{String => Column} or nil
    #   model_columns(model)               -> Hash{String => Column} or nil
    #   enum_values(model, attribute_name) -> Array or nil
    #
    # Returning nil signals "nothing introspectable" (no database, unknown
    # table, unsupported model) and must not raise.
    module SchemaIntrospection
      # The normalized column shape consumed by the DSL type mapping. sql_type
      # is the database's own type string (e.g. "character varying(255)");
      # array is true for array columns, with sql_type holding the element type.
      Column = Struct.new(:name, :sql_type, :comment, :null, :array, keyword_init: true)

      class << self
        # The adapter for the current call: the configured adapter, or the
        # first available built-in. Detection is per-call (not memoized) so a
        # persistence library loaded after Raxon is still picked up.
        #
        # @return [Object, nil]
        def adapter
          configured = Raxon.configuration.schema_adapter
          return configured if configured

          detected = ADAPTERS.find(&:available?)
          detected&.new
        end

        # @param table_name [Symbol, String]
        # @return [Hash{String => Column}, nil]
        def table_columns(table_name)
          adapter&.table_columns(table_name)
        end

        # @param model [Object] A model class exposing schema information
        # @return [Hash{String => Column}, nil]
        def model_columns(model)
          adapter&.model_columns(model)
        end

        # @param model [Object]
        # @param attribute_name [Symbol, String]
        # @return [Array, nil]
        def enum_values(model, attribute_name)
          adapter&.enum_values(model, attribute_name)
        end
      end

      # Introspects through ActiveRecord: the shared connection for tables,
      # columns_hash and inclusion validators for model classes.
      class ActiveRecordAdapter
        def self.available?
          defined?(::ActiveRecord::Base) ? true : false
        end

        def table_columns(table_name)
          columns = ::ActiveRecord::Base.connection.columns(table_name.to_s)
          columns.to_h { |column| [column.name.to_s, normalize(column.name, column)] }
        rescue ::ActiveRecord::ActiveRecordError
          nil
        end

        def model_columns(model)
          return nil unless model.respond_to?(:columns_hash)

          model.columns_hash.to_h { |name, column| [name.to_s, normalize(name, column)] }
        rescue ::ActiveRecord::ActiveRecordError
          nil
        end

        def enum_values(model, attribute_name)
          return nil unless model.respond_to?(:validators_on)

          validator = model.validators_on(attribute_name.to_sym).find { |v| v.is_a?(::ActiveModel::Validations::InclusionValidator) }
          return nil unless validator

          validator.options[:in].respond_to?(:to_a) ? validator.options[:in].to_a : nil
        end

        private

        # Only the PostgreSQL adapter's columns respond to #array.
        def normalize(name, column)
          Column.new(
            name: name.to_s,
            sql_type: column.sql_type,
            comment: column.comment,
            null: column.null,
            array: column.respond_to?(:array) ? !!column.array : false
          )
        end
      end

      # Introspects through a connected Sequel database — the persistence layer
      # under rom-sql. Column comments are not exposed by Sequel's schema
      # parsing on most adapters, so descriptions degrade to "" unless declared
      # in the component block. Inclusion validators do not exist here, so
      # enum-like properties must be declared with allowable_values.
      class SequelAdapter
        def self.available?
          defined?(::Sequel::DATABASES) ? true : false
        end

        def table_columns(table_name)
          db = ::Sequel::DATABASES.first
          return nil unless db

          db.schema(table_name.to_sym).to_h { |name, info| [name.to_s, normalize(name, info)] }
        rescue ::Sequel::Error
          nil
        end

        def model_columns(model)
          return nil unless model.respond_to?(:db_schema)

          model.db_schema.to_h { |name, info| [name.to_s, normalize(name, info)] }
        rescue ::Sequel::Error
          nil
        end

        def enum_values(_model, _attribute_name)
          nil
        end

        private

        # Sequel schema entries are [name, info] pairs; info[:db_type] is the
        # database's type string, with array columns suffixed "[]".
        def normalize(name, info)
          db_type = info[:db_type].to_s
          is_array = db_type.end_with?("[]")

          Column.new(
            name: name.to_s,
            sql_type: is_array ? db_type.delete_suffix("[]") : db_type,
            comment: info[:comment],
            null: info[:allow_null],
            array: is_array
          )
        end
      end

      # Built-in adapters, in detection order.
      ADAPTERS = [ActiveRecordAdapter, SequelAdapter].freeze
    end
  end
end
