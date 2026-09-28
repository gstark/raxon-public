# frozen_string_literal: true

require_relative "deferred_enum"
require_relative "schema_options"
require_relative "strict_options"

module Raxon
  module OpenApi
    # Represents a property within a component, response, or nested object.
    #
    # Properties define individual fields with their types, constraints,
    # and validation rules. They can be simple scalar types or complex
    # nested objects and arrays.
    #
    # Most of its options are shared with {Parameter} via {SchemaOptions}; only
    # +type+, +description+, and +required+ are declared here, where the two
    # classes intentionally differ.
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
      include SchemaOptions

      # @!attribute [r] type
      #   @return [String, Array, nil] The property type (:string, :number, :boolean, :object, :array, or array of types for anyOf), automatically processed
      option :type, proc { |value| OpenApi::TypeSystem.process_type_option(value) }, optional: true

      # @!attribute [r] description
      #   @return [String] Property description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] required
      #   @return [Boolean] Whether the property is required (default: true)
      option :required, default: proc { true }

      # Construct a property, rejecting any unknown option (see {StrictOptions}).
      #
      # @param options [Hash] property configuration options
      # @raise [ArgumentError] when an unsupported option is supplied
      def initialize(**options)
        reject_unknown_options!(options)
        super
      end
    end
  end
end
