# frozen_string_literal: true

module Raxon
  module OpenApi
    # Generates Dry::Schema validators from OpenAPI response definitions.
    #
    # This class converts OpenAPI response specifications into executable
    # validators for runtime validation of response bodies.
    #
    # @example Generate schema from endpoint response
    #   generator = ResponseSchemaGenerator.new(endpoint.responses[200])
    #   schema = generator.to_dry_schema
    #   result = schema.call(response_body)
    #
    class ResponseSchemaGenerator
      # Small adapter for array-root response validation.
      #
      # Dry::Schema validates object-shaped hashes, so root arrays are validated
      # as a synthetic property and then unwrapped back into the public response
      # validation shape. Item validation remains owned by PropertySchemaBuilder.
      class ArrayRootValidator
        ROOT_KEY = :_root

        def initialize(schema)
          @schema = schema
        end

        def call(value)
          result = @schema.call(ROOT_KEY => value)
          ValidationResult.new(value, root_errors(result), root_value(result))
        end

        private

        def root_errors(result)
          errors = result.errors.to_h.fetch(ROOT_KEY, {})
          return {_self: errors} if errors.is_a?(Array)

          errors
        end

        def root_value(result)
          result.to_h.fetch(ROOT_KEY)
        end
      end

      # Minimal result object for array-root response validation.
      #
      # Object-root responses return Dry::Schema::Result directly. Arrays need an
      # adapter result that exposes the same methods used by Endpoint.
      class ValidationResult
        def initialize(value, errors, coerced_value)
          @value = value
          @errors = errors
          @coerced_value = coerced_value
        end

        def success?
          @errors.empty?
        end

        def errors
          ValidationErrors.new(@errors)
        end

        def to_h
          success? ? @coerced_value : @value
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

      # Initialize the generator with a response definition.
      #
      # @param response [Raxon::OpenApi::Response] The response to convert
      def initialize(response)
        @response = response
        @property_schema_builder = PropertySchemaBuilder.new
      end

      # Generate a validator from the response definition.
      #
      # @return [#call, nil] The generated validator, or nil if no properties
      #
      # @example
      #   schema = generator.to_dry_schema
      #   result = schema.call({status: "ok", id: 42})
      #   result.success?  # => true
      #   result.to_h      # => {status: "ok", id: 42}
      def to_dry_schema
        return nil if @response.properties.empty?

        return ArrayRootValidator.new(array_schema_for(@response.properties)) if @response.type == "array"

        object_schema_for(@response.properties)
      end

      # Build a Dry::Schema for an object with the given properties.
      #
      # @param properties [Hash<Symbol, Raxon::OpenApi::Property>] The object properties
      # @return [Dry::Schema::Params]
      def object_schema_for(properties)
        builder = @property_schema_builder

        Dry::Schema.Params do
          builder.add_properties_to_schema(self, properties)
        end
      end

      # Build a Dry::Schema for a synthetic array root property.
      #
      # @param properties [Hash<Symbol, Raxon::OpenApi::Property>] The array item properties
      # @return [Dry::Schema::Params]
      def array_schema_for(properties)
        builder = @property_schema_builder
        root_property = Property.new(
          type: :array,
          of: :object,
          required: true,
          nullable: @response.nullable,
          properties: properties
        )

        Dry::Schema.Params do
          builder.add_property_to_schema(self, ArrayRootValidator::ROOT_KEY, root_property)
        end
      end

      def map_type_to_dry(openapi_type)
        @property_schema_builder.map_type_to_dry(openapi_type)
      end
    end
  end
end
