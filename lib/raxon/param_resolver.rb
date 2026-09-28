# frozen_string_literal: true

module Raxon
  # Resolves the raw, multi-source input of an HTTP request into a single
  # validated, coerced parameter set. See CONTEXT.md ("Param resolution").
  #
  # A request carries parameters in up to six places. ParamResolver collapses
  # them under a fixed precedence (query < form < json < path), re-reads every
  # declared parameter from its own `in:` source so a body value cannot
  # satisfy or override a query/header/cookie/path parameter, validates the merged
  # set against the endpoint's request schema, gives empty params on
  # validation failure, and finally coerces request-body properties (wrapping
  # file uploads).
  #
  # The interface is one verb over plain inputs:
  #   resolve(sources) -> Result(params:, errors:, parse_error:)
  #
  # It depends on the request schema and request body (two endpoint spec
  # artifacts), not on the Request or the Rack env, so its behavior is testable
  # with plain hashes.
  #
  # A resolver holds no per-request state, so one endpoint builds one and
  # shares it across requests and threads. Everything it can work out from the
  # declarations (the parameter names, the read-only keys to strip, whether a
  # body needs the file coercion walk) is worked out once, here.
  #
  # @example
  #   resolver = Raxon::ParamResolver.new(parameters: [], schema: nil, request_body: nil)
  #   sources = Raxon::ParamResolver::Sources.new(
  #     query: {}, form: {}, json: { id: 2 }, path: { id: 1 },
  #     headers: {}, cookies: {}
  #   )
  #   resolver.resolve(sources).params[:id] # => 1 (path wins)
  class ParamResolver
    # The six materialized request sources for a single request, plus whether the
    # JSON body failed to parse. Collected by Request honoring the body-stream
    # ordering constraint (JSON parsed before form params).
    #
    # query/form/json/path carry symbol keys; headers carry the raw HTTP_* env
    # keys (as Request#headers returns); cookies carry string keys.
    #
    # Headers and cookies are read only for parameters declaring `in: :header`
    # or `in: :cookie`, which most endpoints have none of, and Request#headers
    # allocates a hash of every HTTP_* env key. Rather than materialize them,
    # Request passes itself as +deferred+ and they are fetched on first read.
    # Passing them directly still works and wins — that is what tests and
    # programmatic callers do — and the other four sources stay eager because
    # they feed the lenient merge on every request anyway.
    class Sources
      # @param deferred [#headers, #cookies, nil] Consulted for headers and
      #   cookies when they are not passed directly
      # @param body_present [Boolean, nil] Whether the request carried a body in
      #   a media type Raxon reads. Derived from the form and JSON sources when nil.
      def initialize(query: {}, form: {}, json: {}, path: {}, headers: nil, cookies: nil,
        json_parse_error: false, deferred: nil, body_present: nil)
        @query = query
        @body_present = body_present
        @form = form
        @json = json
        @path = path
        @headers = headers
        @cookies = cookies
        @json_parse_error = json_parse_error
        @deferred = deferred
      end

      def headers
        @headers ||= @deferred ? @deferred.headers : {}
      end

      def cookies
        @cookies ||= @deferred ? @deferred.cookies : {}
      end

      attr_reader :query, :form, :json, :path, :json_parse_error

      def body_present?
        @body_present.nil? ? !(@form.empty? && @json.empty?) : @body_present
      end
    end

    # The immutable outcome of resolution.
    #
    # @!attribute params [Hash] The final, handler-ready parameters
    # @!attribute errors [Hash, nil] Validation errors, or nil on success
    # @!attribute parse_error [Boolean] Whether the JSON body failed to parse
    # @!attribute unprocessable [Boolean] Whether the failure was a content
    #   rejection (422) rather than a malformed request (400)
    Result = Struct.new(:params, :errors, :parse_error, :unprocessable)

    # @param parameters [Array<Raxon::OpenApi::Parameter>] Declared parameters
    #   (their `in:` locations drive source isolation). Defaults to empty.
    # @param schema [#call, nil] The endpoint's request schema (a Dry::Schema
    #   callable). When nil, the lenient merge is returned unvalidated.
    # @param request_body [Raxon::OpenApi::RequestBody, nil] Drives coercion.
    # @param keep_undeclared [Boolean] Return the lenient merge when there is no
    #   schema. For a request that matched no endpoint, so there are no
    #   declarations to filter by. A matched endpoint keeps only what it declares.
    def initialize(parameters: [], schema: nil, request_body: nil, keep_undeclared: false)
      @parameters = parameters
      @schema = schema
      @request_body = request_body
      @keep_undeclared = keep_undeclared

      @parameter_names = parameters.map(&:name).freeze
      @body_required = request_body&.required ? true : false
      @cyclic = request_body.respond_to?(:cyclic?) && request_body.cyclic?
      array_body = Raxon::OpenApi::RequestSchemaGenerator.array_body?(request_body)
      @free_form = !request_body.nil? && request_body.properties.empty? && !array_body
      # Wrapping multipart file hashes is the only coercion there is, so a body
      # with no file field anywhere skips the walk.
      @coercer = if !array_body && Raxon::OpenApi::RequestSchemaGenerator.file_fields?(request_body)
        Raxon::OpenApi::RequestBodyCoercer.new(request_body)
      end
      # A declared parameter is re-read from its own source, so it never came
      # from the body and is not stripped.
      read_only_keys = request_body.respond_to?(:read_only_keys) ? request_body.read_only_keys : nil
      @read_only_keys = ((read_only_keys || []) - @parameter_names).freeze
    end

    # Resolve a request's sources into a final parameter set.
    #
    # @param sources [Sources]
    # @return [Result]
    def resolve(sources)
      return Result.new(params: {}, errors: nil, parse_error: true) if sources.json_parse_error

      raw = assemble_raw(sources)
      validation_params = assemble_validation(sources, raw)
      finalize(sources, validation_params, raw)
    end

    private

    # Merge every source under the historical precedence: later wins, so body
    # overrides query/form and path overrides all client-supplied values.
    #
    # @return [Hash]
    # Merging an empty source allocates a hash to copy nothing into, and most
    # requests carry only one or two sources: a GET with a query string has no
    # form or JSON, and a bodyless request has neither. Skipping the empty ones
    # takes the common case from three intermediate hashes to one.
    #
    # The result is always a fresh hash, never one of the sources. Callers own
    # what they get back — on a validation failure it becomes the handler's
    # params — and handing them #query_params itself would let a handler mutate
    # the request's own source hash.
    def assemble_raw(sources)
      raw = merge_source(nil, sources.query)
      raw = merge_source(raw, sources.form)
      raw = merge_source(raw, sources.json)
      raw = merge_source(raw, sources.path)
      raw || {}
    end

    # @param raw [Hash, nil] The accumulator, nil until the first non-empty source
    # @param source [Hash]
    # @return [Hash, nil]
    def merge_source(raw, source)
      return raw if source.empty?

      raw.nil? ? source.dup : raw.merge!(source)
    end

    # Build the source-specific hash used for validation. Every declared
    # parameter is re-read from its own `in:` source, so a body value cannot
    # satisfy or override a query, header, cookie, or path parameter. A JSON
    # body with "file" does not replace ?file= on a GET.
    #
    # @param sources [Sources]
    # @param raw [Hash] The lenient merge
    # @return [Hash]
    def assemble_validation(sources, raw)
      return raw.dup if @parameters.empty?

      params = raw.dup
      normalized_headers = nil

      @parameters.each do |parameter|
        key = parameter.name
        params.delete(key)
        value = case parameter.in
        when :path
          sources.path[key]
        when :header
          rack_key = "HTTP_#{key.to_s.upcase.tr("-", "_")}"
          sources.headers[rack_key] || (normalized_headers ||= normalize_headers(sources.headers))[header_name(key)]
        when :cookie
          sources.cookies[key.to_s]
        else
          sources.query[key]
        end
        params[key] = value unless value.nil?
      end

      params
    end

    # @param headers [Hash]
    # @return [Hash] Headers re-keyed from HTTP_X_FOO to "X-Foo"
    def normalize_headers(headers)
      headers.transform_keys do |key|
        key.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-")
      end
    end

    # @param name [Symbol, String]
    # @return [String]
    def header_name(name)
      name.to_s.tr("_", "-").split("-").map(&:capitalize).join("-")
    end

    # Validate, then coerce.
    #
    # A failed validation gives empty params, never the lenient merge.
    # Metadata blocks, before blocks, and authenticators run before the 400,
    # and any of them can read request.params.
    #
    # @param sources [Sources]
    # @param validation_params [Hash]
    # @param raw [Hash]
    # @return [Result]
    def finalize(sources, validation_params, raw)
      params, errors, unprocessable = validate(sources, validation_params, raw)
      # A body declared required: true (the default) must arrive in a media
      # type Raxon reads. A text/plain body, or no body at all, fails here even
      # when every declared property is optional.
      if @body_required && !sources.body_present?
        params = {}
        errors = (errors || {}).merge(body: ["is missing"])
      end
      strip_read_only(sources, params)
      params = @coercer.call(params) if @coercer
      Result.new(params: params, errors: errors, parse_error: false, unprocessable: unprocessable)
    end

    # Delete top-level values for the body's read-only properties. Those
    # properties are absent from the resolved schema, and the lenient merge
    # keeps undeclared keys, so without this a client-supplied value for a
    # server-managed field (deleted_at, say) would flow through to the handler.
    #
    # A read-only body property often shares its name with a path parameter
    # (the `id` of PUT /users/{id} with an `as: :User` body). The path value
    # already overrode any body value in the merge, and a declared parameter
    # was re-read from its own source, so neither came from the body and both
    # stay.
    def strip_read_only(sources, params)
      @read_only_keys.each do |key|
        params.delete(key) unless sources.path.key?(key)
      end
    end

    # @return [Array(Hash, Hash | nil, Boolean)] [params, errors, unprocessable]
    def validate(sources, validation_params, raw)
      return [declared_only(sources, raw), nil, false] unless @schema

      result = call_schema(validation_params)
      if result.success?
        # Dry::Schema returns declared fields only, so a client cannot add a
        # key the endpoint never asked for (admin=1 on a form POST). Path
        # values come from the route itself, not the client, and stay.
        params = result.to_h
        params = Raxon::OpenApi::RequestBodyResolver.new.filter_cycles(@request_body, params) if @cyclic
        [free_form_body(sources).merge(sources.path, params), nil, false]
      else
        # Only the upload validator classifies a failure as a content rejection;
        # a plain Dry::Schema result has no opinion, so those stay 400.
        unprocessable = result.respond_to?(:unprocessable?) && result.unprocessable?
        [{}, result.errors.to_h, unprocessable]
      end
    end

    # A free-form body (an object body with no properties) accepts any keys by
    # definition, but the schema built for the declared parameters drops them.
    # Keep them, minus the declared parameter names, which read only their own
    # `in:` source.
    #
    # @return [Hash]
    def free_form_body(sources)
      return {} unless @free_form

      sources.form.merge(sources.json).except(*@parameter_names)
    end

    # @raise [Raxon::PatternTimeout] when a pattern: match times out
    def call_schema(validation_params)
      @schema.call(validation_params)
    rescue Regexp::TimeoutError
      raise Raxon::PatternTimeout, "A pattern match timed out while validating the request"
    end

    # The params for an endpoint with nothing to validate against: the path
    # values, plus the body when the endpoint declares a free-form body (a
    # request body with no properties), which accepts any keys by definition.
    #
    # @param raw [Hash]
    # @return [Hash]
    def declared_only(sources, raw)
      return raw if @keep_undeclared
      return sources.path.dup unless @request_body

      sources.form.merge(sources.json, sources.path)
    end
  end
end
