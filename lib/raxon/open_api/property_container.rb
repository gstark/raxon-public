# frozen_string_literal: true

module Raxon
  module OpenApi
    # Shared builder for the OpenAPI classes that hold a tree of nested property
    # definitions: Property, Response, RequestBody, Component, and Parameter.
    #
    # Each of those carries a `@properties` hash (a Dry::Initializer
    # `option :properties, default: proc { {} }`) and defines nested properties
    # the same way. This module is that one definition, so adding or changing how
    # a property is built happens in a single place rather than five.
    #
    # @example
    #   component.property :profile, type: :object do |profile|
    #     profile.property :bio, type: :string
    #   end
    module PropertyContainer
      # Define a (possibly nested) property by name.
      #
      # Options are optional: `property :notes` declares an untyped property,
      # which is "any type" in the emitted document and unconstrained at
      # runtime.
      #
      # @param name [Symbol, String] The property name
      # @param options [Hash] Property configuration options
      # @yield [Property] The created property, for nested configuration
      # @return [void]
      def property(name, options = {}, &block)
        # Normalize the key so `property("id", …)` and `property(:id, …)`
        # address the same property instead of emitting two. This also lets the
        # from_resource/from_table override check (which looks up by symbol)
        # suppress an introspected column when either key form is declared.
        @properties[name.to_sym] = Property.new(**options)
        yield @properties[name.to_sym] if block_given?
      end
    end
  end
end
