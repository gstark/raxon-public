# frozen_string_literal: true

require "rack/utils"

require_relative "component"
require_relative "endpoint"
require_relative "parameter"
require_relative "parameters"
require_relative "property"
require_relative "request_body"
require_relative "response"
require_relative "schema_introspection"

module Raxon
  module OpenApi
    # OpenApi DSL for generating OpenAPI 3.0 specifications from Ruby code.
    #
    # This class provides a domain-specific language for defining OpenAPI components,
    # endpoints, and specifications. It supports automatic schema generation from
    # Alba resources and database schemas (via SchemaIntrospection, which detects
    # whichever persistence library the host application uses).
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
      attr_reader :endpoints, :components, :security_schemes

      def initialize
        @endpoints = []
        @components = []
        @security_schemes = {}
      end

      def reset!
        @endpoints.clear
        @components.clear
        @security_schemes.clear
      end

      # Define a reusable security scheme, emitted under components.securitySchemes
      # and referenced from endpoints via endpoint.security. An optional block
      # makes the scheme enforceable at runtime (see SecurityScheme).
      #
      # @param name [Symbol, String] Registry name for endpoint.security references
      # @param options [Hash] Scheme fields (type:, name:, in:, scheme:, ...)
      # @return [SecurityScheme]
      def security_scheme(name, **options, &authenticator)
        scheme = SecurityScheme.new(name, **options, &authenticator)
        @security_schemes[scheme.name] = scheme
        scheme
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

      def from_resource(name, resource, model, &block)
        columns = SchemaIntrospection.model_columns(model)
        build_from_attributes(name, resource, columns, enum_source: model, &block)
      end

      def from_table(name, resource, table_name, &block)
        columns = SchemaIntrospection.table_columns(table_name)
        build_from_attributes(name, resource, columns, &block)
      end

      def to_open_api
        DSL.with_components(@components) do
          data = {
            openapi: DSL.openapi_version_string,
            info: DSL.build_api_info,
            paths: DSL.build_paths(@endpoints),
            components: DSL.build_components(@components, @security_schemes)
          }

          data = DSL.convert_nullable_to_type_arrays(data) if DSL.openapi_31?
          DSL.deep_transform_keys(data, &:to_s)
        end
      end

      private

      # Shared body of from_resource/from_table: block-declared properties
      # first, then Alba attributes resolved against the introspected columns
      # (nil when no database/adapter is available).
      def build_from_attributes(name, resource, columns, enum_source: nil)
        component(name, type: :object) do |component|
          yield component if block_given?

          resource._attributes.each do |attribute_name, definition|
            next if component.properties.key?(attribute_name.to_sym)

            if definition.is_a?(Alba::Association)
              DSL.build_association_property(component, attribute_name, definition)
            elsif definition.is_a?(Symbol) && columns
              column = columns[attribute_name.to_s]
              next if column.nil?

              allowable_values = enum_source ? SchemaIntrospection.enum_values(enum_source, attribute_name) : nil
              DSL.build_column_property(component, attribute_name, column, allowable_values: allowable_values)
            end
          end
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

      def self.security_schemes
        default_spec.security_schemes
      end

      # Define a security scheme on the default specification.
      #
      # @see Specification#security_scheme
      def self.security_scheme(name, **options, &authenticator)
        default_spec.security_scheme(name, **options, &authenticator)
      end

      # The `openapi` field value for the configured spec version.
      #
      # @return [String] "3.1.0" or "3.0.0"
      def self.openapi_version_string
        case Raxon.configuration.openapi_spec_version.to_s
        when "3.1", "3.1.0"
          "3.1.0"
        when "3.0", "3.0.0"
          "3.0.0"
        else
          raise ArgumentError, "Unsupported openapi_spec_version: #{Raxon.configuration.openapi_spec_version.inspect} (expected \"3.1\" or \"3.0\")"
        end
      end

      def self.openapi_31?
        openapi_version_string == "3.1.0"
      end

      # Rewrite 3.0-style +nullable: true+ schemas into their OpenAPI 3.1 form,
      # where null is expressed through the type system instead of a keyword:
      # a typed schema gains "null" in its type array, an anyOf gains a
      # +{type: "null"}+ branch, and a bare $ref is wrapped in an anyOf (a $ref
      # cannot carry sibling type information).
      #
      # @param node [Object] Emitted specification data (pre key-stringification)
      # @return [Object] The transformed data
      def self.convert_nullable_to_type_arrays(node)
        case node
        when Hash
          transformed = node.to_h { |key, value| [key, convert_nullable_to_type_arrays(value)] }
          convert_nullable_schema(transformed)
        when Array
          node.map { |value| convert_nullable_to_type_arrays(value) }
        else
          node
        end
      end

      def self.convert_nullable_schema(schema)
        return schema unless schema[:nullable] == true

        if schema.key?(:type)
          schema.delete(:nullable)
          schema[:type] = Array(schema[:type]) + ["null"]
          schema
        elsif schema.key?(:anyOf)
          schema.delete(:nullable)
          schema[:anyOf] += [{type: "null"}]
          schema
        elsif (ref = schema[:$ref] || schema["$ref"])
          {anyOf: [{"$ref" => ref}, {type: "null"}]}
        else
          # Not a schema this transform understands (e.g. literal example data);
          # leave it untouched.
          schema
        end
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

      # Validate and normalize an OpenAPI specification-extensions hash.
      #
      # OpenAPI requires specification extension keys to start with "x-"; any
      # other key raises immediately (see the No Silent Fallbacks tenet). Keys
      # are normalized to strings so explicit extensions and configured
      # type-level extensions merge predictably.
      #
      # @param extensions [Hash] Extension keys/values (e.g. {"x-ts-type" => "Dayjs"})
      # @return [Hash] The extensions with string keys
      # @raise [ArgumentError] When extensions is not a Hash or a key lacks the "x-" prefix
      def self.process_extensions(extensions)
        raise ArgumentError, "extensions must be a Hash, got #{extensions.class}" unless extensions.is_a?(Hash)

        extensions.each_key do |key|
          next if key.to_s.start_with?("x-")

          raise ArgumentError,
            "Invalid specification extension key: #{key.inspect}. " \
            "OpenAPI specification extension keys must start with \"x-\"."
        end

        extensions.transform_keys(&:to_s)
      end

      # Configured specification extensions for a DSL type name.
      #
      # Reads Raxon.configuration.openapi_type_extensions, which maps DSL type
      # names (e.g. :datetime, :date) to extension hashes applied to every
      # schema emitted with that type — including schemas generated by
      # from_resource/from_table, where there is no call site to pass
      # +extensions:+ explicitly.
      #
      # @param type [String, Symbol, Array, nil] The processed DSL type
      # @return [Hash] Extensions with string keys, empty when none configured
      #
      # @private
      def self.type_extensions_for(type)
        return {} unless type.is_a?(String) || type.is_a?(Symbol)

        configured = Raxon.configuration.openapi_type_extensions
        return {} unless configured&.any?

        extensions = configured[type.to_sym] || configured[type.to_s]
        extensions ? process_extensions(extensions) : {}
      end

      # Generate a component schema from an Alba resource and a model class.
      #
      # Automatically introspects the resource attributes and database schema
      # to generate appropriate OpenAPI component definitions with correct types,
      # descriptions, and validation constraints. Introspection goes through
      # SchemaIntrospection, so any supported persistence library (or a
      # configured adapter) works; with none available, only block-declared
      # properties are emitted.
      #
      # @param name [Symbol, String] The component name
      # @param resource [Alba::Resource] The Alba resource class
      # @param model [Class] The model class (e.g. an ActiveRecord model)
      # @yield [Component] The component object for additional configuration
      #
      # @example
      #   from_resource(:User, UserResource, User) do |component|
      #     component.property :custom_field, type: :string
      #   end
      #
      def self.from_resource(name, resource, model, &block)
        default_spec.from_resource(name, resource, model, &block)
      end

      # Generate a component schema from an Alba resource and a database table.
      #
      # Sibling to {from_resource} for tables that have no model class (e.g.
      # tables owned by a ROM relation). Columns are introspected through
      # SchemaIntrospection using the detected database library, so the same
      # type mapping applies.
      #
      # Unlike from_resource, inclusion validators cannot be introspected (there
      # is no model class), so enum-like properties must be declared in the block
      # via allowable_values.
      #
      # @param name [Symbol, String] The component name
      # @param resource [Alba::Resource] The Alba resource class
      # @param table_name [Symbol, String] The database table name
      # @yield [Component] The component object for additional configuration
      #
      # @example
      #   from_table(:ReleaseNote, ReleaseNoteResource, :release_notes) do |component|
      #     component.property :created_by_name, type: :string, nullable: true
      #   end
      #
      def self.from_table(name, resource, table_name, &block)
        default_spec.from_table(name, resource, table_name, &block)
      end

      # Build a property from an Alba association.
      #
      # @param component [Component] The component to add the property to
      # @param attribute_name [Symbol, String] The attribute name
      # @param definition [Alba::Association] The association definition
      # @return [void]
      #
      # @private
      def self.build_association_property(component, attribute_name, definition)
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
      #
      # @private
      def self.build_column_property(component, attribute_name, column, allowable_values: nil)
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
        when /\Atimestamp/
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
        return {type: "object", **properties_to_json(property.properties)} if property.properties.any? && !property.of

        items = property_to_items_type(property)
        items.merge!(properties_to_json(property.properties)) if property.of.to_s == "object" && property.properties
        items.merge!(merge_enum(property)) unless items.key?(:$ref)
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
          **properties_to_json(property.properties)
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
        schema = format ? {type: "string", format: format} : {type: processed_type.to_s}
        schema.merge!(type_extensions_for(processed_type))
        schema
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
        metadata.merge!(schema_extensions(property))
        metadata
      end

      # Specification extensions for a property-like object: configured
      # type-level extensions first, with the object's explicit +extensions:+
      # winning on key conflicts. Not emitted on $ref schemas ($ref siblings
      # are ignored in OpenAPI 3.0), which never call schema_metadata.
      #
      # @param property [Property, Parameter, Component, Response, RequestBody]
      # @return [Hash] Extensions with string keys
      #
      # @private
      def self.schema_extensions(property)
        extensions = type_extensions_for(property.type)
        if property.respond_to?(:extensions) && property.extensions.any?
          extensions = extensions.merge(property.extensions)
        end
        extensions
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
        property_definitions = properties.to_h { |name, property| property_to_json(name, property) }.reject { |_name, definition| definition.nil? || definition.empty? }

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
        declared, routed = endpoints.partition { |endpoint| endpoint.route_file_path.nil? }

        # Route-file endpoints are emitted after DSL-declared endpoints so that
        # on a path+method collision the route — the real, enforced
        # implementation — wins over a documentation-only declaration.
        (declared + routed).each_with_object({}) do |endpoint, paths|
          next if middleware_only_route?(endpoint)

          paths[endpoint.path] ||= {}
          endpoint.operations.each do |operation|
            paths[endpoint.path][operation] = build_operation_hash(endpoint)
          end
        end
      end

      # Whether an endpoint is a middleware-only route file (e.g. an all.rb
      # that only registers before/metadata blocks). These carry no handler and
      # describe no API surface of their own, so they are excluded from the
      # generated document. DSL-declared endpoints (no route file) are always
      # documented — they exist purely as documentation.
      #
      # @param endpoint [Endpoint]
      # @return [Boolean]
      #
      # @private
      def self.middleware_only_route?(endpoint)
        !endpoint.route_file_path.nil? && endpoint.handler_block.nil?
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
        endpoint.responses.to_h do |status, response|
          code = status_to_code(status)
          [code, build_response_object(response, code)]
        end
      end

      # Build a single response object.
      #
      # A response declared without a description gets the standard HTTP reason
      # phrase for its status code (e.g. "OK", "Not Found") — OpenAPI requires
      # the description field, and an empty string trips spec linters.
      #
      # @param response [Response] The response definition
      # @param status_code [Integer, nil] Numeric status code, used for the default description
      # @return [Hash] Response object with description, headers, and content
      #
      # @private
      def self.build_response_object(response, status_code = nil)
        description = response.description.to_s
        description = Rack::Utils::HTTP_STATUS_CODES.fetch(status_code, "") if description.empty?

        {
          description: description,
          headers: {},
          content: {
            response.content_type => {
              schema: property_to_json("schema", response)[1].except(:description)
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
      def self.build_components(components = default_spec.components, security_schemes = default_spec.security_schemes)
        with_components(components) do
          result = {
            schemas: components.to_h { |component| property_to_json(component.name, component) }
          }
          result[:securitySchemes] = security_schemes.transform_values(&:to_openapi) if security_schemes.any?
          result
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
