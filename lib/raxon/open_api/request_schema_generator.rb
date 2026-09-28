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
        @property_schema_builder = PropertySchemaBuilder.new
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
        array_body = self.class.array_body?(@request_body)
        return nil if @parameters.parameters.empty? && !array_body && (@request_body.nil? || @request_body.properties.empty?)

        params = @parameters.parameters
        request_body = @request_body
        builder = @property_schema_builder
        body_items = array_body ? array_body_property(request_body) : nil

        schema = Dry::Schema.Params do
          params.each do |param|
            builder.add_parameter_to_schema(self, param)
          end

          if body_items
            # A top-level array has no keys to merge, so it validates under
            # :body and reaches the handler as request.params[:body].
            builder.add_field_to_schema(self, :body, body_items)
          elsif request_body&.properties&.any?
            # Add request body properties at the top level
            builder.add_properties_to_schema(self, request_body.properties)
          end
        end

        (!array_body && self.class.file_fields?(request_body)) ? FileUploadValidator.new(schema, request_body) : schema
      end

      # Whether a request body is a top-level JSON array.
      #
      # @param request_body [RequestBody, nil]
      # @return [Boolean]
      def self.array_body?(request_body)
        request_body&.type == "array"
      end

      # Whether a request body, or any property nested in it, is `type: :file`.
      #
      # @param field [RequestBody, Property, nil]
      # @return [Boolean]
      def self.file_fields?(field)
        return false unless field&.properties&.any?

        field.properties.any? do |_name, property|
          property.type == "file" || file_fields?(property)
        end
      end

      private

      # The array body as a property, so the schema builder can validate it
      # like an array field.
      #
      # @param request_body [RequestBody]
      # @return [Property]
      def array_body_property(request_body)
        Property.new(type: :array, of: request_body.of, properties: request_body.properties,
          required: request_body.required, nullable: request_body.nullable, enum: request_body.enum)
      end
    end
  end
end
