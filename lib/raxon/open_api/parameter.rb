# frozen_string_literal: true

require_relative "deferred_enum"

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
    # @example Enum parameter (e.g. a constrained path segment)
    #   Parameter.new(:format, in: :path, type: :string, enum: %w[pdf png])
    #
    # @example Deferred enum parameter (resolved lazily on read)
    #   Parameter.new(:format, in: :path, type: :string,
    #     enum: -> { RenditionRenderer::SUPPORTED_FORMATS })
    #
    class Parameter
      extend Dry::Initializer
      include DeferredEnum

      # @!attribute [r] name
      #   @return [Symbol, String] The parameter name
      param :name

      # @!attribute [r] in
      #   @return [Symbol] Where the parameter is located (:query, :path, :header, :cookie) (default: :query)
      option :in, default: proc { :query }

      # @!attribute [r] required
      #   @return [Boolean] Whether the parameter is required (defaults to true for path parameters, false otherwise)
      option :required, default: proc { self.in == :path }

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

      # @!attribute [r] enum
      #   @return [Array, nil] List of allowed values, surfaced in the generated
      #     OpenAPI schema. May be supplied as a callable (e.g. a lambda), which
      #     is stored unevaluated and resolved on every read — see {DeferredEnum}.
      option :enum, optional: true

      # @!attribute [r] allowable_values
      #   @return [Array, nil] Alias for enum - list of allowed values. May also
      #     be supplied as a callable resolved lazily — see {DeferredEnum}.
      option :allowable_values, optional: true

      # @!attribute [r] nullable
      #   @return [Boolean] Whether the parameter can be null (default: false)
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

      # @!attribute [r] properties
      #   @return [Hash] Hash of nested property definitions for body/object parameters
      option :properties, default: proc { {} }

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
