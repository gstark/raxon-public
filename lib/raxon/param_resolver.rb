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
    Sources = Struct.new(
      :query, :form, :json, :path, :headers, :cookies, :json_parse_error,
      keyword_init: true
    )

    # The immutable outcome of resolution.
    #
    # @!attribute params [Hash] The final, handler-ready parameters
    # @!attribute errors [Hash, nil] Validation errors, or nil on success
    # @!attribute parse_error [Boolean] Whether the JSON body failed to parse
    Result = Struct.new(:params, :errors, :parse_error, keyword_init: true)

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
    def assemble_raw
      @sources.query
        .merge(@sources.form)
        .merge(@sources.json)
        .merge(@sources.path)
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

    # @param parameter [Raxon::OpenApi::Parameter]
    # @param raw [Hash]
    # @return [Object, nil]
    def value_from_source(parameter, raw)
      case parameter.in.to_sym
      when :path
        @sources.path[parameter.name.to_sym]
      when :query
        @sources.query[parameter.name.to_sym]
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
      params, errors = validate(validation_params, raw)
      params = Raxon::OpenApi::RequestBodyCoercer.new(@request_body).call(params) if @request_body
      Result.new(params: params, errors: errors, parse_error: false)
    end

    # @return [Array(Hash, Hash | nil)] [params, errors]
    def validate(validation_params, raw)
      return [raw, nil] unless @schema

      result = @schema.call(validation_params)
      if result.success?
        [result.to_h, nil]
      else
        [raw, result.errors.to_h]
      end
    end
  end
end
