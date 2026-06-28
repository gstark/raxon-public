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
    class Specification
      attr_reader :endpoints, :components

      def initialize
        @endpoints = []
        @components = []
      end

      def reset!
        @endpoints.clear
        @components.clear
      end

      def component(name, options, &block)
        component = Component.new(name, **options)
        @components << component
        yield component if block_given?
        component
      end

      def endpoint
        endpoint = Endpoint.new
        @endpoints << endpoint
        yield endpoint if block_given?
        endpoint
      end

      def from_resource(name, resource, active_record_class, &block)
        component(name, type: :object) do |component|
          yield component if block_given?

          resource._attributes.each do |attribute_name, definition|
            next if component&.properties&.key?(attribute_name.to_sym)

            if definition.is_a?(Alba::Association)
              DSL.build_association_property(component, attribute_name, definition, nil)
            elsif definition.is_a?(Symbol)
              DSL.build_database_property(component, attribute_name, active_record_class)
            end
          end
        end
      end

      def to_open_api
        DSL.with_components(@components) do
          data = {
            openapi: "3.0.0",
            info: DSL.build_api_info,
            paths: DSL.build_paths(@endpoints),
            components: DSL.build_components(@components)
          }

          DSL.deep_transform_keys(data, &:to_s)
        end
      end
    end

    class DSL
      class << self
        attr_writer :default_spec
      end

      def self.default_spec
        @default_spec ||= Specification.new
      end

      def self.reset!
        @default_spec = Specification.new
      end

      def self.endpoints
        default_spec.endpoints
      end

      def self.components
        default_spec.components
      end

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
        when :integer
          "integer"
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
        default_spec.from_resource(name, resource, active_record_class, &block)
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
        when "integer", "bigint"
          integer_property_options(is_array_column, base_options)
        when "double precision", /numeric\(.*\)/
          numeric_property_options(is_array_column, base_options)
        when "string", /character varying/, "text"
          string_property_options(is_array_column, base_options)
        when "boolean"
          boolean_property_options(is_array_column, base_options)
        when "timestamp(6) without time zone"
          datetime_property_options(is_array_column, base_options)
        when "date"
          date_property_options(is_array_column, base_options)
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

      # Build property options for integer types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for integer type
      #
      # @private
      def self.integer_property_options(is_array_column, base_options)
        if is_array_column
          {type: :array, of: :integer, **base_options}
        else
          {type: :integer, **base_options}
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
          {type: :array, of: :datetime, **base_options}
        else
          {type: :datetime, format: :date_time, **base_options}
        end
      end

      # Build property options for date types.
      #
      # @param is_array_column [Boolean] Whether the column is an array type
      # @param base_options [Hash] Base property options
      # @return [Hash] Property options for date type
      #
      # @private
      def self.date_property_options(is_array_column, base_options)
        if is_array_column
          {type: :array, of: :date, **base_options}
        else
          {type: :date, format: :date, **base_options}
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
        default_spec.component(name, options, &block)
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
      def self.endpoint(&block)
        default_spec.endpoint(&block)
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
        item_type = property.as || property.of
        active_components.map(&:name).include?(item_type.to_s) ? {"$ref": "#/components/schemas/#{item_type}"} : schema_for_type(item_type)
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
        definition = case property.type
        when "array"
          array_property_definition(property)
        when "file"
          file_property_definition(property)
        when Array
          union_type_definition(property)
        else
          if property.as || (property.type == "object" && property.of)
            reference_property_definition(property)
          else
            standard_property_definition(property)
          end
        end

        [name, definition]
      end

      # Generate definition for a property that references a component schema.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Reference property definition
      #
      # @private
      def self.reference_property_definition(property)
        ref_name = property.as || property.of

        {
          "$ref" => "#/components/schemas/#{ref_name}",
          **merge_nullable(property)
        }
      end

      # Generate definition for an array property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Array property definition
      #
      # @private
      def self.array_property_definition(property)
        {
          type: openapi_schema_type(property),
          description: property.description,
          **merge_nullable(property),
          **schema_metadata(property),
          items: array_items_definition(property)
        }
      end

      # Generate the item schema for an array property.
      #
      # An enum declared on the array field constrains its *elements*, so it is
      # emitted on the items schema (never on the array itself). The enum is read
      # lazily, keeping deferred (callable) enums working. It is omitted when the
      # items are a component +$ref+, where a sibling +enum+ would be invalid.
      #
      # @param property [Property, Component, Response] The array property object
      # @return [Hash] OpenAPI items schema
      #
      # @private
      def self.array_items_definition(property)
        return {type: "object", **properties_to_json(property.properties)} if property.properties&.any? && !property.of

        items = property_to_items_type(property)
        items.merge!(properties_to_json(property.properties)) if property.of.to_s == "object" && property.properties
        items.merge!(merge_enum(property)) unless items.key?(:"$ref")
        items
      end

      # Generate definition for a file upload property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] OpenAPI binary string property definition
      #
      # @private
      def self.file_property_definition(property)
        {
          type: "string",
          format: "binary",
          description: property.description,
          **merge_nullable(property),
          **schema_metadata(property).except(:format)
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
          anyOf: property.type.map { |t| schema_for_type(t) },
          description: property.description,
          **merge_enum_and_nullable(property),
          **schema_metadata(property)
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
          type: openapi_schema_type(property),
          description: property.description,
          **merge_enum_and_nullable(property),
          **schema_metadata(property),
          **(property.properties ? properties_to_json(property.properties) : {})
        }
      end

      # Return the OpenAPI schema for a raw type value.
      #
      # @param raw_type [Symbol, String]
      # @return [Hash]
      #
      # @private
      def self.schema_for_type(raw_type)
        processed_type = process_type(raw_type)
        format = standard_format_for_type(processed_type)
        return {type: "string", format: format} if format

        {type: processed_type.to_s}
      end

      # Return the OpenAPI type for a property-like object.
      #
      # @param property [Property, Parameter, Component, Response] The property object
      # @return [String]
      #
      # @private
      def self.openapi_schema_type(property)
        format = standard_format_for_type(property.type)
        format ? "string" : property.type
      end

      # Return a standard OpenAPI string format for convenience date/email/UUID types.
      #
      # @param type [String, Symbol]
      # @return [String, nil]
      #
      # @private
      def self.standard_format_for_type(type)
        case type.to_s
        when "datetime", "date_time", "Dayjs"
          "date-time"
        when "date"
          "date"
        when "uuid"
          "uuid"
        when "email"
          "email"
        end
      end

      # Extract OpenAPI schema metadata fields from a property-like object.
      #
      # @param property [Property, Parameter, Component, Response] The property object
      # @return [Hash] OpenAPI schema metadata
      #
      # @private
      def self.schema_metadata(property)
        metadata = {}
        inferred_format = standard_format_for_type(property.type)
        explicit_format = normalize_format(property.format) if schema_metadata_present?(property, :format)
        metadata[:format] = explicit_format || inferred_format if explicit_format || inferred_format
        metadata[:example] = property.example if schema_metadata_present?(property, :example)
        metadata[:default] = property.default if schema_metadata_present?(property, :default)
        metadata[:minimum] = property.minimum if schema_metadata_present?(property, :minimum)
        metadata[:maximum] = property.maximum if schema_metadata_present?(property, :maximum)
        metadata[:minLength] = property.min_length if schema_metadata_present?(property, :min_length)
        metadata[:maxLength] = property.max_length if schema_metadata_present?(property, :max_length)
        if schema_metadata_present?(property, :pattern)
          pattern = property.pattern
          metadata[:pattern] = pattern.is_a?(Regexp) ? pattern.source : pattern.to_s
        end
        metadata[:minItems] = property.min_items if schema_metadata_present?(property, :min_items)
        metadata[:maxItems] = property.max_items if schema_metadata_present?(property, :max_items)
        metadata[:uniqueItems] = property.unique_items if schema_metadata_present?(property, :unique_items)
        metadata
      end

      def self.schema_metadata_present?(property, attribute)
        property.respond_to?(attribute) && !property.public_send(attribute).nil?
      end

      def self.normalize_format(format)
        case format.to_s
        when "date_time", "datetime"
          "date-time"
        else
          format.to_s
        end
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
        merge_enum(property).merge!(merge_nullable(property))
      end

      # Merge the enum attribute into a hash if the property defines one.
      #
      # Reads +allowable_values+/+enum+ lazily, so deferred (callable) enums are
      # resolved on each read. +enum+ takes precedence over +allowable_values+.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Hash containing the resolved enum, empty hash otherwise
      #
      # @private
      def self.merge_enum(property)
        result = {}
        result[:enum] = property.allowable_values if property.respond_to?(:allowable_values) && property.allowable_values
        result[:enum] = property.enum if property.respond_to?(:enum) && property.enum
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
        default_spec.to_open_api
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
      def self.build_paths(endpoints = default_spec.endpoints)
        endpoints.each_with_object({}) do |endpoint, paths|
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

        operation_hash[:summary] = endpoint.summary if endpoint.summary
        operation_hash[:description] = endpoint.description if endpoint.description
        operation_hash[:operationId] = endpoint.operation_id if endpoint.operation_id
        operation_hash[:tags] = endpoint.tags if endpoint.tags.any?
        operation_hash[:deprecated] = true if endpoint.deprecated
        operation_hash[:security] = stringify_security_requirements(endpoint.security) if endpoint.security

        if endpoint.request_body
          operation_hash[:requestBody] = build_request_body(endpoint.request_body)
        end

        operation_hash
      end

      # Convert OpenAPI security requirement keys to strings for JSON output.
      #
      # @param security [Array<Hash>, Hash]
      # @return [Array<Hash>]
      #
      # @private
      def self.stringify_security_requirements(security)
        Array(security).map do |requirement|
          requirement.transform_keys(&:to_s)
        end
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
            response.content_type => {
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
            request_body_media_type(request_body) => {
              schema: property_to_json("schema", request_body)[1].except(:description)
            }
          }
        }
      end

      # Return the OpenAPI media type for a request body definition.
      #
      # @param request_body [RequestBody] The request body definition
      # @return [String] OpenAPI media type
      #
      # @private
      def self.request_body_media_type(request_body)
        (request_body.type == "multipart") ? "multipart/form-data" : "application/json"
      end

      # Build the components section of the OpenAPI specification.
      #
      # @return [Hash] Components hash with schemas
      #
      # @private
      def self.build_components(components = default_spec.components)
        with_components(components) do
          {
            schemas: components.to_h { |component| property_to_json(component.name, component) }
          }
        end
      end

      def self.with_components(components)
        previous_components = Thread.current[:raxon_openapi_components]
        Thread.current[:raxon_openapi_components] = components
        yield
      ensure
        Thread.current[:raxon_openapi_components] = previous_components
      end

      def self.active_components
        Thread.current[:raxon_openapi_components] || default_spec.components
      end
    end
  end
end
