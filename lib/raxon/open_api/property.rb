# frozen_string_literal: true

require_relative "deferred_enum"
require_relative "strict_options"

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
    # @example Deferred enum property (resolved lazily on read)
    #   Property.new(type: :string, enum: -> { MyModel::SUPPORTED_KINDS })
    #
    # @example Nested object property
    #   property = Property.new(type: :object, description: "User profile")
    #   property.property :bio, type: :string
    #   property.property :age, type: :number
    #
    class Property
      extend Dry::Initializer
      include PropertyContainer
      include DeferredEnum
      include StrictOptions

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
      #   @return [Array, nil] List of allowed values. May be supplied as a
      #     callable (e.g. a lambda), which is stored unevaluated and resolved on
      #     every read — see {DeferredEnum}.
      option :enum, optional: true

      # @!attribute [r] allowable_values
      #   @return [Array, nil] Alias for enum - list of allowed values. May also
      #     be supplied as a callable resolved lazily — see {DeferredEnum}.
      option :allowable_values, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the property can be null (default: false)
      option :nullable, default: proc { false }

      # @!attribute [r] format
      #   @return [String, Symbol, nil] OpenAPI string format
      option :format, optional: true

      # @!attribute [r] example
      #   @return [Object, nil] OpenAPI example value
      option :example, optional: true

      # @!attribute [r] default
      #   @return [Object, nil] OpenAPI default value
      option :default, optional: true

      # @!attribute [r] minimum
      #   @return [Numeric, nil] Minimum numeric value
      option :minimum, optional: true

      # @!attribute [r] maximum
      #   @return [Numeric, nil] Maximum numeric value
      option :maximum, optional: true

      # @!attribute [r] min_length
      #   @return [Integer, nil] Minimum string length
      option :min_length, optional: true

      # @!attribute [r] max_length
      #   @return [Integer, nil] Maximum string length
      option :max_length, optional: true

      # @!attribute [r] pattern
      #   @return [String, Regexp, nil] String pattern constraint
      option :pattern, optional: true

      # @!attribute [r] min_items
      #   @return [Integer, nil] Minimum array item count
      option :min_items, optional: true

      # @!attribute [r] max_items
      #   @return [Integer, nil] Maximum array item count
      option :max_items, optional: true

      # @!attribute [r] unique_items
      #   @return [Boolean, nil] Whether array items must be unique
      option :unique_items, optional: true

      # @!attribute [r] extensions
      #   @return [Hash] OpenAPI specification extensions merged into the emitted
      #     schema (e.g. {"x-ts-type" => "Dayjs"}). Keys must start with "x-".
      option :extensions, proc { |value| OpenApi::DSL.process_extensions(value) }, default: proc { {} }

      # @!attribute [r] properties
      #   @return [Hash] Hash of nested property definitions for object types
      option :properties, default: proc { {} }

      # Construct a property, rejecting any unknown option (see {StrictOptions}).
      #
      # @param options [Hash] property configuration options
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
