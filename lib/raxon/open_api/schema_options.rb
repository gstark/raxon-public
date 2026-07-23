# frozen_string_literal: true

require_relative "deferred_enum"

module Raxon
  module OpenApi
    # The OpenAPI schema options shared verbatim by {Property} and {Parameter}.
    #
    # Both describe a JSON Schema field and carry the same constraint/metadata
    # vocabulary (of, enum, nullable, format, the numeric/length/array bounds,
    # extensions, nested properties). Declaring them once here keeps the two
    # classes from drifting. Options that legitimately differ between the two —
    # +type+, +description+, and +required+ — are intentionally left to each
    # class rather than shared.
    #
    # The including class must +extend Dry::Initializer+ and +include
    # DeferredEnum+ before including this module.
    module SchemaOptions
      def self.included(base)
        base.class_eval do
          # @!attribute [r] of
          #   @return [Symbol, String, nil] For array types, the element type
          option :of, optional: true

          # @!attribute [r] as
          #   @return [Symbol, String, nil] Reference to a component schema
          option :as, optional: true

          # @!attribute [r] enum
          #   @return [Array, nil] Allowed values. May be a callable resolved
          #     lazily on every read — see {DeferredEnum}.
          option :enum, optional: true

          # @!attribute [r] allowable_values
          #   @return [Array, nil] Alias for enum. May also be a callable
          #     resolved lazily — see {DeferredEnum}.
          option :allowable_values, optional: true

          # @!attribute [r] nullable
          #   @return [Boolean] Whether the value can be null (default: false)
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

          # @!attribute [r] max_size
          #   @return [Integer, nil] Maximum size in bytes for a +type: :file+
          #     field. Exceeding it answers 413. Note the name: +max_length+
          #     already means string length, so uploads get their own option.
          option :max_size, optional: true

          # Preferred declarative spelling for per-upload byte limits.
          option :max_bytes, optional: true

          # @!attribute [r] allowed_extensions
          #   @return [Array<String>, nil] Filename extensions accepted for a
          #     +type: :file+ field, without the leading dot (e.g. %w[jpg png]).
          #     Matched case-insensitively against the client-supplied filename,
          #     which is a usability check and not proof of content — see
          #     {Raxon::UploadedFile}. Named +allowed_extensions+ rather than
          #     +extensions+, which is taken by OpenAPI specification extensions.
          option :allowed_extensions, optional: true

          # Claimed MIME types accepted for a file upload. This is a transport
          # constraint, not a content-security assertion.
          option :content_types, optional: true

          # @!attribute [r] extensions
          #   @return [Hash] OpenAPI specification extensions merged into the
          #     emitted schema (e.g. {"x-ts-type" => "Dayjs"}). Keys must start
          #     with "x-".
          option :extensions, proc { |value| OpenApi::TypeSystem.process_extensions(value) }, default: proc { {} }

          # @!attribute [r] properties
          #   @return [Hash] Nested property definitions for object/array types
          option :properties, default: proc { {} }
        end
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
