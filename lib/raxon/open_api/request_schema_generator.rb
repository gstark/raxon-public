# frozen_string_literal: true

module Raxon
  module OpenApi
    # Generates Dry::Schema validators from OpenAPI request definitions.
    #
    # This class converts OpenAPI parameter and request body specifications
    # into executable Dry::Schema validators for runtime validation and type coercion.
    #
    # @example Generate schema from endpoint parameters and request body
    #   generator = RequestSchemaGenerator.new(endpoint.parameters, endpoint.request_body)
    #   schema = generator.to_dry_schema
    #   result = schema.call(params)
    #
    class RequestSchemaGenerator
      # Initialize the generator with parameter definitions.
      #
      # @param parameters [Raxon::OpenApi::Parameters] The parameters to convert
      # @param request_body [Raxon::OpenApi::RequestBody, nil] Optional request body definition
      def initialize(parameters, request_body = nil)
        @parameters = parameters
        @request_body = request_body
      end

      # Generate a Dry::Schema from the parameter definitions.
      #
      # @return [Dry::Schema::Params, nil] The generated schema, or nil if no parameters
      #
      # @example
      #   schema = generator.to_dry_schema
      #   result = schema.call({id: "42", name: "Test"})
      #   result.success?  # => true
      #   result.to_h      # => {id: 42, name: "Test"}
      def to_dry_schema
        return nil if @parameters.parameters.empty? && (@request_body.nil? || @request_body.properties.empty?)

        params = @parameters.parameters
        request_body = @request_body
        generator = self

        Dry::Schema.Params do
          params.each do |param|
            generator.add_parameter_to_schema(self, param)
          end

          # Add request body properties at the top level
          if request_body&.properties&.any?
            generator.add_properties_to_schema(self, request_body.properties)
          end
        end
      end

      # Add a single parameter to the Dry::Schema DSL context.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param param [Raxon::OpenApi::Parameter] The parameter to add
      def add_parameter_to_schema(schema_context, param)
        add_field_to_schema(schema_context, param.name.to_sym, param)
      end

      # Add nested properties to a hash schema context.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param properties [Hash<Symbol, Raxon::OpenApi::Property>] The properties to add
      def add_properties_to_schema(schema_context, properties)
        properties.each do |prop_name, property|
          add_property_to_schema(schema_context, prop_name, property)
        end
      end

      # Add a single property to the Dry::Schema DSL context.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param prop_name [Symbol] The property name
      # @param property [Raxon::OpenApi::Property] The property definition
      def add_property_to_schema(schema_context, prop_name, property)
        add_field_to_schema(schema_context, prop_name, property)
      end

      # Add a field (parameter or property) to the Dry::Schema DSL context.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param field_name [Symbol] The field name
      # @param field [Raxon::OpenApi::Parameter, Raxon::OpenApi::Property] The field definition
      #
      # @private
      def add_field_to_schema(schema_context, field_name, field)
        map_type_to_dry(field.type)
        generator = self

        if field.type == "object" && field.properties.any?
          add_object_field(schema_context, field_name, field, generator)
        elsif field.type == "array"
          add_array_field(schema_context, field_name, field)
        elsif field.required
          add_required_scalar_field(schema_context, field_name, field.type)
        else
          add_optional_scalar_field(schema_context, field_name, field.type)
        end
      end

      # Add an object field with nested properties.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param field_name [Symbol] The field name
      # @param field [Raxon::OpenApi::Parameter, Raxon::OpenApi::Property] The field definition
      # @param generator [RequestSchemaGenerator] The generator instance
      #
      # @private
      def add_object_field(schema_context, field_name, field, generator)
        if field.required
          schema_context.required(field_name).hash do
            generator.add_properties_to_schema(self, field.properties)
          end
        else
          schema_context.optional(field_name).hash do
            generator.add_properties_to_schema(self, field.properties)
          end
        end
      end

      # Add an array field.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param field_name [Symbol] The field name
      # @param field [Raxon::OpenApi::Parameter, Raxon::OpenApi::Property] The field definition
      #
      # @private
      def add_array_field(schema_context, field_name, field)
        if field.required
          schema_context.required(field_name).value(:array)
        else
          schema_context.optional(field_name).value(:array)
        end
      end

      # Add a required scalar field with type coercion.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param field_name [Symbol] The field name
      # @param field_type [String] The field type
      #
      # @private
      def add_required_scalar_field(schema_context, field_name, field_type)
        case field_type
        when "string"
          schema_context.required(field_name).value(:string)
        when "number"
          schema_context.required(field_name).filled(:integer)
        when "boolean"
          schema_context.required(field_name).filled(:bool)
        else
          schema_context.required(field_name).filled
        end
      end

      # Add an optional scalar field with type coercion.
      #
      # @param schema_context [Dry::Schema::DSL] The schema DSL context
      # @param field_name [Symbol] The field name
      # @param field_type [String] The field type
      #
      # @private
      def add_optional_scalar_field(schema_context, field_name, field_type)
        case field_type
        when "string"
          schema_context.optional(field_name).value(:string)
        when "number"
          schema_context.optional(field_name).maybe(:integer)
        when "boolean"
          schema_context.optional(field_name).maybe(:bool)
        else
          # Default to string for unknown types
          schema_context.optional(field_name).value(:string)
        end
      end

      # Map OpenAPI types to Dry::Types specifications.
      #
      # @param openapi_type [String] The OpenAPI type
      # @return [String] The corresponding Dry::Types specification
      #
      # @example
      #   map_type_to_dry("string")   # => "params.integer"
      #   map_type_to_dry("number")   # => "params.integer"
      #   map_type_to_dry("boolean")  # => "params.bool"
      def map_type_to_dry(openapi_type)
        case openapi_type
        when "string"
          "params.string"
        when "number"
          # Use integer for number type
          # Dry::Schema::Params will coerce "42" to 42
          "params.integer"
        when "boolean"
          "params.bool"
        when "object"
          "params.hash"
        when "array"
          "params.array"
        else
          # Default to string for unknown types
          "params.string"
        end
      end
    end
  end
end
