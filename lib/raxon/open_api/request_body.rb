# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents a request body with schema and metadata.
    #
    # RequestBody defines the structure and content type of data sent
    # in the body of an API request (typically for POST, PUT, PATCH operations).
    #
    # @example Simple request body
    #   RequestBody.new(type: :object, description: "User data")
    #
    # @example Request body with nested properties
    #   request_body = RequestBody.new(type: :object, description: "User data", required: true)
    #   request_body.property :name, type: :string
    #   request_body.property :email, type: :string
    #
    class RequestBody
      extend Dry::Initializer

      # @!attribute [r] type
      #   @return [String] The request body type (:object, :array, etc.), automatically processed
      option :type, proc { |value| OpenApi::DSL.process_type(value) }

      # @!attribute [r] as
      #   @return [Symbol, String, nil] Reference to a component schema
      option :as, optional: true

      # @!attribute [r] description
      #   @return [String] Request body description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the request body can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] required
      #   @return [Boolean] Whether the request body is required (default: true)
      option :required, default: proc { true }

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      attr_reader :options

      def initialize(**options)
        @options = options
        super
      end

      # Define a property within this request body.
      #
      # @param name [Symbol, String] The property name
      # @param options [Hash] Property configuration options
      # @yield [Property] The property object for further configuration
      #
      # @example
      #   request_body.property :name, type: :string
      #   request_body.property :address, type: :object do |address|
      #     address.property :street, type: :string
      #   end
      def property(name, options, &block)
        @properties[name] = Property.new(**options)
        yield @properties[name] if block_given?
      end
    end
  end
end
