# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents a property within a component, response, or nested object.
    #
    # Properties define individual fields with their types, constraints,
    # and validation rules. They can be simple scalar types or complex
    # nested objects and arrays.
    #
    # @example Simple property
    #   Property.new(type: :string, description: "User name", required: true)
    #
    # @example Array property
    #   Property.new(type: :array, of: :string, description: "List of tags")
    #
    # @example Enum property
    #   Property.new(type: :string, enum: %w[active inactive], description: "User status")
    #
    # @example Nested object property
    #   property = Property.new(type: :object, description: "User profile")
    #   property.property :bio, type: :string
    #   property.property :age, type: :number
    #
    class Property
      extend Dry::Initializer

      # @!attribute [r] type
      #   @return [String, Array, nil] The property type (:string, :number, :boolean, :object, :array, or array of types for anyOf), automatically processed
      option :type, proc { |value| OpenApi::DSL.process_type(value) }, optional: true

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] description
      #   @return [String] Property description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] required
      #   @return [Boolean] Whether the property is required (default: true)
      option :required, default: proc { true }

      # @!attribute [r] as
      #   @return [Symbol, String, nil] Reference to a component schema
      option :as, optional: true

      # @!attribute [r] enum
      #   @return [Array, nil] List of allowed values
      option :enum, optional: true

      # @!attribute [r] allowable_values
      #   @return [Array, nil] Alias for enum - list of allowed values
      option :allowable_values, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the property can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] properties
      #   @return [Hash] Hash of nested property definitions for object types
      option :properties, default: proc { {} }

      # Define a nested property within this property.
      #
      # @param name [Symbol, String] The nested property name
      # @param options [Hash] Nested property configuration options
      # @yield [Property] The nested property object for further configuration
      #
      # @example
      #   property.property :address, type: :object do |address|
      #     address.property :street, type: :string
      #     address.property :city, type: :string
      #   end
      def property(name, options, &block)
        @properties[name] = Property.new(**options)
        yield @properties[name] if block_given?
      end
    end
  end
end
