# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents a reusable OpenAPI component schema.
    #
    # Components define reusable schemas that can be referenced throughout
    # the OpenAPI specification. They can represent objects, arrays, or other
    # complex types with nested properties.
    #
    # @example Define a User component
    #   component = Component.new(:User, type: :object, description: "A user in the system")
    #   component.property :name, type: :string, description: "Full name"
    #   component.property :email, type: :string, description: "Email address"
    #
    class Component
      extend Dry::Initializer

      # @!attribute [r] name
      #   @return [Symbol, String] The component name
      param :name

      # @!attribute [r] type
      #   @return [String] The base type (:object, :array, etc.), automatically processed
      option :type, proc { |value| OpenApi::DSL.process_type(value) }

      # @!attribute [r] description
      #   @return [String] Component description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      attr_reader :as

      # Define a property within this component.
      #
      # @param name [Symbol, String] The property name
      # @param options [Hash] Property configuration options
      # @yield [Property] The property object for further configuration
      #
      # @example
      #   component.property :name, type: :string, required: true
      #   component.property :profile, type: :object do |profile|
      #     profile.property :bio, type: :string
      #   end
      def property(name, options, &block)
        @properties[name] = Property.new(**options)

        yield @properties[name] if block_given?
      end
    end
  end
end
