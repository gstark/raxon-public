# frozen_string_literal: true

module Raxon
  module OpenApi
    # Validates declared file upload fields after Dry::Schema has handled the
    # structural type coercion. This keeps Rack upload shape checks in one
    # explicit boundary instead of silently letting arbitrary values through
    # file-typed request body properties.
    class FileUploadValidator
      def initialize(schema, request_body)
        @schema = schema
        @request_body = request_body
      end

      def call(params)
        result = @schema.call(params)
        @uploaded_bytes = 0
        @unprocessable = false
        file_errors = file_errors_for(params)
        enforce_total_size!
        return result if file_errors.empty? && result.success?

        ValidationResult.new(params, deep_merge_errors(result.errors.to_h, file_errors), unprocessable: @unprocessable)
      end

      private

      def file_errors_for(params)
        return {} unless params.is_a?(Hash)
        return {} unless @request_body&.properties&.any?

        validate_properties(@request_body.properties, params)
      end

      # Reject a body whose uploads exceed the declared combined ceiling.
      #
      # Size violations are raised as {Raxon::RequestBodyTooLarge} (413) rather
      # than reported as validation errors, matching what +max_request_body_size+
      # already does for the request as a whole. The rule across uploads is:
      # too big is 413, wrong content is a validation error.
      def enforce_total_size!
        limit = @request_body&.max_total_size
        return unless limit
        return unless @uploaded_bytes > limit

        raise Raxon::RequestBodyTooLarge
      end

      def validate_properties(properties, params)
        properties.each_with_object({}) do |(name, property), errors|
          key = params.key?(name) ? name : name.to_s
          next unless params.key?(key)

          property_errors = validate_property(property, params[key])
          errors[name.to_sym] = property_errors unless property_errors.empty?
        end
      end

      def validate_property(property, value)
        return {} if value.nil? && property.nullable

        case property.type
        when "file"
          upload = Raxon::UploadedFile.normalize(value)
          return ["must be a file upload"] if upload.nil?

          validate_upload(property, upload)
        when "object"
          validate_object(property, value)
        when "array"
          validate_array(property, value)
        else
          {}
        end
      end

      # Apply the declared constraints to an upload that is structurally valid,
      # and accumulate its size toward the body's +max_total_size+.
      #
      # @return [Array<String>] validation errors, empty when the upload passes
      # @raise [Raxon::RequestBodyTooLarge] when it exceeds the declared max_size
      def validate_upload(property, upload)
        size = upload_size(upload)
        @uploaded_bytes += size

        limit = property.max_bytes || property.max_size
        raise Raxon::RequestBodyTooLarge if limit && size > limit

        extension_errors(property, upload) + content_type_errors(property, upload)
      end

      # Byte size of an upload, measured from the tempfile so it reflects what
      # was actually received rather than any client-declared length.
      #
      # Deliberately not rescued: a size that cannot be read must not fall back
      # to 0, which would treat the file as empty and wave it past every
      # declared limit.
      def upload_size(upload)
        upload.size.to_i
      end

      # Check the filename extension against the declared allowlist.
      #
      # The filename is client-supplied and proves nothing about the bytes (see
      # {Raxon::UploadedFile}), so this rejects obvious mistakes early and is
      # explicitly not a substitute for validating content before use.
      def extension_errors(property, upload)
        allowed = property.allowed_extensions
        return [] unless allowed&.any?

        permitted = allowed.map { |extension| extension.to_s.delete_prefix(".").downcase }
        actual = File.extname(upload.original_filename.to_s).delete_prefix(".").downcase
        return [] if permitted.include?(actual)

        # A well-formed request carrying content the endpoint will not accept —
        # 422 rather than 400. See ValidationResult#unprocessable?.
        @unprocessable = true
        ["must be one of the allowed file types: #{permitted.join(", ")}"]
      end

      def content_type_errors(property, upload)
        allowed = property.content_types
        return [] unless allowed&.any?

        actual = upload.content_type.to_s.split(";", 2).first.strip.downcase
        permitted = allowed.map { |type| type.to_s.downcase }
        return [] if !actual.empty? && permitted.include?(actual)

        @unprocessable = true
        ["must have one of the allowed content types: #{permitted.join(", ")}"]
      end

      def validate_object(property, value)
        return {} unless value.is_a?(Hash)
        return {} unless property.properties.any?

        validate_properties(property.properties, value)
      end

      def validate_array(property, value)
        value_is_array = value.is_a?(Array)
        return {} unless value_is_array

        validates_object_items = property.properties.any? && (property.of.nil? || property.of.to_s == "object")
        return {} unless validates_object_items

        item_errors = {}
        value.each_with_index do |item, index|
          next unless item.is_a?(Hash)

          errors = validate_properties(property.properties, item)
          item_errors[index] = errors unless errors.empty?
        end
        item_errors
      end

      def deep_merge_errors(left, right)
        left.merge(right) do |_key, left_value, right_value|
          if left_value.is_a?(Hash) && right_value.is_a?(Hash)
            deep_merge_errors(left_value, right_value)
          elsif left_value.is_a?(Array) && right_value.is_a?(Array)
            left_value + right_value
          else
            right_value
          end
        end
      end

      # A failed validation. The validator returns the Dry::Schema result
      # untouched when everything passed, so this wrapper is only ever built
      # for a failure and #success? is always false.
      #
      # #to_h therefore never exposes the schema's coerced output: a caller that
      # checks errors loosely gets the untouched input rather than values that
      # failed upload validation. This mirrors
      # ResponseSchemaGenerator::ValidationResult, whose to_h guards the same way.
      class ValidationResult
        def initialize(params, errors, unprocessable: false)
          @params = params
          @errors = errors
          @unprocessable = unprocessable
        end

        def success?
          @errors.empty?
        end

        # Whether the failure was a *content* rejection rather than a malformed
        # request. A syntactically fine upload of a type the endpoint refuses is
        # 422 Unprocessable Content; a missing or mistyped field is still 400.
        #
        # Errors stay merged either way, so a request with both problems reports
        # both — only the status is affected.
        def unprocessable?
          @unprocessable
        end

        def errors
          ValidationErrors.new(@errors)
        end

        def to_h
          @params
        end
      end

      class ValidationErrors
        def initialize(errors)
          @errors = errors
        end

        def to_h
          @errors
        end
      end
    end
  end
end
