# frozen_string_literal: true

require_relative "spec_version"
require_relative "type_system"

module Raxon
  module OpenApi
    # Turns DSL objects (Property, Parameter, Component, Response, RequestBody)
    # into OpenAPI schema hashes.
    #
    # Every emitted schema in the document comes from here; the document builder
    # only decides where each schema is placed. Emission needs to know which
    # components exist in order to choose between a +$ref+ and an inline schema,
    # and that set is carried in a thread-local established by
    # {SchemaEmitter.with_components} for the duration of a build.
    module SchemaEmitter
      COMPONENTS_KEY = :raxon_openapi_components

      module_function

      # Run a block with +components+ as the set of referenceable component
      # schemas. Nesting is safe: the previous set is restored on exit.
      #
      # @param components [Array<Component>]
      # @return [Object] the block's value
      def with_components(components)
        previous_components = Thread.current[COMPONENTS_KEY]
        Thread.current[COMPONENTS_KEY] = components
        yield
      ensure
        Thread.current[COMPONENTS_KEY] = previous_components
      end

      # The components referenceable by the schema currently being emitted.
      #
      # @return [Array<Component>]
      def active_components
        Thread.current[COMPONENTS_KEY] || DSL.default_spec.components
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
      def property_to_json(name, property)
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

      # Convert a hash of properties to OpenAPI JSON schema format.
      #
      # @param properties [Hash] Hash of property objects
      # @return [Hash] OpenAPI properties schema with required fields
      #
      # @example
      #   properties_to_json(properties)  # => {required: ["name"], properties: {...}}
      #
      def properties_to_json(properties)
        required_fields = properties.filter { |_, property| property.required }.keys.map(&:to_s)
        property_definitions = properties.to_h { |name, property| property_to_json(name, property) }.reject { |_name, definition| definition.nil? || definition.empty? }

        result = {}
        result[:required] = required_fields unless required_fields.empty?
        result[:properties] = property_definitions unless property_definitions.empty?
        result
      end

      # The schema for a property, with its +description+ stripped. Used where
      # OpenAPI carries the description on the enclosing object (parameters,
      # responses, request bodies) rather than on the schema itself.
      #
      # @param property [Property, Parameter, Response, RequestBody]
      # @return [Hash]
      def schema_without_description(property)
        property_to_json("schema", property)[1].except(:description)
      end

      # Convert a property to OpenAPI items specification for array types.
      #
      # @param property [Property] The property to convert
      # @return [Hash] OpenAPI items specification
      #
      # @example
      #   property_to_items_type(property)  # => {"$ref": "#/components/schemas/User"}
      #
      def property_to_items_type(property)
        item_type = property.as || property.of
        active_components.map(&:name).include?(item_type.to_s) ? {"$ref": "#/components/schemas/#{item_type}"} : schema_for_type(item_type)
      end

      # Generate definition for a property that references a component schema.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Reference property definition
      #
      # @private
      def reference_property_definition(property)
        ref = {"$ref" => "#/components/schemas/#{property.as || property.of}"}
        return ref unless property.respond_to?(:nullable) && property.nullable

        if SpecVersion.openapi_31?
          # DocumentBuilder rewrites this into an anyOf carrying a
          # {type: "null"} branch, since a $ref cannot hold sibling type info.
          ref.merge(nullable: true)
        else
          # In OpenAPI 3.0 a $ref ignores sibling keywords, so a bare
          # {$ref, nullable: true} silently drops the nullability. Express it
          # through allOf, which every 3.0 tool honors.
          {allOf: [ref], nullable: true}
        end
      end

      # Generate definition for an array property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Array property definition
      #
      # @private
      def array_property_definition(property)
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
      def array_items_definition(property)
        return {type: "object", **properties_to_json(property.properties)} if property.properties.any? && !property.of

        # An array with no declared element type and no nested properties has
        # unspecified items. Emit an empty schema (any value) rather than
        # {"type": ""}, which is invalid.
        return {} if property.of.nil? && property.as.nil?

        items = property_to_items_type(property)
        items.merge!(properties_to_json(property.properties)) if property.of.to_s == "object" && property.properties
        items.merge!(merge_enum(property)) unless items.key?(:$ref)
        items
      end

      # Generate definition for a file upload property.
      #
      # Byte limits are emitted through +x-max-bytes+. +maxLength+ remains a
      # character-length constraint when explicitly declared, rather than being
      # repurposed as a byte limit for a binary value.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] OpenAPI binary string property definition
      #
      # @private
      def file_property_definition(property)
        metadata = schema_metadata(property).except(:format)
        max_bytes = property.max_bytes || property.max_size if property.respond_to?(:max_size)
        metadata["x-max-bytes"] = max_bytes if max_bytes
        metadata["x-content-types"] = property.content_types if property.respond_to?(:content_types) && property.content_types

        {
          type: "string",
          format: "binary",
          description: property.description,
          **merge_nullable(property),
          **metadata
        }
      end

      # Generate definition for a union type property.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Union type (anyOf) property definition
      #
      # @private
      def union_type_definition(property)
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
      def standard_property_definition(property)
        {
          **schema_type_entry(property),
          description: property.description,
          **merge_enum_and_nullable(property),
          **schema_metadata(property),
          **properties_to_json(property.properties)
        }
      end

      # The {type: ...} entry for a property, omitted when the property declares
      # no type. A schema with no type is valid and matches any value; "type":
      # null is not valid in either 3.0 or 3.1.
      #
      # @param property [Property, Response]
      # @return [Hash]
      #
      # @private
      def schema_type_entry(property)
        type = openapi_schema_type(property)
        type.nil? ? {} : {type: type}
      end

      # Return the OpenAPI schema for a raw type value.
      #
      # @param raw_type [Symbol, String]
      # @return [Hash]
      #
      # @private
      def schema_for_type(raw_type)
        processed_type = TypeSystem.process_type(raw_type)
        format = TypeSystem.standard_format_for_type(processed_type)
        schema = format ? {type: "string", format: format} : {type: processed_type.to_s}
        schema.merge!(TypeSystem.type_extensions_for(processed_type))
        schema
      end

      # Return the OpenAPI type for a property-like object.
      #
      # +multipart+ is a Raxon-level marker that selects the
      # multipart/form-data media type for a request body; it is not a JSON
      # Schema type, and emitting it as one produced an invalid document for
      # every file-upload endpoint. The body itself is an object of form
      # fields, so that is what the schema says.
      #
      # @param property [Property, Parameter, Component, Response] The property object
      # @return [String]
      #
      # @private
      def openapi_schema_type(property)
        return "object" if property.type == "multipart"

        format = TypeSystem.standard_format_for_type(property.type)
        format ? "string" : property.type
      end

      # Extract OpenAPI schema metadata fields from a property-like object.
      #
      # @param property [Property, Parameter, Component, Response] The property object
      # @return [Hash] OpenAPI schema metadata
      #
      # @private
      def schema_metadata(property)
        metadata = {}
        inferred_format = TypeSystem.standard_format_for_type(property.type)
        explicit_format = TypeSystem.normalize_format(property.format) if schema_metadata_present?(property, :format)
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
        metadata[:readOnly] = true if property.respond_to?(:read_only) && property.read_only
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
      def schema_extensions(property)
        extensions = TypeSystem.type_extensions_for(property.type)
        if property.respond_to?(:extensions) && property.extensions.any?
          extensions = extensions.merge(property.extensions)
        end
        extensions
      end

      # @private
      def schema_metadata_present?(property, attribute)
        property.respond_to?(attribute) && !property.public_send(attribute).nil?
      end

      # Merge nullable attribute into a hash if the property is nullable.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Hash containing nullable: true if applicable, empty hash otherwise
      #
      # @private
      def merge_nullable(property)
        (property.respond_to?(:nullable) && property.nullable) ? {nullable: true} : {}
      end

      # Merge enum and nullable attributes into a hash.
      #
      # @param property [Property, Component, Response] The property object
      # @return [Hash] Hash containing enum and/or nullable attributes if applicable
      #
      # @private
      def merge_enum_and_nullable(property)
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
      def merge_enum(property)
        result = {}
        result[:enum] = property.allowable_values if property.respond_to?(:allowable_values) && property.allowable_values
        result[:enum] = property.enum if property.respond_to?(:enum) && property.enum
        result
      end
    end
  end
end
