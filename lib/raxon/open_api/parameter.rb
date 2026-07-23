# frozen_string_literal: true

require_relative "deferred_enum"
require_relative "schema_options"
require_relative "strict_options"

module Raxon
  module OpenApi
    # Represents a single parameter for an API endpoint.
    #
    # Parameters can be located in different parts of the request (path, query,
    # header, etc.) and have various types and validation rules.
    #
    # Most of its options are shared with {Property} via {SchemaOptions}; only
    # +type+, +description+, +required+, plus the parameter-specific +name+ and
    # +in+, are declared here.
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
      include PropertyContainer
      include DeferredEnum
      include StrictOptions
      include SchemaOptions

      # Valid OpenAPI parameter locations.
      LOCATIONS = %i[query header path cookie].freeze

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
      option :type, proc { |value| OpenApi::TypeSystem.process_type_option(value) }

      # @!attribute [r] description
      #   @return [String, nil] Parameter description
      option :description, optional: true

      # Construct a parameter, rejecting any unknown option (see {StrictOptions}).
      #
      # @param name [Symbol, String] the parameter name
      # @param options [Hash] parameter configuration options
      # @raise [ArgumentError] when an unsupported option is supplied
      def initialize(name, **options)
        reject_unknown_options!(options)
        validate_location!(options[:in])
        validate_body_only_type!(name, options[:type])
        super
      end

      # Types that only mean something in a request body. A parameter is
      # serialized into a URL, header, or cookie, and OpenAPI defines no
      # serialization for binary data in any of those places — so `type: :file`
      # on a parameter cannot be described in the generated document no matter
      # what the runtime does with it.
      BODY_ONLY_TYPES = %i[file multipart].freeze

      # Reject a body-only type on a parameter.
      #
      # Without this the declaration half-works, which is worse than either
      # extreme: an `in: :query` parameter is validated against the lenient
      # source merge (see ParamResolver#assemble_validation), which includes
      # form params, so a real multipart upload does reach it — but neither
      # FileUploadValidator nor RequestBodyCoercer consults parameters, so the
      # handler receives the raw Rack hash instead of the documented
      # Raxon::UploadedFile, and a non-file value passes validation entirely.
      #
      # @param name [Symbol, String] the parameter name, for the message
      # @param type [Symbol, String, Array, nil]
      # @raise [Error] when the type is body-only
      # @return [void]
      def validate_body_only_type!(name, type)
        offending = Array(type).find { |member| BODY_ONLY_TYPES.include?(member.to_s.to_sym) }
        return if offending.nil?

        raise Error,
          "type: #{offending.to_sym.inspect} is not valid for a parameter (#{name}). " \
          "Declare uploads in the request body:\n" \
          "  endpoint.body type: :multipart do |body|\n" \
          "    body.property :#{name}, type: :file\n" \
          "  end"
      end
      private :validate_body_only_type!

      # Reject an unknown +in:+ location. A typo (e.g. +in: :qeury+) otherwise
      # produces an invalid OpenAPI document and a parameter that is never
      # sourced at runtime — a silent failure.
      #
      # @param location [Symbol, String, nil]
      # @raise [ArgumentError] when the location is not a valid OpenAPI location
      # @return [void]
      def validate_location!(location)
        return if location.nil?
        return if LOCATIONS.include?(location.to_sym)

        raise ArgumentError,
          "invalid `in:` location for #{self.class}: #{location.inspect}. " \
          "Valid locations: #{LOCATIONS.join(", ")}."
      end
      private :validate_location!
    end
  end
end
