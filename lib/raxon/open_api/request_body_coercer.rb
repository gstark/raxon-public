# frozen_string_literal: true

module Raxon
  module OpenApi
    # Coerces request body params according to request body property definitions.
    #
    # RequestBodyCoercer is responsible for interpreting the OpenAPI request body
    # property tree after validation has produced a params hash. It keeps
    # request orchestration separate from property-specific coercion rules.
    #
    # The main coercion it performs today is wrapping Rack multipart file hashes
    # in Raxon::UploadedFile for properties declared as type: :file. Object
    # properties are traversed recursively, so nested file fields behave the same
    # as top-level file fields. Array properties with object item definitions are
    # traversed recursively too.
    #
    # @example Coerce a nested file property
    #   request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    #   request_body.property :profile, type: :object do |profile|
    #     profile.property :photo, type: :file
    #   end
    #
    #   params = { profile: { photo: rack_file_hash } }
    #   Raxon::OpenApi::RequestBodyCoercer.new(request_body).call(params)
    #   params[:profile][:photo] # => #<Raxon::UploadedFile ...>
    class RequestBodyCoercer
      # Initialize a request body coercer.
      #
      # @param request_body [Raxon::OpenApi::RequestBody, nil] Request body definition
      def initialize(request_body)
        @request_body = request_body
      end

      # Coerce params in place according to the configured request body.
      #
      # Returns the original params object for convenient assignment by callers.
      # If there is no request body, no request body properties, or params is not
      # a Hash, the input is returned unchanged.
      #
      # @param params [Hash, Object] Validated params or raw params to coerce
      # @return [Hash, Object] The same params object, with applicable values coerced
      def call(params)
        return params unless @request_body&.properties&.any?
        return params unless params.is_a?(Hash)

        coerce_properties(@request_body.properties, params)
        params
      end

      private

      # Coerce each declared property present in the params hash.
      #
      # Handles both symbol and string keys because params can come from Rack,
      # JSON parsing, or dry-schema output depending on request shape.
      #
      # @param properties [Hash{Symbol,String => Raxon::OpenApi::Property}]
      # @param params [Hash]
      # @return [void]
      def coerce_properties(properties, params)
        properties.each do |name, property|
          key = params.key?(name) ? name : name.to_s
          next unless params.key?(key)

          params[key] = coerce_property(property, params[key])
        end
      end

      # Coerce a single value for a property definition.
      #
      # @param property [Raxon::OpenApi::Property]
      # @param value [Object]
      # @return [Object] Coerced value
      def coerce_property(property, value)
        case property.type
        when "file"
          coerce_file(value)
        when "object"
          coerce_object(property, value)
        when "array"
          coerce_array(property, value)
        else
          value
        end
      end

      # Wrap a Rack multipart file hash in Raxon::UploadedFile.
      #
      # Already wrapped values are returned unchanged. Values that are not Rack
      # multipart file hashes are also returned unchanged.
      #
      # @param value [Object]
      # @return [Object, Raxon::UploadedFile]
      def coerce_file(value)
        Raxon::UploadedFile.normalize(value) || value
      end

      # Recursively coerce an object property's nested properties.
      #
      # @param property [Raxon::OpenApi::Property]
      # @param value [Object]
      # @return [Object]
      def coerce_object(property, value)
        return value unless value.is_a?(Hash)
        return value unless property.properties.any?

        coerce_properties(property.properties, value)
        value
      end

      # Recursively coerce array object item properties.
      #
      # @param property [Raxon::OpenApi::Property]
      # @param value [Object]
      # @return [Object]
      def coerce_array(property, value)
        value_is_an_array = value.is_a?(Array)
        return value unless value_is_an_array

        coerces_object_items = property.properties.any? && (property.of.nil? || property.of.to_s == "object")
        return value unless coerces_object_items

        value.each do |item|
          coerce_properties(property.properties, item) if item.is_a?(Hash)
        end

        value
      end
    end
  end
end
