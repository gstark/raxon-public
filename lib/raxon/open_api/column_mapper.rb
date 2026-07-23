# frozen_string_literal: true

module Raxon
  module OpenApi
    # Maps introspected database columns and Alba associations onto Raxon
    # property declarations. Used by Specification#from_resource/#from_table;
    # the DSL types it produces are then emitted like any hand-written property.
    module ColumnMapper
      # Non-array scalar formats keyed by the OpenAPI element type. datetime/date
      # carry an explicit format; every other type infers it (or needs none) at
      # emission time.
      SQL_ELEMENT_FORMATS = {datetime: :date_time, date: :date}.freeze

      module_function

      # Build a property from an Alba association.
      #
      # @param component [Component] The component to add the property to
      # @param attribute_name [Symbol, String] The attribute name
      # @param definition [Alba::Association] The association definition
      # @return [void]
      def build_association_property(component, attribute_name, definition)
        resource_name = definition.instance_variable_get(:@resource).name.split("::").last.gsub(/Resource$/, "")
        component.property attribute_name, type: :array, of: resource_name
      end

      # Build a property from a normalized column.
      #
      # @param component [Component] The component to add the property to
      # @param attribute_name [Symbol, String] The attribute name
      # @param column [SchemaIntrospection::Column] The normalized column
      # @param allowable_values [Array, nil] Array of allowed values
      # @return [void]
      def build_column_property(component, attribute_name, column, allowable_values: nil)
        property_options = build_property_options(column.sql_type, column.array, column.comment.to_s, column.null, allowable_values)
        component.property attribute_name, **property_options
      end

      # Build property options hash based on SQL type.
      #
      # @param sql_type [String] The SQL column type
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param description [String] The column description
      # @param is_nullable [Boolean] Whether the column is nullable
      # @param allowable_values [Array, nil] Array of allowed values
      # @return [Hash] Property options hash
      def build_property_options(sql_type, is_array_column, description, is_nullable, allowable_values)
        base_options = {description: description, nullable: is_nullable, allowable_values: allowable_values}
        element_type = openapi_element_for_sql_type(sql_type)

        if is_array_column
          {type: :array, of: element_type, **base_options}
        elsif (format = SQL_ELEMENT_FORMATS[element_type])
          {type: element_type, format: format, **base_options}
        else
          {type: element_type, **base_options}
        end
      end

      # Map a database column's SQL type to the OpenAPI element type Raxon emits.
      #
      # Unknown types fall back to :string — the JSON-safe default — so an
      # unfamiliar column (uuid, inet, a domain type, ...) documents as a string
      # instead of crashing document generation, which is what previously
      # happened for common types like uuid, json, and bare numeric.
      #
      # @param sql_type [String] The database column's SQL type
      # @return [Symbol] The OpenAPI element type
      def openapi_element_for_sql_type(sql_type)
        case sql_type
        when "integer", "bigint", "smallint"
          :integer
        when "double precision", "real", "numeric", /\Anumeric\(.*\)/
          :number
        when "string", "text", /character varying/
          :string
        when "boolean"
          :boolean
        when /\Atimestamp/
          :datetime
        when "date"
          :date
        when "uuid"
          :uuid
        when "json", "jsonb"
          :object
        else
          :string
        end
      end
    end
  end
end
