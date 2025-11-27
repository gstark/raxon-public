# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents an API response with schema and metadata.
    #
    # Responses define the structure and content type of data returned
    # by an API endpoint for specific HTTP status codes.
    #
    # @example Simple response
    #   Response.new(type: :object, as: :User, description: "User details")
    #
    # @example Array response
    #   Response.new(type: :array, of: :User, description: "List of users")
    #
    # @example Response with nested properties
    #   response = Response.new(type: :object, description: "Error details")
    #   response.property :error, type: :string
    #   response.property :code, type: :number
    #
    class Response
      extend Dry::Initializer

      # @!attribute [r] type
      #   @return [String] The response type (:object, :array, etc.), automatically processed
      option :type, proc { |value| OpenApi::DSL.process_type(value) }

      # @!attribute [r] as
      #   @return [Symbol, String, nil] Reference to a component schema
      option :as, optional: true

      # @!attribute [r] description
      #   @return [String] Response description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the response can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      attr_reader :options

      def initialize(**options)
        @options = options
        super
      end

      # Define a property within this response.
      #
      # @param name [Symbol, String] The property name
      # @param options [Hash] Property configuration options
      # @yield [Property] The property object for further configuration
      #
      # @example
      #   response.property :success, type: :boolean
      #   response.property :data, type: :object do |data|
      #     data.property :id, type: :number
      #   end
      def property(name, options, &block)
        @properties[name] = Property.new(**options)
        yield @properties[name] if block_given?
      end
    end
  end
end
