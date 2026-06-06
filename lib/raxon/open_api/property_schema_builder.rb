# frozen_string_literal: true

module Raxon
  module OpenApi
    # Builds Dry::Schema fields from OpenAPI parameter/property definitions.
    #
    # Request and response validation both need to translate the same OpenAPI
    # field model into Dry::Schema macros. Keeping that translation here avoids
    # two subtly-divergent copies of required/optional, scalar, array, object,
    # nullable, and file handling.
    class PropertySchemaBuilder
      def add_parameter_to_schema(schema_context, param)
        add_field_to_schema(schema_context, param.name.to_sym, param)
      end

      def add_properties_to_schema(schema_context, properties)
        properties.each do |prop_name, property|
          add_property_to_schema(schema_context, prop_name, property)
        end
      end

      def add_property_to_schema(schema_context, prop_name, property)
        add_field_to_schema(schema_context, prop_name, property)
      end

      def add_field_to_schema(schema_context, field_name, field)
        case field.type
        when "object"
          add_object_field(schema_context, field_name, field)
        when "array"
          add_array_field(schema_context, field_name, field)
        when "file"
          add_file_field(schema_context, field_name, field)
        else
          add_scalar_field(schema_context, field_name, field)
        end
      end

      def dry_schema_type(field_type)
        case field_type
        when "string"
          :string
        when "number"
          :integer
        when "boolean"
          :bool
        when "array"
          :array
        when "object"
          :hash
        else
          :string
        end
      end

      def map_type_to_dry(openapi_type)
        case openapi_type
        when "string"
          "params.string"
        when "number"
          "params.integer"
        when "boolean"
          "params.bool"
        when "object"
          "params.hash"
        when "array"
          "params.array"
        when "file"
          "params.any"
        else
          "params.string"
        end
      end

      private

      def add_object_field(schema_context, field_name, field)
        if field.properties.any?
          add_object_with_properties_field(schema_context, field_name, field)
        else
          add_hash_field(schema_context, field_name, field)
        end
      end

      def add_object_with_properties_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        builder = self

        if field.nullable
          key.maybe(:hash) do
            builder.add_properties_to_schema(self, field.properties)
          end
        else
          key.hash do
            builder.add_properties_to_schema(self, field.properties)
          end
        end
      end

      def add_hash_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)

        if field.nullable
          key.maybe(:hash)
        else
          key.value(:hash)
        end
      end

      def add_array_field(schema_context, field_name, field)
        if array_object_item_field?(field)
          add_array_object_item_field(schema_context, field_name, field)
        elsif array_scalar_item_type(field)
          add_array_scalar_item_field(schema_context, field_name, field)
        else
          add_scalar_field(schema_context, field_name, field)
        end
      end

      def add_array_object_item_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        builder = self

        if field.nullable
          key.maybe(:array) do
            each(:hash) do
              builder.add_properties_to_schema(self, field.properties)
            end
          end
        else
          key.array(:hash) do
            builder.add_properties_to_schema(self, field.properties)
          end
        end
      end

      def add_array_scalar_item_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        item_type = array_scalar_item_type(field)

        if field.nullable
          key.maybe(:array) do
            each(item_type)
          end
        else
          key.array(item_type)
        end
      end

      def add_scalar_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        type = dry_schema_type(field.type)

        if field.nullable
          key.maybe(type)
        else
          key.value(type)
        end
      end

      def add_file_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)

        if field.nullable
          key.maybe(:any)
        else
          key.filled
        end
      end

      def array_object_item_field?(field)
        field.properties.any? && (field.of.nil? || field.of.to_s == "object")
      end

      def array_scalar_item_type(field)
        return nil unless field.of

        type = dry_schema_type(field.of.to_s)
        return nil if type == :hash

        type
      end

      def field_key(schema_context, field_name, field)
        field.required ? schema_context.required(field_name) : schema_context.optional(field_name)
      end
    end
  end
end
