# frozen_string_literal: true

require_relative "component"
require_relative "endpoint"
require_relative "parameter"
require_relative "parameters"
require_relative "property"
require_relative "request_body"
require_relative "response"

module Raxon
  module OpenApi
    # OpenApi DSL for generating OpenAPI 3.0 specifications from Ruby code.
    #
    # This class provides a domain-specific language for defining OpenAPI components,
    # endpoints, and specifications. It supports automatic schema generation from
    # ActiveRecord models and Alba resources.
    #
    # @example Basic usage
    #   OpenApi::DSL.component(:User, type: :object) do |component|
    #     component.property :name, type: :string
    #     component.property :email, type: :string
    #   end
    #
    #   OpenApi::DSL.endpoint do |e|
    #     e.path "/users"
    #     e.operation :get
    #     e.response 200, type: :array, of: :User
    #   end
    #
    # @example Resource-based component generation
    #   OpenApi::DSL.from_resource(:User, UserResource, User)
    #
    class DSL
      @@endpoints = []
      @@components = []

      # Process and normalize a type specification.
      #
      # Converts Ruby symbols and types to OpenAPI-compatible string types.
      # Handles both simple types and array specifications.
      #
      # @param type [Symbol, String, Array] The type to process
      # @return [String, Array] The processed type
      #
      # @example
      #   process_type(:string)   # => "string"
      #   process_type(:number)   # => "number"
      #   process_type([:string, :number])  # => [:string, :number]
      #
      def self.process_type(type)
        case type
        when Array
          type
        when :number
          "number"
        when :string
          "string"
        when :boolean
          "boolean"
        when :object
          "object"
        when :array
          "array"
        else
          type.to_s
        end
      end

      # Check if database is present and accessible for the given ActiveRecord class.
      #
      # @param active_record_class [Class] ActiveRecord model class
      # @return [Boolean] true if database is accessible, false otherwise
      #
      # @example
      #   database_present?(User)  # => true if User table exists and is accessible
      #
      def self.database_present?(active_record_class)
        !!active_record_class.columns_hash
      rescue ActiveRecord::StatementInvalid
        false
      end

      # Generate a component schema from an Alba resource and ActiveRecord model.
      #
      # Automatically introspects the resource attributes and database schema
      # to generate appropriate OpenAPI component definitions with correct types,
      # descriptions, and validation constraints.
      #
      # @param name [Symbol, String] The component name
      # @param resource [Alba::Resource] The Alba resource class
      # @param active_record_class [Class] The ActiveRecord model class
      # @yield [Component] The component object for additional configuration
      #
      # @example
      #   from_resource(:User, UserResource, User) do |component|
      #     component.property :custom_field, type: :string
      #   end
      #
      def self.from_resource(name, resource, active_record_class, &block)
        component(name, type: :object) do |component|
          yield component if block_given?

          resource._attributes.each do |attribute_name, definition|
            # skip if we've already defined the property
            next if component&.properties&.key?(attribute_name.to_sym)

            property = component&.properties&.[](attribute_name.to_sym)

            if definition.is_a?(Alba::Association)
              build_association_property(component, attribute_name, definition, property)
            elsif definition.is_a?(Symbol)
              build_database_property(component, attribute_name, active_record_class)
            end
          end
        end
      end

      # Build a property from an Alba association.
      #
      # @param component [Component] The component to add the property to
      # @param attribute_name [Symbol, String] The attribute name
      # @param definition [Alba::Association] The association definition
      # @param property [Property, nil] The existing property if already defined
      # @return [void]
      #
      # @private
      def self.build_association_property(component, attribute_name, definition, property)
        resource_name = definition.instance_variable_get(:@resource).name.split("::").last.gsub(/Resource$/, "")
        component.property attribute_name, type: :array, of: resource_name, nullable: property&.nullable
      end

      # Build a property from a database column.
      #
      # @param component [Component] The component to add the property to
      # @param attribute_name [Symbol, String] The attribute name
      # @param active_record_class [Class] The ActiveRecord model class
      # @return [void]
      #
      # @private
      def self.build_database_property(component, attribute_name, active_record_class)
        return unless database_present?(active_record_class)

        active_record_definition = active_record_class.columns_hash[attribute_name.to_s]
        return if active_record_definition.nil?

        sql_type = active_record_definition.sql_type
        description = active_record_definition.comment.to_s
        is_array_column = active_record_definition.respond_to?(:array) && active_record_definition.array
        is_nullable = active_record_definition.null
        allowable_values = extract_allowable_values(active_record_class, attribute_name)

        property_options = build_property_options(sql_type, is_array_column, description, is_nullable, allowable_values)
        component.property attribute_name, **property_options
      end

      # Extract allowable values from inclusion validators for an attribute.
      #
      # @param active_record_class [Class] The ActiveRecord model class
      # @param attribute_name [Symbol, String] The attribute name
      # @return [Array, nil] Array of allowed values or nil if not present
      #
      # @private
      def self.extract_allowable_values(active_record_class, attribute_name)
        return nil unless active_record_class.respond_to?(:validators_on)

        inclusion_validators = active_record_class.validators_on(attribute_name.to_sym).select { |v| v.is_a?(ActiveModel::Validations::InclusionValidator) }
        return nil unless inclusion_validators.any?

        validator = inclusion_validators.first
        validator.options[:in].respond_to?(:to_a) ? validator.options[:in].to_a : nil
      end

      # Build property options hash based on SQL type.
      #
      # @param sql_type [String] The SQL column type
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param description [String] The column description
      # @param is_nullable [Boolean] Whether the column is nullable
      # @param allowable_values [Array, nil] Array of allowed values
      # @return [Hash] Property options hash
      #
      # @private
      def self.build_property_options(sql_type, is_array_column, description, is_nullable, allowable_values)
        base_options = {description: description, nullable: is_nullable, allowable_values: allowable_values}

        case sql_type
        when "integer", "bigint", "double precision", /numeric\(.*\)/
          numeric_property_options(is_array_column, base_options)
        when "string", /character varying/, "text"
          string_property_options(is_array_column, base_options)
        when "boolean"
          boolean_property_options(is_array_column, base_options)
        when "timestamp(6) without time zone", "date"
          datetime_property_options(is_array_column, base_options)
        when "jsonb"
          {type: :object, **base_options}
        else
          raise "Unknown sql type: #{sql_type}"
        end
      end

      # Build property options for numeric types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for numeric type
      #
      # @private
      def self.numeric_property_options(is_array_column, base_options)
        if is_array_column
          {type: :array, of: :number, **base_options}
        else
          {type: :number, **base_options}
        end
      end

      # Build property options for string types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for string type
      #
      # @private
      def self.string_property_options(is_array_column, base_options)
        if is_array_column
          {type: :array, of: :string, **base_options}
        else
          {type: :string, **base_options}
        end
      end

      # Build property options for boolean types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for boolean type
      #
      # @private
      def self.boolean_property_options(is_array_column, base_options)
        if is_array_column
          {type: :array, of: :boolean, **base_options}
        else
          {type: :boolean, **base_options}
        end
      end

      # Build property options for datetime types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for datetime type
      #
      # @private
      def self.datetime_property_options(is_array_column, base_options)
        if is_array_column
          {type: "Dayjs", of: :datetime, **base_options}
        else
          {type: "Dayjs", **base_options}
        end
      end

      # Define a reusable OpenAPI component schema.
      #
      # Components are reusable schemas that can be referenced throughout
      # the OpenAPI specification using $ref.
      #
      # @param name [Symbol, String] The component name
      # @param options [Hash] Component configuration options
      # @yield [Component] The component object for configuration
      #
      # @example
      #   component(:User, type: :object, description: "A user") do |component|
      #     component.property :name, type: :string
      #     component.property :email, type: :string
      #   end
      #
      def self.component(name, options, &block)
        component = Component.new(name, **options)

        @@components << component

        yield component if block_given?
      end

      # Define an API endpoint with operations and responses.
      #
      # @yield [Endpoint] The endpoint object for configuration
      #
      # @example
      #   endpoint do |e|
      #     e.path "/users"
      #     e.operation :get
      #     e.response 200, type: :array, of: :User
      #   end
      #
      def self.endpoint
        endpoint = Endpoint.new

        @@endpoints << endpoint

        yield endpoint if block_given?
      end

      # Recursively transform all keys in a nested hash/array structure.
      #
      # @param obj [Hash, Array, Object] The object to transform
      # @yield [Symbol, String] Block to transform each key
      # @return [Hash, Array, Object] The object with transformed keys
      #
      # @example
      #   deep_transform_keys({a: {b: 1}}, &:to_s)  # => {"a" => {"b" => 1}}
      #
      def self.deep_transform_keys(obj, &block)
        case obj
        when Hash
          obj.transform_keys(&block).transform_values { |v| deep_transform_keys(v, &block) }
        when Array
          obj.map { |v| deep_transform_keys(v, &block) }
        else
          obj
        end
      end

      # Convert a property to OpenAPI items specification for array types.
      #
      # @param property [Property] The property to convert
      # @return [Hash] OpenAPI items specification
      #
      # @example
      #   property_to_items_type(property)  # => {"$ref": "#/components/schemas/User"}
      #
      def self.property_to_items_type(property)
        @@components.map(&:name).include?(property.of.to_s) ? {"$ref": "#/components/schemas/#{property.of}"} : {type: property.of.to_s}
      end

      # Convert a property to OpenAPI JSON schema format.
      #
      # Handles various property types including arrays, objects, references,
      # and union types. Returns both the property name and its schema definition.
      #
      # @param name [Symbol, String] The property name
      # @param property [Property, Component, Response] The property object
      # @return [Array] Array containing [name, schema_definition]
      #
      # @example
      #   property_to_json(:name, property)  # => [:name, {type: "string", description: "..."}]
      #
      def self.property_to_json(name, property)
        # Handle schema references - check both `as:` and `of:` for object types
        if property.as || (property.type == "object" && property.of)
          [name, reference_property_definition(property)]
        else
          definition = case property.type
          when "array"
            array_property_definition(property)
          when Array
            union_type_definition(property)
          else
            standard_property_definition(property)
          end
          [name, definition]
        end
      end

      # Generate definition for a property that references a component schema.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Reference property definition
      #
      # @private
      def self.reference_property_definition(property)
        ref_name = property.as || property.of

        if property.type == "array"
          {
            type: "array",
            items: {
              "$ref" => "#/components/schemas/#{ref_name}"
            }
          }
        else
          {
            "$ref" => "#/components/schemas/#{ref_name}",
            **merge_nullable(property)
          }
        end
      end

      # Generate definition for an array property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Array property definition
      #
      # @private
      def self.array_property_definition(property)
        items = {**property_to_items_type(property), **merge_nullable(property)}

        if property.of.to_s == "object" && property.properties
          items.merge!(properties_to_json(property.properties))
        end

        {
          type: property.type,
          description: property.description,
          items: items
        }
      end

      # Generate definition for a union type property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Union type (anyOf) property definition
      #
      # @private
      def self.union_type_definition(property)
        {
          anyOf: property.type.map { |t| {type: process_type(t)} },
          description: property.description,
          **merge_enum_and_nullable(property)
        }
      end

      # Generate definition for a standard (non-array, non-union) property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Standard property definition
      #
      # @private
      def self.standard_property_definition(property)
        {
          type: property.type,
          description: property.description,
          **merge_enum_and_nullable(property),
          **(property.properties ? properties_to_json(property.properties) : {})
        }
      end

      # Merge nullable attribute into a hash if the property is nullable.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Hash containing nullable: true if applicable, empty hash otherwise
      #
      # @private
      def self.merge_nullable(property)
        (property.respond_to?(:nullable) && property.nullable) ? {nullable: true} : {}
      end

      # Merge enum and nullable attributes into a hash.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Hash containing enum and/or nullable attributes if applicable
      #
      # @private
      def self.merge_enum_and_nullable(property)
        result = {}
        result[:enum] = property.allowable_values if property.respond_to?(:allowable_values) && property.allowable_values
        result[:enum] = property.enum if property.respond_to?(:enum) && property.enum
        result.merge!(merge_nullable(property))
        result
      end

      # Convert a hash of properties to OpenAPI JSON schema format.
      #
      # @param properties [Hash] Hash of property objects
      # @return [Hash] OpenAPI properties schema with required fields
      #
      # @example
      #   properties_to_json(properties)  # => {required: ["name"], properties: {...}}
      #
      def self.properties_to_json(properties)
        required_fields = properties.filter { |_, property| property.required }.keys.map(&:to_s)
        property_definitions = properties.to_h { |name, property| property_to_json(name, property) }.compact_blank

        result = {}
        result[:required] = required_fields unless required_fields.empty?
        result[:properties] = property_definitions unless property_definitions.empty?
        result
      end

      # Generate the complete OpenAPI 3.0 specification.
      #
      # Converts all defined endpoints and components into a complete
      # OpenAPI 3.0 JSON specification with proper structure and references.
      #
      # @return [Hash] Complete OpenAPI 3.0 specification
      #
      # @example
      #   Raxon::OpenApi::DSL.to_open_api  # => {openapi: "3.0.0", info: {...}, paths: {...}, components: {...}}
      #
      def self.to_open_api
        data = {
          openapi: "3.0.0",
          info: build_api_info,
          paths: build_paths,
          components: build_components
        }

        data.deep_transform_keys(&:to_s)
      end

      # Build the API info section of the OpenAPI specification.
      #
      # @return [Hash] API info with title, description, and version
      #
      # @private
      def self.build_api_info
        {
          title: Raxon.configuration.openapi_title,
          description: Raxon.configuration.openapi_description,
          version: Raxon.configuration.openapi_version
        }
      end

      # Build the paths section of the OpenAPI specification.
      #
      # @return [Hash] Paths mapping to endpoint operations
      #
      # @private
      def self.build_paths
        @@endpoints.each_with_object({}) do |endpoint, paths|
          paths[endpoint.path] ||= {}
          endpoint.operations.each do |operation|
            paths[endpoint.path][operation] = build_operation_hash(endpoint)
          end
        end
      end

      # Build an operation hash for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to build the operation for
      # @return [Hash] Operation hash with parameters, responses, and optional requestBody
      #
      # @private
      def self.build_operation_hash(endpoint)
        operation_hash = {
          parameters: build_parameters(endpoint),
          responses: build_responses(endpoint)
        }

        if endpoint.request_body
          operation_hash[:requestBody] = build_request_body(endpoint.request_body)
        end

        operation_hash
      end

      # Build the parameters list for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to extract parameters from
      # @return [Array<Hash>] Array of parameter definitions
      #
      # @private
      def self.build_parameters(endpoint)
        endpoint.parameters.parameters.map { |parameter|
          {
            name: parameter.name.to_s,
            in: parameter.in.to_s,
            required: parameter.required,
            description: parameter.description.to_s,
            schema: property_to_json("schema", parameter)[1].except(:description)
          }
        }
      end

      # Convert a status code symbol or integer to its numeric code.
      #
      # Uses Raxon::Response::STATUS_CODES for symbol lookup.
      #
      # @param status [Symbol, Integer] Status code symbol (e.g., :ok) or numeric code
      # @return [Integer] The numeric HTTP status code
      # @raise [ArgumentError] If the symbol is not a recognized status code
      #
      # @example
      #   status_to_code(:ok)        # => 200
      #   status_to_code(:not_found) # => 404
      #   status_to_code(201)        # => 201
      #
      def self.status_to_code(status)
        return status if status.is_a?(Integer)

        Raxon::Response::STATUS_CODES[status] || raise(ArgumentError, "Unknown status code symbol: #{status}")
      end

      # Build the responses section for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to extract responses from
      # @return [Hash] Hash of status codes to response definitions
      #
      # @private
      def self.build_responses(endpoint)
        endpoint.responses.to_h { |status, response| [status_to_code(status), build_response_object(response)] }
      end

      # Build a single response object.
      #
      # @param response [Response] The response definition
      # @return [Hash] Response object with description, headers, and content
      #
      # @private
      def self.build_response_object(response)
        {
          description: response.description.to_s,
          headers: {},
          content: {
            "application/json" => {
              schema: property_to_json("XXXXX", response)[1].except(:description)
            }
          }
        }
      end

      # Build the request body for an endpoint.
      #
      # @param request_body [RequestBody] The request body definition
      # @return [Hash] Request body object with description, required, and content
      #
      # @private
      def self.build_request_body(request_body)
        {
          description: request_body.description.to_s,
          required: request_body.required,
          content: {
            "application/json" => {
              schema: property_to_json("schema", request_body)[1].except(:description)
            }
          }
        }
      end

      # Build the components section of the OpenAPI specification.
      #
      # @return [Hash] Components hash with schemas
      #
      # @private
      def self.build_components
        {
          schemas: @@components.to_h { |component| property_to_json(component.name, component) }
        }
      end
    end
  end
end
