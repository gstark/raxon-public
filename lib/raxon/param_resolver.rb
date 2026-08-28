# frozen_string_literal: true

module Raxon
  # Resolves the raw, multi-source input of an HTTP request into a single
  # validated, coerced parameter set. See CONTEXT.md ("Param resolution").
  #
  # A request carries parameters in up to six places. ParamResolver collapses
  # them under a fixed precedence (query < form < json < path), re-reads any
  # parameter with a declared `in:` location from its own source so a body value
  # cannot satisfy a required header/cookie/path parameter, validates the merged
  # set against the endpoint's request schema, falls back to the lenient merge on
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
      def initialize(query: {}, form: {}, json: {}, path: {}, headers: nil, cookies: nil,
        json_parse_error: false, deferred: nil)
        @query = query
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
    end

    # The immutable outcome of resolution.
    #
    # @!attribute params [Hash] The final, handler-ready parameters
    # @!attribute errors [Hash, nil] Validation errors, or nil on success
    # @!attribute parse_error [Boolean] Whether the JSON body failed to parse
    # @!attribute unprocessable [Boolean] Whether the failure was a content
    #   rejection (422) rather than a malformed request (400)
    Result = Struct.new(:params, :errors, :parse_error, :unprocessable, keyword_init: true)

    # @param parameters [Array<Raxon::OpenApi::Parameter>] Declared parameters
    #   (their `in:` locations drive source isolation). Defaults to empty.
    # @param schema [#call, nil] The endpoint's request schema (a Dry::Schema
    #   callable). When nil, the lenient merge is returned unvalidated.
    # @param request_body [Raxon::OpenApi::RequestBody, nil] Drives coercion.
    def initialize(parameters: [], schema: nil, request_body: nil)
      @parameters = parameters
      @schema = schema
      @request_body = request_body
    end

    # Resolve a request's sources into a final parameter set.
    #
    # @param sources [Sources]
    # @return [Result]
    def resolve(sources)
      return Result.new(params: {}, errors: nil, parse_error: true) if sources.json_parse_error

      @sources = sources
      @normalized_headers = nil

      raw = assemble_raw
      validation_params = assemble_validation(raw)
      finalize(validation_params, raw)
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
    def assemble_raw
      raw = merge_source(nil, @sources.query)
      raw = merge_source(raw, @sources.form)
      raw = merge_source(raw, @sources.json)
      raw = merge_source(raw, @sources.path)
      raw || {}
    end

    # @param raw [Hash, nil] The accumulator, nil until the first non-empty source
    # @param source [Hash]
    # @return [Hash, nil]
    def merge_source(raw, source)
      return raw if source.empty?

      raw.nil? ? source.dup : raw.merge!(source)
    end

    # Build the source-specific hash used for validation. Any parameter with a
    # non-query `in:` location is re-read from its own source so a query/body
    # value cannot satisfy it.
    #
    # @param raw [Hash] The lenient merge (used for the fallback `else` branch)
    # @return [Hash]
    def assemble_validation(raw)
      params = raw.dup

      @parameters.each do |parameter|
        next if parameter.in.to_sym == :query

        key = parameter.name.to_sym
        params.delete(key)
        value = value_from_source(parameter, raw)
        params[key] = value unless value.nil?
      end

      params
    end

    # Only called for non-query parameters: assemble_validation skips
    # `in: :query`, which is already covered by the lenient merge.
    #
    # @param parameter [Raxon::OpenApi::Parameter]
    # @param raw [Hash]
    # @return [Object, nil]
    def value_from_source(parameter, raw)
      case parameter.in.to_sym
      when :path
        @sources.path[parameter.name.to_sym]
      when :header
        header_value(parameter.name)
      when :cookie
        @sources.cookies[parameter.name.to_s]
      else
        raw[parameter.name.to_sym]
      end
    end

    # Look up a header parameter, matching either the raw HTTP_* env key or the
    # capitalized-dash normalized form.
    #
    # @param name [Symbol, String]
    # @return [String, nil]
    def header_value(name)
      rack_key = "HTTP_#{name.to_s.upcase.tr("-", "_")}"
      @sources.headers[rack_key] || normalized_headers[header_name(name)]
    end

    # @return [Hash] Headers re-keyed from HTTP_X_FOO to "X-Foo"
    def normalized_headers
      @normalized_headers ||= @sources.headers.transform_keys do |key|
        key.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-")
      end
    end

    # @param name [Symbol, String]
    # @return [String]
    def header_name(name)
      name.to_s.tr("_", "-").split("-").map(&:capitalize).join("-")
    end

    # Validate, apply the lenient fallback, then coerce.
    #
    # @param validation_params [Hash]
    # @param raw [Hash]
    # @return [Result]
    def finalize(validation_params, raw)
      params, errors, unprocessable = validate(validation_params, raw)
      strip_read_only(params)
      params = Raxon::OpenApi::RequestBodyCoercer.new(@request_body).call(params) if @request_body
      Result.new(params: params, errors: errors, parse_error: false, unprocessable: unprocessable)
    end

    # Delete top-level values for the body's read-only properties. Those
    # properties are absent from the resolved schema, and the lenient merge
    # keeps undeclared keys, so without this a client-supplied value for a
    # server-managed field (deleted_at, say) would flow through to the handler.
    # Runs on the fallback path too — belt and suspenders, since a failed
    # validation already answers 400 before the handler.
    def strip_read_only(params)
      keys = @request_body.respond_to?(:read_only_keys) ? @request_body&.read_only_keys : nil
      return if keys.nil? || keys.empty?

      keys.each do |key|
        params.delete(key.to_sym)
        params.delete(key.to_s)
      end
    end

    # @return [Array(Hash, Hash | nil, Boolean)] [params, errors, unprocessable]
    def validate(validation_params, raw)
      return [raw, nil, false] unless @schema

      result = @schema.call(validation_params)
      if result.success?
        # Dry::Schema returns declared fields only. Route parameters validate
        # their own sources, but Raxon has historically kept undeclared query
        # and body values available to handlers; retain that behavior while
        # letting declared values replace their raw counterparts with coerced
        # values.
        declared = @parameters.map { |parameter| parameter.name.to_sym }
        declared.concat(@request_body.properties.keys.map(&:to_sym)) if @request_body&.properties
        [raw.reject { |key, _| declared.include?(key.to_sym) }.merge(result.to_h), nil, false]
      else
        # Only the upload validator classifies a failure as a content rejection;
        # a plain Dry::Schema result has no opinion, so those stay 400.
        unprocessable = result.respond_to?(:unprocessable?) && result.unprocessable?
        [raw, result.errors.to_h, unprocessable]
      end
    end
  end
end
