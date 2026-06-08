# frozen_string_literal: true

module Raxon
  module OpenApi
    # Validates declared file upload fields after Dry::Schema has handled the
    # structural type coercion. This keeps Rack upload shape checks in one
    # explicit boundary instead of silently letting arbitrary values through
    # file-typed request body properties.
    class FileUploadValidator
      def initialize(schema, request_body)
        @schema = schema
        @request_body = request_body
      end

      def call(params)
        result = @schema.call(params)
        file_errors = file_errors_for(params)
        return result if file_errors.empty? && result.success?

        ValidationResult.new(result, deep_merge_errors(result.errors.to_h, file_errors))
      end

      private

      def file_errors_for(params)
        return {} unless params.is_a?(Hash)
        return {} unless @request_body&.properties&.any?

        validate_properties(@request_body.properties, params)
      end

      def validate_properties(properties, params)
        properties.each_with_object({}) do |(name, property), errors|
          key = params.key?(name) ? name : name.to_s
          next unless params.key?(key)

          property_errors = validate_property(property, params[key])
          errors[name.to_sym] = property_errors unless property_errors.empty?
        end
      end

      def validate_property(property, value)
        return {} if value.nil? && property.nullable

        case property.type
        when "file"
          Raxon::UploadedFile.valid_upload?(value) ? {} : ["must be a file upload"]
        when "object"
          validate_object(property, value)
        when "array"
          validate_array(property, value)
        else
          {}
        end
      end

      def validate_object(property, value)
        return {} unless value.is_a?(Hash)
        return {} unless property.properties.any?

        validate_properties(property.properties, value)
      end

      def validate_array(property, value)
        value_is_array = value.is_a?(Array)
        return {} unless value_is_array

        validates_object_items = property.properties.any? && (property.of.nil? || property.of.to_s == "object")
        return {} unless validates_object_items

        item_errors = {}
        value.each_with_index do |item, index|
          next unless item.is_a?(Hash)

          errors = validate_properties(property.properties, item)
          item_errors[index] = errors unless errors.empty?
        end
        item_errors
      end

      def deep_merge_errors(left, right)
        left.merge(right) do |_key, left_value, right_value|
          if left_value.is_a?(Hash) && right_value.is_a?(Hash)
            deep_merge_errors(left_value, right_value)
          elsif left_value.is_a?(Array) && right_value.is_a?(Array)
            left_value + right_value
          else
            right_value
          end
        end
      end

      class ValidationResult
        def initialize(schema_result, errors)
          @schema_result = schema_result
          @errors = errors
        end

        def success?
          @errors.empty?
        end

        def errors
          ValidationErrors.new(@errors)
        end

        def to_h
          @schema_result.to_h
        end
      end

      class ValidationErrors
        def initialize(errors)
          @errors = errors
        end

        def to_h
          @errors
        end
      end
    end
  end
end
