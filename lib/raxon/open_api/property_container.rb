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
      # @param name [Symbol, String] The property name
      # @param options [Hash] Property configuration options
      # @yield [Property] The created property, for nested configuration
      # @return [void]
      def property(name, options, &block)
        @properties[name] = Property.new(**options)
        yield @properties[name] if block_given?
      end
    end
  end
end
