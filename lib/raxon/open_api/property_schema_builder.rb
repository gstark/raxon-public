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
      # A `datetime`/`date` field is a string on the wire, and a request can only
      # ever carry it as one. A *response* is different: a handler that returns
      # domain objects hands back a Time, Date, or DateTime, and JSON.generate
      # turns it into exactly the string the schema describes. Validating those
      # as strings rejects bodies that are correct once serialized, so accept
      # either form. ActiveSupport::TimeWithZone answers is_a?(Time), so it is
      # covered by the Time branch.
      TEMPORAL = (
        Dry::Types["strict.string"] |
        Dry::Types["strict.time"] |
        Dry::Types["strict.date"] |
        Dry::Types["strict.date_time"]
      ).freeze

      # Any hex UUID in the 8-4-4-4-12 form, of any version.
      UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # A `uuid` or `email` field is a string that must also match its format,
      # so a :uuid path parameter cannot carry ../../etc/passwd. The email
      # regexp is the HTML living standard's, which URI ships.
      FORMATTED = {
        uuid: Dry::Types["strict.string"].constrained(format: UUID_FORMAT),
        email: Dry::Types["strict.string"].constrained(format: URI::MailTo::EMAIL_REGEXP)
      }.freeze

      # Dry types that take the string length and pattern constraints.
      STRING_TYPES = [:string, :uuid, :email].freeze

      # A number must be finite. Float("1e400") and JSON 1e400 both give
      # Infinity, which passes a float type check and any minimum.
      FINITE = {gt?: -Float::INFINITY, lt?: Float::INFINITY}.freeze

      # A `number` in a response body. A request's :float coerces 5 to 5.0, but
      # a response schema coerces nothing, and 5 is a valid JSON number. A
      # BigDecimal is one too: Raxon::JSONEncoder writes it as a number.
      RESPONSE_NUMBER = (Dry::Types["strict.integer"] | Dry::Types["strict.float"] | Dry::Types["strict.decimal"]).freeze

      # An integer in a request. params.integer coerces with Integer(), which
      # truncates a Float: 4.5 became 4 and the fraction was silently lost.
      # Handing it the fraction as a String makes Integer() reject it, so it
      # answers "must be an integer"; a whole 4.0 still coerces to 4.
      WHOLE_INTEGER = Dry::Types["params.integer"].prepend { |value|
        (value.is_a?(Float) && value.finite? && value != value.truncate) ? value.to_s : value
      }.freeze

      # @param response [Boolean] Build fields for a response schema. A
      #   response schema checks the values the handler returns and coerces
      #   none of them, so `number` must accept an Integer as well as a Float.
      def initialize(response: false)
        @response = response
      end

      def add_parameter_to_schema(schema_context, param)
        add_field_to_schema(schema_context, param.name, param)
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
        return add_union_field(schema_context, field_name, field) if field.type.is_a?(Array)

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
        when "datetime", "date_time", "date", "Dayjs"
          :temporal
        when "uuid"
          :uuid
        when "email"
          :email
        when "string"
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

        type = runtime_type(type)

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

      # A union type (`type: [:string, :number]`) accepts a value any member
      # accepts, as the anyOf in the document says. Before this it had no case
      # of its own, fell through dry_schema_type to :string, and rejected every
      # value that was not a string.
      def add_union_field(schema_context, field_name, field)
        key = field_key(schema_context, field_name, field)
        type = field.type.map { |member| union_member_type(member) }.reduce(:|)
        constraints = enum_constraint(field)

        if field.nullable
          key.maybe(type, **constraints)
        else
          key.value(type, **constraints)
        end
      end

      # The dry type for one member of a union. A sum needs type objects, not
      # the symbols the other fields pass, and a request member coerces where
      # a response member does not.
      def union_member_type(member)
        case dry_schema_type(member.to_s)
        when :string then Dry::Types["strict.string"]
        when :float then @response ? RESPONSE_NUMBER : Dry::Types["params.float"]
        when :integer then @response ? Dry::Types["strict.integer"] : WHOLE_INTEGER
        when :bool then Dry::Types[@response ? "strict.bool" : "params.bool"]
        when :hash then Dry::Types["strict.hash"]
        when :array then Dry::Types["strict.array"]
        when :any then Dry::Types["any"]
        else runtime_type(dry_schema_type(member.to_s))
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

      # Item types `of:` can name. Anything else is a component reference — a
      # `$ref` in the emitted document — and must not be validated as a scalar.
      SCALAR_ITEM_TYPES = %w[string number integer boolean datetime date_time date Dayjs uuid email].freeze

      def array_scalar_item_type(field)
        return nil unless field.of

        # `of: "Widget"` describes an array of objects. Falling through to
        # dry_schema_type's else branch typed those items as *strings*, so a
        # correct array-of-objects body was rejected with "must be a string" —
        # the array is still validated as an array, just without a per-item
        # constraint the reference cannot supply here.
        return nil unless SCALAR_ITEM_TYPES.include?(field.of.to_s)

        type = dry_schema_type(field.of.to_s)
        return nil if type == :hash

        runtime_type(type)
      end

      # The type dry-schema checks for a dry_schema_type symbol.
      #
      # @param type [Symbol]
      # @return [Symbol, Dry::Types::Type]
      def runtime_type(type)
        return TEMPORAL if type == :temporal
        return RESPONSE_NUMBER if type == :float && @response
        return WHOLE_INTEGER if type == :integer && !@response

        FORMATTED.fetch(type, type)
      end

      def field_key(schema_context, field_name, field)
        field.required ? schema_context.required(field_name) : schema_context.optional(field_name)
      end

      def dry_constraints_for(field, dry_type)
        constraints = {}

        if STRING_TYPES.include?(dry_type)
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

        constraints.merge!(FINITE) if dry_type == :float

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
