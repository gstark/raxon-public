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
        return nil if @parameters.parameters.empty? && (@request_body.nil? || @request_body.properties.empty?)

        params = @parameters.parameters
        request_body = @request_body
        builder = @property_schema_builder

        schema = Dry::Schema.Params do
          params.each do |param|
            builder.add_parameter_to_schema(self, param)
          end

          # Add request body properties at the top level
          if request_body&.properties&.any?
            builder.add_properties_to_schema(self, request_body.properties)
          end
        end

        file_upload_fields?(request_body) ? FileUploadValidator.new(schema, request_body) : schema
      end

      def map_type_to_dry(openapi_type)
        @property_schema_builder.map_type_to_dry(openapi_type)
      end

      private

      def file_upload_fields?(field)
        return false unless field&.properties&.any?

        field.properties.any? do |_name, property|
          property.type == "file" || file_upload_fields?(property)
        end
      end
    end
  end
end
