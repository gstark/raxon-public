# frozen_string_literal: true

module Raxon
  module OpenApi
    # Resolves a request body's component references for request-time use.
    #
    # The emitted document keeps `as:`/`of:` references as `$ref`s, but at
    # runtime a reference is only useful expanded: an unresolved body compiled
    # to no schema at all, so a `body as: "User"` accepted any input, stripped
    # nothing, and coerced nothing — silently unlike the same properties
    # declared inline. This resolver inlines the referenced component's
    # properties (recursively, cycle-safe) and removes `read_only` properties,
    # which are response-direction fields a request must not supply.
    #
    # The resolved body feeds RequestSchemaGenerator, ParamResolver's
    # declared-key replacement, RequestBodyCoercer, and FileUploadValidator.
    # The declared body is never mutated — document emission keeps the `$ref`.
    #
    # Resolution is lenient where today's behavior is lenient (`of:` naming an
    # unknown component stays an unconstrained array) and strict where the
    # declaration is unambiguous: `as:` always names a component, so an unknown
    # `as:` reference raises rather than reintroducing the silent bypass.
    class RequestBodyResolver
      # @param components [Array<Component>] The referenceable components.
      #   Defaults to the application-wide specification's components, the same
      #   registry ResponseSchemaGenerator and SchemaEmitter fall back to.
      def initialize(components = DSL.components)
        @components = components.to_h { |component| [component.name, component] }
      end

      # @param request_body [RequestBody, nil]
      # @return [RequestBody, nil] +request_body+ itself when there is nothing
      #   to resolve, otherwise a resolved copy carrying +read_only_keys+
      # @raise [Raxon::OpenApi::Error] when +as:+ names an unknown component
      def call(request_body)
        return request_body if request_body.nil?

        @cyclic = false
        return resolve_array_body(request_body) if RequestSchemaGenerator.array_body?(request_body)
        return request_body unless needs_resolution?(request_body)

        properties, stack = body_properties(request_body)
        copy_attributes = RequestBody.dry_initializer.attributes(request_body)
        copy_attributes.delete(:as)
        copy_attributes[:properties] = resolve_properties(properties, stack)

        copy = RequestBody.new(**copy_attributes)
        copy.read_only_keys = properties.select { |_, property| property.read_only }.keys
        copy.cyclic = @cyclic
        copy
      end

      # Filter the validated params below each cycle point of a resolved body.
      #
      # Resolution stops at a component that refers to itself, and the schema
      # validates that point as an open object, so any key passes, read-only
      # fields included. This walks the data, which is finite, and at each
      # cycle point keeps only the component's declared properties that are
      # not read_only, at every depth.
      #
      # The nested values of an open object are the request's own source
      # hashes, so this builds new hashes and never changes them in place.
      #
      # @param request_body [RequestBody] A body returned by {#call}
      # @param params [Hash] Validated params
      # @return [Hash] The filtered params
      def filter_cycles(request_body, params)
        return params unless request_body.cyclic?
        return filter_properties(request_body.properties, params) unless RequestSchemaGenerator.array_body?(request_body)

        params.merge(body: map_hashes(params[:body]) { |item| filter_properties(request_body.properties, item) })
      end

      private

      # @param properties [Hash{Symbol => Property}]
      # @param data [Hash]
      # @return [Hash]
      def filter_properties(properties, data)
        properties.each_with_object(data.dup) do |(name, property), filtered|
          key = data.key?(name) ? name : name.to_s
          value = data[key]
          next if value.nil?

          reference = reference_name(property)
          component = reference && find_component(reference)
          if object_component?(component)
            filtered[key] = map_hashes(value) { |item| filter_component(component, item) }
          elsif property.properties.any?
            filtered[key] = map_hashes(value) { |item| filter_properties(property.properties, item) }
          end
        end
      end

      def filter_component(component, item)
        kept = component.properties.reject { |_, property| property.read_only }
        filter_properties(kept, item.select { |key, _| kept.key?(key.to_sym) })
      end

      # Yield a Hash, or each Hash in an Array, and return the replacements.
      def map_hashes(value)
        case value
        when Hash then yield value
        when Array then value.map { |item| item.is_a?(Hash) ? yield(item) : item }
        else value
        end
      end

      # A top-level array body whose `of:` names a component validates each
      # item against the component's properties. Inline item properties get
      # the same treatment as an object body's: references inlined and
      # read-only properties removed.
      def resolve_array_body(request_body)
        reference = reference_name(request_body)
        component = reference && find_component(reference)
        if object_component?(component)
          properties, stack = component.properties, [component.name]
        elsif properties_need_resolution?(request_body.properties)
          properties, stack = request_body.properties, []
        else
          return request_body
        end

        copy_attributes = RequestBody.dry_initializer.attributes(request_body)
        copy_attributes[:of] = :object
        copy_attributes[:properties] = resolve_properties(properties, stack)
        copy = RequestBody.new(**copy_attributes)
        copy.cyclic = @cyclic
        copy
      end

      # @return [Array(Hash, Array<String>)] The top-level property set (the
      #   referenced component's when the body is an `as:` reference, with any
      #   inline declarations winning by name) and the initial cycle-detection
      #   stack.
      def body_properties(request_body)
        return [request_body.properties, []] unless request_body.as

        component = find_component!(request_body.as, "request body")
        return [request_body.properties, []] unless object_component?(component)

        [component.properties.merge(request_body.properties), [component.name]]
      end

      def needs_resolution?(request_body)
        !!request_body.as || properties_need_resolution?(request_body.properties)
      end

      def properties_need_resolution?(properties)
        properties.any? do |_, property|
          property.read_only || reference_name(property) || properties_need_resolution?(property.properties)
        end
      end

      # Rebuild a property set with references inlined and read-only properties
      # removed. Properties that need no change are reused as-is.
      def resolve_properties(properties, stack)
        properties.each_with_object({}) do |(name, property), resolved|
          next if property.read_only

          resolved[name] = resolve_property(property, stack)
        end
      end

      def resolve_property(property, stack)
        if (reference = reference_name(property))
          resolve_reference(property, reference, stack)
        elsif property.properties.any?
          resolved = resolve_properties(property.properties, stack)
          (resolved == property.properties) ? property : copy_with_properties(property, resolved)
        else
          property
        end
      end

      # The component name a property references, or nil. Mirrors the
      # emitter's rules: `as:` is always a reference; `of:` is one for arrays
      # (unless it names a built-in type) and for `type: :object`.
      def reference_name(property)
        return property.as if property.as
        return nil unless property.of

        case property.type
        when "array"
          TypeSystem::KNOWN_TYPES.include?(property.of.to_s.to_sym) ? nil : property.of
        when "object"
          property.of
        end
      end

      # Replace a reference property with the referenced component's properties
      # inlined. A cycle (a component reachable from itself) stops expanding at
      # the repeated component, which then validates as an open object — the
      # pre-resolution behavior. An `of:` reference to an unknown component
      # also keeps today's behavior (an unconstrained array).
      def resolve_reference(property, reference, stack)
        component = if property.as
          find_component!(reference, "property")
        else
          find_component(reference)
        end
        return property unless object_component?(component)
        if stack.include?(component.name)
          @cyclic = true
          return property
        end

        resolved = resolve_properties(component.properties, stack + [component.name])

        if property.type == "array"
          Property.new(type: :array, of: :object, required: property.required, nullable: property.nullable,
            min_items: property.min_items, max_items: property.max_items, properties: resolved)
        else
          Property.new(type: :object, required: property.required, nullable: property.nullable, properties: resolved)
        end
      end

      def copy_with_properties(property, resolved)
        attributes = Property.dry_initializer.attributes(property)
        attributes[:properties] = resolved
        Property.new(**attributes)
      end

      # Only an object-shaped component can be inlined as properties; a scalar
      # or otherwise shapeless component leaves the reference unresolved.
      def object_component?(component)
        return false if component.nil?

        component.type == "object" || component.properties.any?
      end

      def find_component(name)
        @components[name.to_s]
      end

      def find_component!(name, context)
        find_component(name) || raise(Error, "Request body resolution failed: #{context} references unknown component #{name.inspect}")
      end
    end
  end
end
