# frozen_string_literal: true

module Raxon
  module OpenApi
    # Builds Dry::Schema fields from OpenAPI parameter/property definitions.
    #
    # Request and response validation both need to translate the same OpenAPI
    # field model into Dry::Schema macros. Keeping that translation here avoids
    # two subtly-divergent copies of required/optional, scalar, array, object,
    # nullable, and file handling.
    class PropertySchemaBuilder
      def add_parameter_to_schema(schema_context, param)
        add_field_to_schema(schema_context, param.name.to_sym, param)
      end

      def add_properties_to_schema(schema_context, properties)
        properties.each do |prop_name, property|
          add_property_to_schema(schema_context, prop_name, property)
        end
      end

      def add_property_to_schema(schema_context, prop_name, property)
        add_field_to_schema(schema_context, prop_name, property)
      end

      def add_field_to_schema(schema_context, field_name, field)
        case field.type
        when "object"
          add_object_field(schema_context, field_name, field)
        when "array"
          add_array_field(schema_context, field_name, field)
        when "file"
          add_file_field(schema_context, field_name, field)
        else
          add_scalar_field(schema_context, field_name, field)
        end
      end

      def dry_schema_type(field_type)
        case field_type
        when nil
          # An untyped property means "any type" in the emitted document (no
          # `type` key), so it must not be validated as a string at runtime.
          :any
        when "string", "datetime", "date_time", "date", "Dayjs", "uuid", "email"
          :string
        when "number"
          :float
        when "integer"
          :integer
        when "boolean"
          :bool
        when "array"
          :array
        when "object"
          :hash
        else
          :string
        end
      end

      private

      def add_object_field(schema_context, field_name, field)
        if field.properties.any?
          add_object_with_properties_field(schema_context, field_name, field)
        else
          add_hash_field(schema_context, field_name, field)
        end
      end

      def add_object_with_properties_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        builder = self

        if field.nullable
          key.maybe(:hash) do
            builder.add_properties_to_schema(self, field.properties)
          end
        else
          key.hash do
            builder.add_properties_to_schema(self, field.properties)
          end
        end
      end

      def add_hash_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)

        if field.nullable
          key.maybe(:hash)
        else
          key.value(:hash)
        end
      end

      def add_array_field(schema_context, field_name, field)
        if array_object_item_field?(field)
          add_array_object_item_field(schema_context, field_name, field)
        elsif array_scalar_item_type(field)
          add_array_scalar_item_field(schema_context, field_name, field)
        else
          add_scalar_field(schema_context, field_name, field)
        end
      end

      def add_array_object_item_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        builder = self

        constraints = dry_constraints_for(field, :array)

        if field.nullable
          key.maybe(:array, **constraints) do
            each(:hash) do
              builder.add_properties_to_schema(self, field.properties)
            end
          end
        elsif constraints.empty?
          key.array(:hash) do
            builder.add_properties_to_schema(self, field.properties)
          end
        else
          key.value(:array, **constraints).each(:hash) do
            builder.add_properties_to_schema(self, field.properties)
          end
        end
      end

      def add_array_scalar_item_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        item_type = array_scalar_item_type(field)

        constraints = dry_constraints_for(field, :array)
        # An enum on an array constrains each element, not the array itself
        # (matching the OpenAPI doc, which emits enum on the items schema).
        item_constraints = enum_constraint(field)

        if field.nullable
          key.maybe(:array, **constraints) do
            each(item_type, **item_constraints)
          end
        elsif constraints.empty?
          key.array(item_type, **item_constraints)
        else
          key.value(:array, **constraints).each(item_type, **item_constraints)
        end
      end

      def add_scalar_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        type = dry_schema_type(field.type)

        constraints = dry_constraints_for(field, type)

        return add_untyped_field(key, field, constraints) if type == :any

        if field.nullable
          key.maybe(type, **constraints)
        else
          key.value(type, **constraints)
        end
      end

      # An untyped property is "any type" in the emitted document, so it gets no
      # type predicate at runtime.
      #
      # It cannot go through the typed path above: dry-schema silently drops
      # predicates passed alongside :any — `value(:any, included_in?: [...])`
      # accepts anything — so a declared enum would vanish. Passing the
      # constraints with no type at all enforces them correctly.
      def add_untyped_field(key, field, constraints)
        if field.nullable
          constraints.empty? ? key.maybe(:any) : key.maybe(**constraints)
        elsif constraints.empty?
          key.value(:any)
        else
          key.value(**constraints)
        end
      end

      def add_file_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)

        if field.nullable
          key.maybe(:any)
        else
          key.filled
        end
      end

      def array_object_item_field?(field)
        field.properties.any? && (field.of.nil? || field.of.to_s == "object")
      end

      def array_scalar_item_type(field)
        return nil unless field.of

        type = dry_schema_type(field.of.to_s)
        return nil if type == :hash

        type
      end

      def field_key(schema_context, field_name, field)
        field.required ? schema_context.required(field_name) : schema_context.optional(field_name)
      end

      def dry_constraints_for(field, dry_type)
        constraints = {}

        if dry_type == :string
          # Order matters, and is load-bearing rather than stylistic. dry-schema
          # chains these predicates with a short-circuiting AND in declaration
          # order, so putting the cheap length checks ahead of format? means a
          # too-long value is rejected on size and the regexp is never run
          # against it at all. That caps the work a hostile oversized subject can
          # provoke before compile_pattern's timeout is even needed — the
          # structural half of the ReDoS defense. Reordering these three lines
          # silently removes it; property_schema_builder_spec pins the behavior.
          constraints[:min_size?] = field.min_length if field.respond_to?(:min_length) && field.min_length
          constraints[:max_size?] = field.max_length if field.respond_to?(:max_length) && field.max_length
          constraints[:format?] = compile_pattern(field.pattern) if field.respond_to?(:pattern) && field.pattern
        end

        if dry_type == :integer || dry_type == :float
          constraints[:gteq?] = field.minimum if field.respond_to?(:minimum) && field.minimum
          constraints[:lteq?] = field.maximum if field.respond_to?(:maximum) && field.maximum
        end

        if dry_type == :array
          constraints[:min_size?] = field.min_items if field.respond_to?(:min_items) && field.min_items
          constraints[:max_size?] = field.max_items if field.respond_to?(:max_items) && field.max_items
        end

        # Enforce the declared enum on scalar values. For arrays the enum
        # constrains each element (see add_array_scalar_item_field), so it is
        # never applied to the array itself here.
        constraints.merge!(enum_constraint(field)) unless dry_type == :array || dry_type == :hash

        constraints
      end

      # Compile a declared +pattern+ into a Regexp carrying the configured
      # per-match timeout, so a catastrophically-backtracking pattern raises
      # Regexp::TimeoutError on hostile input rather than pinning a CPU (ReDoS).
      # A nil timeout leaves the regexp unbounded (Ruby's default).
      #
      # @param pattern [String, Regexp]
      # @return [Regexp]
      def compile_pattern(pattern)
        Regexp.new(pattern.to_s, timeout: Raxon.configuration.regexp_timeout)
      end

      # Build the dry-schema inclusion constraint for a field's enum, or an
      # empty hash when none is declared. Reads +enum+/+allowable_values+ lazily
      # (resolving deferred callables on each read), with +enum+ taking
      # precedence over +allowable_values+ — mirroring the OpenAPI generator.
      def enum_constraint(field)
        values = enum_values(field)
        values ? {included_in?: values} : {}
      end

      def enum_values(field)
        return field.enum if field.respond_to?(:enum) && field.enum

        field.allowable_values if field.respond_to?(:allowable_values) && field.allowable_values
      end
    end
  end
end
