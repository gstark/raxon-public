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

      # Finds keys in a response body that the declared schema does not name.
      #
      # Dry::Schema ignores keys it was not told about, and its validate_keys
      # option also rejects the contents of a free-form `type: :object`
      # property (a jsonb column, say). This walks the body alongside the
      # declared properties instead, and stops wherever the declaration stops:
      # an object with no declared properties, an array of scalars, or a
      # component reference that names nothing known.
      class UndeclaredKeys
        NOT_ALLOWED = ["is not allowed"].freeze

        # @param components [Hash{String => Component}] Components by name
        def initialize(components)
          @components = components
        end

        # @param value [Object] The body, or a nested value within it
        # @param properties [Hash<Symbol, Property>] What the object declares
        # @return [Hash] Errors in Dry::Schema's shape; empty when none
        def object(value, properties)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, child), errors|
            property = properties[key.to_sym]
            if property.nil?
              errors[key] = NOT_ALLOWED
            else
              nested = property_errors(child, property)
              errors[key] = nested unless nested.empty?
            end
          end
        end

        # @param value [Object] An array of objects
        # @param properties [Hash<Symbol, Property>] What each item declares
        # @return [Hash] Errors keyed by item index; empty when none
        def array(value, properties)
          return {} unless value.is_a?(Array)

          value.each_with_index.with_object({}) do |(item, index), errors|
            nested = object(item, properties)
            errors[index] = nested unless nested.empty?
          end
        end

        private

        def property_errors(value, property)
          case property.type
          when "object"
            properties = declared(property.properties) || component_properties(property.as)
            properties ? object(value, properties) : {}
          when "array"
            properties = item_properties(property)
            properties ? array(value, properties) : {}
          else
            {}
          end
        end

        def item_properties(property)
          of = property.of&.to_s
          return declared(property.properties) if of.nil? || of == "object"

          component_properties(of)
        end

        def component_properties(name)
          return nil unless name

          declared(@components[name.to_s]&.properties)
        end

        # nil for an absent or empty declaration: nothing is declared, so
        # nothing is undeclared.
        def declared(properties)
          properties unless properties.nil? || properties.empty?
        end
      end

      # Runs the declared schema, then the undeclared-key check, and reports
      # both sets of errors together.
      class KeyCheckedValidator
        def initialize(schema, check)
          @schema = schema
          @check = check
        end

        def call(value)
          result = @schema.call(value)
          extra = @check.call(value)
          return result if extra.empty?

          ValidationResult.new(value, deep_merge(result.errors.to_h, extra), value)
        end

        private

        def deep_merge(errors, extra)
          errors.merge(extra) do |_key, left, right|
            (left.is_a?(Hash) && right.is_a?(Hash)) ? deep_merge(left, right) : right
          end
        end
      end

      # Initialize the generator with a response definition.
      #
      # @param response [Raxon::OpenApi::Response] The response to convert
      def initialize(response, components: Raxon::OpenApi::DSL.components)
        @response = response
        @components = components.to_h { |component| [component.name, component] }
        @property_schema_builder = PropertySchemaBuilder.new(response: true)
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
        component = referenced_component
        return nil if component.nil? && @response.properties.empty?

        properties = component ? component.properties : @response.properties
        array_root = @response.type == "array"
        schema = array_root ? ArrayRootValidator.new(array_schema_for(properties)) : object_schema_for(properties)
        # A component with no properties (introspection found no table, say)
        # declares no shape, so there is nothing to call undeclared.
        return schema if properties.empty?

        keys = UndeclaredKeys.new(@components)
        KeyCheckedValidator.new(schema, array_root ? ->(value) { keys.array(value, properties) } : ->(value) { keys.object(value, properties) })
      end

      def reference_name
        @response.as || @response.of
      end

      def referenced_component
        return nil unless reference_name

        @components[reference_name.to_s]
      end

      # Build a Dry::Schema for an object with the given properties.
      #
      # @param properties [Hash<Symbol, Raxon::OpenApi::Property>] The object properties
      # A JSON schema, not a Params one. Params coerces strings for form
      # input: "yes" passes as a boolean and "12" as an integer, although the
      # body still sends the strings. The JSON processor checks the values as
      # they are, and still accepts string keys.
      #
      # @return [Dry::Schema::JSON]
      def object_schema_for(properties)
        builder = @property_schema_builder

        Dry::Schema.JSON do
          builder.add_properties_to_schema(self, properties)
        end
      end

      # Build a Dry::Schema for a synthetic array root property.
      #
      # @param properties [Hash<Symbol, Raxon::OpenApi::Property>] The array item properties
      # @return [Dry::Schema::JSON]
      def array_schema_for(properties)
        builder = @property_schema_builder
        root_property = Property.new(
          type: :array,
          of: :object,
          required: true,
          nullable: @response.nullable,
          properties: properties
        )

        Dry::Schema.JSON do
          builder.add_property_to_schema(self, ArrayRootValidator::ROOT_KEY, root_property)
        end
      end
    end
  end
end
