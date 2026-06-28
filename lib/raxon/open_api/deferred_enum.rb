# frozen_string_literal: true

module Raxon
  module OpenApi
    # Lazy resolution for +enum+ / +allowable_values+ on properties and parameters.
    #
    # Route DSL bodies are evaluated by Raxon::RouteLoader.load! at boot, before
    # the host application's autoloading (e.g. a Rails engine) is wired up. An
    # inline reference to an autoloaded constant in a route body therefore raises
    # NameError, which is why such enums are otherwise hand-inlined as literals
    # and guarded against drift. Supplying the enum as a callable defers that
    # reference until the value is actually read:
    #
    #   body.property :artifact_type, type: :string,
    #     enum: -> { DentalAi::ArtifactGenerator::SUPPORTED_TYPES }
    #
    # The callable is stored unevaluated at load time and resolved on every read
    # — OpenAPI-doc generation and request-time schema use — by which point the
    # constant resolves. The result is intentionally not memoized, so the live
    # constant is the single source of truth on each read. A plain Array enum is
    # returned unchanged, so existing literal usage is unaffected.
    module DeferredEnum
      private

      # Resolve an enum value that may have been supplied as a callable.
      #
      # @param value [Array, #call, nil] enum stored at definition time
      # @return [Array, nil] the array, calling a callable on each read
      def resolve_deferred_enum(value)
        value.respond_to?(:call) ? value.call : value
      end
    end
  end
end
