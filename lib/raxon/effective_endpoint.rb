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
      @request_schema = OpenApi::RequestSchemaGenerator.new(@parameters, leaf.request_body).to_dry_schema
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
    attr_reader :request_schema
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

    private

    def build_response_schemas
      responses.each_with_object({}) do |(status, response), schemas|
        schema = OpenApi::ResponseSchemaGenerator.new(response).to_dry_schema
        schemas[OpenApi::DocumentBuilder.status_to_code(status)] = schema if schema
      end
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
