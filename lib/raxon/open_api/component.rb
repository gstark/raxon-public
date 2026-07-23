# frozen_string_literal: true

require_relative "strict_options"

module Raxon
  module OpenApi
    # Represents a reusable OpenAPI component schema.
    #
    # Components define reusable schemas that can be referenced throughout
    # the OpenAPI specification. They can represent objects, arrays, or other
    # complex types with nested properties.
    #
    # @example Define a User component
    #   component = Component.new(:User, type: :object, description: "A user in the system")
    #   component.property :name, type: :string, description: "Full name"
    #   component.property :email, type: :string, description: "Email address"
    #
    class Component
      extend Dry::Initializer
      include PropertyContainer
      include StrictOptions

      # @!attribute [r] name
      #   @return [String] The component name, normalized to a String so that
      #     `component(:User)` and `component("User")` register and resolve
      #     identically (a Symbol name previously broke `$ref` matching for
      #     `of:`/`as:` references).
      param :name, proc(&:to_s)

      # @!attribute [r] type
      #   @return [String] The base type (:object, :array, etc.), automatically processed
      option :type, proc { |value| OpenApi::TypeSystem.process_type_option(value) }

      # @!attribute [r] description
      #   @return [String] Component description (default: "")
      option :description, default: proc { "" }

      # @!attribute [r] of
      #   @return [Symbol, String, nil] For array types, the type of array elements
      option :of, optional: true

      # @!attribute [r] extensions
      #   @return [Hash] OpenAPI specification extensions merged into the emitted
      #     schema (e.g. {"x-ts-type" => "Dayjs"}). Keys must start with "x-".
      option :extensions, proc { |value| OpenApi::TypeSystem.process_extensions(value) }, default: proc { {} }

      # @!attribute [r] properties
      #   @return [Hash] Hash of property definitions
      option :properties, default: proc { {} }

      # Always nil for a component. It exists so the shared, duck-typed
      # property_to_json emitter can treat a Component like any other schema
      # object (it probes +.as+ to decide between a $ref and an inline schema);
      # a component is never itself a reference, so the probe must return nil
      # rather than raise NoMethodError.
      #
      # @return [nil]
      attr_reader :as

      # Construct a component, rejecting any unknown option (see {StrictOptions}).
      #
      # @param name [Symbol, String] the component name
      # @param options [Hash] component configuration options
      # @raise [ArgumentError] when an unsupported option is supplied
      def initialize(name, **options)
        reject_unknown_options!(options)
        super
      end
    end
  end
end
