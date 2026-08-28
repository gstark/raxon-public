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
        @components = components
      end

      # @param request_body [RequestBody, nil]
      # @return [RequestBody, nil] +request_body+ itself when there is nothing
      #   to resolve, otherwise a resolved copy carrying +read_only_keys+
      # @raise [Raxon::OpenApi::Error] when +as:+ names an unknown component
      def call(request_body)
        return request_body if request_body.nil?
        return request_body unless needs_resolution?(request_body)

        properties, stack = body_properties(request_body)
        copy_attributes = RequestBody.dry_initializer.attributes(request_body)
        copy_attributes.delete(:as)
        copy_attributes[:properties] = resolve_properties(properties, stack)

        copy = RequestBody.new(**copy_attributes)
        copy.read_only_keys = properties.select { |_, property| property.read_only }.keys
        copy
      end

      private

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
        return property if stack.include?(component.name)

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
        @components.find { |component| component.name == name.to_s }
      end

      def find_component!(name, context)
        find_component(name) || raise(Error, "Request body resolution failed: #{context} references unknown component #{name.inspect}")
      end
    end
  end
end
