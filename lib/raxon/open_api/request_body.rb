# frozen_string_literal: true

require_relative "deferred_enum"
require_relative "strict_options"

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
      include PropertyContainer
      include DeferredEnum
      include StrictOptions

      # @!attribute [r] type
      #   @return [String] The request body type (:object, :array, etc.), automatically processed
      option :type, proc { |value| OpenApi::TypeSystem.process_type_option(value) }

      # @!attribute [r] as
      #   @return [Symbol, String, nil] Reference to a component schema
      option :as, optional: true

      # @!attribute [r] description
      #   @return [String] Request body description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] enum
      #   @return [Array, nil] List of allowed values, surfaced in the generated
      #     schema. May be supplied as a callable resolved lazily — see {DeferredEnum}.
      option :enum, optional: true

      # @!attribute [r] allowable_values
      #   @return [Array, nil] Alias for enum. May also be a callable resolved
      #     lazily — see {DeferredEnum}.
      option :allowable_values, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the request body can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] required
      #   @return [Boolean] Whether the request body is required (default: true)
      option :required, default: proc { true }

      # @!attribute [r] max_total_size
      #   @return [Integer, nil] Combined byte ceiling for every upload in the
      #     body. Exceeding it answers 413. Applies across all file fields, so a
      #     request that stays under each individual +max_size+ can still be
      #     rejected for its total.
      option :max_total_size, optional: true

      # @!attribute [r] extensions
      #   @return [Hash] OpenAPI specification extensions merged into the emitted
      #     schema (e.g. {"x-ts-type" => "Dayjs"}). Keys must start with "x-".
      option :extensions, proc { |value| OpenApi::TypeSystem.process_extensions(value) }, default: proc { {} }

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      # Construct a request body, rejecting any unknown option (see {StrictOptions}).
      #
      # @param options [Hash] request body configuration options
      # @raise [ArgumentError] when an unsupported option is supplied
      def initialize(**options)
        reject_unknown_options!(options)
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
