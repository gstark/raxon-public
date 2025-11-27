# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents a single parameter for an API endpoint.
    #
    # Parameters can be located in different parts of the request (path, query,
    # header, etc.) and have various types and validation rules.
    #
    # @example Path parameter
    #   Parameter.new(:id, type: :string, in: :path, description: "Resource ID")
    #
    # @example Optional query parameter
    #   Parameter.new(:limit, type: :number, in: :query, required: false)
    #
    class Parameter
      extend Dry::Initializer

      # @!attribute [r] name
      #   @return [Symbol, String] The parameter name
      param :name

      # @!attribute [r] in
      #   @return [Symbol] Where the parameter is located (:query, :path, :header, :cookie) (default: :query)
      option :in, default: proc { :query }

      # @!attribute [r] required
      #   @return [Boolean] Whether the parameter is required (default: true)
      option :required, default: proc { true }

      # @!attribute [r] type
      #   @return [String] The parameter type, automatically processed
      option :type, proc { |value| OpenApi::DSL.process_type(value) }

      # @!attribute [r] description
      #   @return [String, nil] Parameter description
      option :description, optional: true

      # @!attribute [r] as
      #   @return [Symbol, String, nil] Reference to a component schema
      option :as, optional: true

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the parameter can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] properties
      #   @return [Hash] Hash of nested property definitions for body/object parameters
      option :properties, default: proc { {} }

      # Define a nested property within this parameter (for body/object parameters).
      #
      # @param name [Symbol, String] The nested property name
      # @param options [Hash] Nested property configuration options
      # @yield [Property] The nested property object for further configuration
      #
      # @example
      #   parameter.property :auto_scale, type: :boolean, description: "Whether to auto scale"
      #   parameter.property :address, type: :object do |address|
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
