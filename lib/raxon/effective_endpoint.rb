# frozen_string_literal: true

module Raxon
  # Immutable operation contract composed from the matching all.rb ancestors
  # and the selected route file. Source endpoints remain unmodified.
  class EffectiveEndpoint
    attr_reader :leaf, :endpoints, :parameters, :responses, :security, :validate_response, :validation_profile, :static_metadata, :provenance

    def initialize(leaf, endpoints)
      @leaf = leaf
      @endpoints = endpoints.freeze
      @declaration_endpoints = endpoints.select { |endpoint| endpoint.equal?(leaf) || endpoint.method == "all" }.freeze
      @parameters, parameter_sources = compose_parameters
      @request_schema = RequestSchema.new(@parameters, leaf.request_body)
      @responses, response_sources = compose_responses
      @response_schemas = build_response_schemas
      @security, security_source = nearest(:security)
      @validate_response, validation_source = nearest(:validate_response)
      @validation_profile, profile_source = nearest(:validation_profile)
      @static_metadata, metadata_sources = compose_static_metadata
      @provenance = {parameters: parameter_sources, responses: response_sources,
                     security: security_source, validate_response: validation_source, validation_profile: profile_source,
                     metadata: metadata_sources}.freeze
      freeze
    end

    def request_body = leaf.request_body

    # The compiled request schema, or nil when the endpoint declares nothing to
    # validate. Compiled on first use — see {RequestSchema}.
    def request_schema = @request_schema.schema

    # Whether this endpoint declares anything to validate, answered without
    # compiling the schema.
    def request_schema? = @request_schema.declared?

    def handler_block = leaf.handler_block
    def handler_mode = leaf.handler_mode
    def representation = leaf.representation
    def has_handler? = leaf.has_handler?
    def route_file_path = leaf.route_file_path
    def route_context = leaf.route_context
    def create_context_instance = leaf.create_context_instance
    def description = leaf.description
    def summary = leaf.summary
    def operation_id = leaf.operation_id
    def tags = leaf.tags
    def deprecated = leaf.deprecated
    def path = leaf.path
    def operations = leaf.operations
    def method = leaf.method

    attr_reader :response_schemas

    # The endpoint's request schema, compiled on first use.
    #
    # Same reasoning as {ResponseSchemas}: dry-schema compilation dominates route
    # loading, and a schema is only needed once a request actually reaches the
    # endpoint. #declared? answers "is there anything to validate" from the
    # declarations alone, so the common "no parameters, no body" endpoint never
    # compiles anything.
    class RequestSchema
      def initialize(parameters, request_body)
        @parameters = parameters
        @request_body = request_body
        @mutex = Mutex.new
      end

      # @return [Boolean] whether any parameter or body property is declared
      def declared?
        @parameters.parameters.any? || @request_body&.properties&.any? || false
      end

      # @return [Dry::Schema::Params, FileUploadValidator, nil]
      def schema
        return @schema if defined?(@schema)

        @mutex.synchronize do
          next @schema if defined?(@schema)

          @schema = OpenApi::RequestSchemaGenerator.new(@parameters, @request_body).to_dry_schema
        end
      end
    end

    # Response schemas compiled on first use, keyed by status code.
    #
    # Compiling every declared response for every route is the single most
    # expensive thing route loading can do: dry-schema compilation is not cheap,
    # and an app with a few hundred routes declaring a handful of responses each
    # pays it hundreds of times before it serves a request. Almost all of that
    # work is wasted — response validation is opt-in and off by default, and even
    # when it is on an endpoint only ever needs the schema for the status it
    # actually answers with.
    class ResponseSchemas
      def initialize(responses)
        @responses = responses
        @cache = {}
        @mutex = Mutex.new
      end

      # @param code [Integer] HTTP status code
      # @return [Dry::Schema::Params, nil]
      def [](code)
        return @cache[code] if @cache.key?(code)

        @mutex.synchronize do
          next @cache[code] if @cache.key?(code)

          # A status can be declared twice — `exception_error` (:unprocessable_entity)
          # alongside an explicit `response 422`, say. Building the whole hash let
          # the later declaration overwrite the earlier one, so match from the end.
          response = @responses.to_a.reverse.find { |status, _| OpenApi::DocumentBuilder.status_to_code(status) == code }&.last
          @cache[code] = response && OpenApi::ResponseSchemaGenerator.new(response).to_dry_schema
        end
      end
    end

    private

    def build_response_schemas
      ResponseSchemas.new(responses)
    end

    def compose_parameters
      entries = {}
      sources = {}
      inferred = leaf.inferred_path_parameters
      inferred.each do |name|
        defaults = Raxon.configuration.path_parameter_defaults&.call(name, leaf.path) || {type: :string}
        parameter = OpenApi::Parameter.new(name, in: :path, required: true, **defaults)
        entries[[:path, name.to_sym]] = parameter
        sources[[:path, name.to_sym]] = :filename
      end
      @declaration_endpoints.each do |endpoint|
        endpoint.parameters.parameters.each do |parameter|
          key = [parameter.in.to_sym, parameter.name.to_sym]
          entries[key] = parameter
          sources[key] = endpoint.route_file_path
        end
      end
      # Existing static routes may use a path parameter as a documented input;
      # enforce filename agreement for dynamic routes, where the filename is
      # the structural owner, without turning this compatible addition into a
      # breaking load-time change for older route trees.
      unknown = inferred.empty? ? [] : entries.keys.select { |location, name| location == :path && !inferred.include?(name) }
      unless unknown.empty?
        names = inferred.join(", ")
        raise Error, "Path parameter #{unknown.first.last.inspect} in #{leaf.route_file_path} is not present in filename (expected: #{names})"
      end
      parameters = OpenApi::Parameters.new
      entries.each_value { |parameter| parameters.parameters << parameter }
      [parameters.freeze, sources.freeze]
    end

    def compose_responses
      values, sources = {}, {}
      @declaration_endpoints.each do |endpoint|
        endpoint.default_responses.each do |status, response|
          key = OpenApi::DocumentBuilder.status_to_code(status)
          values[key] = response
          sources[key] = endpoint.route_file_path
        end
      end
      @declaration_endpoints.each do |endpoint|
        endpoint.responses.each do |status, response|
          key = OpenApi::DocumentBuilder.status_to_code(status)
          values[key] = response
          sources[key] = endpoint.route_file_path
        end
      end
      [values.freeze, sources.freeze]
    end

    def nearest(attribute)
      @declaration_endpoints.reverse_each do |endpoint|
        value = endpoint.public_send(attribute)
        return [value, endpoint.route_file_path] unless value.nil?
      end
      [nil, nil]
    end

    def compose_static_metadata
      values, sources = {}, {}
      endpoints.each do |endpoint|
        endpoint.static_metadata.each do |key, value|
          values[key] = value
          sources[key] = endpoint.route_file_path
        end
      end
      [values.freeze, sources.freeze]
    end
  end
end
