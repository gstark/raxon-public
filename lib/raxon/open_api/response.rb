# frozen_string_literal: true

require_relative "deferred_enum"
require_relative "strict_options"

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
    # @example Array response constrained to an enum of element values
    #   Response.new(type: :array, of: :string, enum: %w[draft published])
    #
    # @example Response with nested properties
    #   response = Response.new(type: :object, description: "Error details")
    #   response.property :error, type: :string
    #   response.property :code, type: :number
    #
    class Response
      extend Dry::Initializer
      include PropertyContainer
      include DeferredEnum
      include StrictOptions

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

      # @!attribute [r] enum
      #   @return [Array, nil] List of allowed values, surfaced in the generated
      #     OpenAPI schema. For an array response the enum constrains the array's
      #     *elements* (emitted on the items schema). May be supplied as a callable
      #     resolved lazily on every read — see {DeferredEnum}.
      option :enum, optional: true

      # @!attribute [r] allowable_values
      #   @return [Array, nil] Alias for enum - list of allowed values. May also
      #     be supplied as a callable resolved lazily — see {DeferredEnum}.
      option :allowable_values, optional: true

      # @!attribute [r] content_type
      #   @return [String] The response media type, used as the +content+ key in
      #     the generated OpenAPI response object (default: "application/json").
      #     Set this for non-JSON responses such as +"text/csv"+.
      option :content_type, default: proc { "application/json" }

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the response can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      attr_reader :options

      # Construct a response, rejecting any unknown option (see {StrictOptions}).
      #
      # @param options [Hash] response configuration options
      # @raise [ArgumentError] when an unsupported option is supplied
      def initialize(**options)
        reject_unknown_options!(options)
        @options = options
        super
      end

      # Resolve a deferred (callable) +enum+ lazily on read. See {DeferredEnum}.
      # @return [Array, nil]
      def enum
        resolve_deferred_enum(super)
      end

      # Resolve a deferred (callable) +allowable_values+ lazily on read.
      # See {DeferredEnum}.
      # @return [Array, nil]
      def allowable_values
        resolve_deferred_enum(super)
      end
    end
  end
end
