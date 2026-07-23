# frozen_string_literal: true

module Raxon
  module OpenApi
    # Resolves the configured OpenAPI specification version. Emission differs
    # between 3.0 and 3.1 in a few places (chiefly how null is expressed), so
    # both the schema emitter and the document builder ask here.
    module SpecVersion
      module_function

      # The `openapi` field value for the configured spec version.
      #
      # @return [String] "3.1.0" or "3.0.0"
      def version_string
        case Raxon.configuration.openapi_spec_version.to_s
        when "3.1", "3.1.0"
          "3.1.0"
        when "3.0", "3.0.0"
          "3.0.0"
        else
          raise ArgumentError, "Unsupported openapi_spec_version: #{Raxon.configuration.openapi_spec_version.inspect} (expected \"3.1\" or \"3.0\")"
        end
      end

      # @return [Boolean] whether the configured version is OpenAPI 3.1
      def openapi_31?
        version_string == "3.1.0"
      end
    end
  end
end
