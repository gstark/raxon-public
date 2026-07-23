# frozen_string_literal: true

require "rack/utils"

require_relative "error"
require_relative "schema_emitter"
require_relative "spec_version"

module Raxon
  module OpenApi
    # Assembles a complete OpenAPI document from a {Specification}.
    #
    # This class decides document *structure* — paths, operations, parameters,
    # responses, request bodies, components — and delegates every schema it
    # needs to {SchemaEmitter}. One instance builds one document, so the
    # component context is established once for the whole build.
    #
    # @example
    #   DocumentBuilder.new(specification).build
    #
    class DocumentBuilder
      # Convert a status code symbol or integer to its numeric code.
      #
      # Uses Raxon::Response::STATUS_CODES for symbol lookup.
      #
      # @param status [Symbol, Integer] Status code symbol (e.g., :ok) or numeric code
      # @return [Integer] The numeric HTTP status code
      # @raise [ArgumentError] If the symbol is not a recognized status code
      #
      # @example
      #   status_to_code(:ok)        # => 200
      #   status_to_code(:not_found) # => 404
      #   status_to_code(201)        # => 201
      #
      def self.status_to_code(status)
        return status if status.is_a?(Integer)

        Raxon::Response::STATUS_CODES[status] || raise(ArgumentError, "Unknown status code symbol: #{status}")
      end

      # @param specification [Specification] The endpoints, components, and
      #   security schemes to document
      def initialize(specification)
        @specification = specification
      end

      # Generate the complete OpenAPI specification document.
      #
      # @return [Hash] Complete OpenAPI document with string keys
      def build
        SchemaEmitter.with_components(components) do
          data = {
            openapi: SpecVersion.version_string,
            info: build_api_info,
            paths: build_paths,
            components: build_components
          }

          data = convert_nullable_to_type_arrays(data) if SpecVersion.openapi_31?
          deep_transform_keys(data, &:to_s)
        end
      end

      private

      def endpoints
        @specification.endpoints
      end

      def components
        @specification.components
      end

      def security_schemes
        @specification.security_schemes
      end

      # Build the API info section of the OpenAPI specification.
      #
      # @return [Hash] API info with title, description, and version
      def build_api_info
        {
          title: Raxon.configuration.openapi_title,
          description: Raxon.configuration.openapi_description,
          version: Raxon.configuration.openapi_version
        }
      end

      # Build the paths section of the OpenAPI specification.
      #
      # @return [Hash] Paths mapping to endpoint operations
      def build_paths
        declared, routed = endpoints.partition { |endpoint| endpoint.route_file_path.nil? }

        # Route-file endpoints are emitted after DSL-declared endpoints so that
        # on a path+method collision the route — the real, enforced
        # implementation — wins over a documentation-only declaration.
        (declared + routed).each_with_object({}) do |endpoint, paths|
          next if middleware_only_route?(endpoint)

          if endpoint.path.nil? || endpoint.path.empty?
            raise Error, "OpenAPI endpoint has no path (operations: #{endpoint.operations.join(", ")}). " \
                         "Set endpoint.path before generating the document."
          end

          paths[endpoint.path] ||= {}
          endpoint.operations.each do |operation|
            paths[endpoint.path][operation] = build_operation_hash(endpoint)
          end
        end
      end

      # Whether an endpoint is a middleware-only route file (e.g. an all.rb
      # that only registers before/metadata blocks). These carry no handler and
      # describe no API surface of their own, so they are excluded from the
      # generated document. DSL-declared endpoints (no route file) are always
      # documented — they exist purely as documentation.
      #
      # @param endpoint [Endpoint]
      # @return [Boolean]
      def middleware_only_route?(endpoint)
        !endpoint.route_file_path.nil? && endpoint.handler_block.nil?
      end

      # Build an operation hash for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to build the operation for
      # @return [Hash] Operation hash with parameters, responses, and optional requestBody
      def build_operation_hash(endpoint)
        endpoint = endpoint.effective_endpoint if endpoint.respond_to?(:effective_endpoint) && endpoint.effective_endpoint
        operation_hash = {
          parameters: build_parameters(endpoint),
          responses: build_responses(endpoint)
        }

        operation_hash[:summary] = endpoint.summary if endpoint.summary
        operation_hash[:description] = endpoint.description if endpoint.description
        operation_hash[:operationId] = endpoint.operation_id if endpoint.operation_id
        operation_hash[:tags] = endpoint.tags if endpoint.tags.any?
        operation_hash[:deprecated] = true if endpoint.deprecated
        operation_hash[:security] = stringify_security_requirements(endpoint.security) if endpoint.security

        if endpoint.request_body
          operation_hash[:requestBody] = build_request_body(endpoint.request_body)
        end

        operation_hash
      end

      # Convert OpenAPI security requirement keys to strings for JSON output.
      #
      # @param security [Array<Hash>, Hash]
      # @return [Array<Hash>]
      def stringify_security_requirements(security)
        Array(security).map do |requirement|
          requirement.transform_keys(&:to_s)
        end
      end

      # Build the parameters list for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to extract parameters from
      # @return [Array<Hash>] Array of parameter definitions
      def build_parameters(endpoint)
        endpoint.parameters.parameters.map { |parameter|
          {
            name: parameter.name.to_s,
            in: parameter.in.to_s,
            required: parameter.required,
            description: parameter.description.to_s,
            schema: SchemaEmitter.schema_without_description(parameter)
          }
        }
      end

      # Build the responses section for an endpoint.
      #
      # @param endpoint [Endpoint] The endpoint to extract responses from
      # @return [Hash] Hash of status codes to response definitions
      def build_responses(endpoint)
        endpoint.responses.to_h do |status, response|
          code = self.class.status_to_code(status)
          [code, build_response_object(response, code)]
        end
      end

      # Build a single response object.
      #
      # A response declared without a description gets the standard HTTP reason
      # phrase for its status code (e.g. "OK", "Not Found") — OpenAPI requires
      # the description field, and an empty string trips spec linters.
      #
      # @param response [Response] The response definition
      # @param status_code [Integer, nil] Numeric status code, used for the default description
      # @return [Hash] Response object with description, headers, and content
      def build_response_object(response, status_code = nil)
        description = response.description.to_s
        description = Rack::Utils::HTTP_STATUS_CODES.fetch(status_code, "") if description.empty?

        object = {description: description, headers: {}}

        # A body-less response (e.g. a 204) declares no schema and must not carry
        # a content object; OpenAPI forbids content for 204/304.
        unless response_body_absent?(response)
          object[:content] = {
            response.content_type => {schema: SchemaEmitter.schema_without_description(response)}
          }
        end

        object
      end

      # Whether a response describes no body at all (no type, reference, or
      # properties). Such a response is emitted without a content object.
      #
      # @param response [Response]
      # @return [Boolean]
      def response_body_absent?(response)
        response.type.nil? && response.as.nil? && response.of.nil? && response.properties.empty?
      end

      # Build the request body for an endpoint.
      #
      # @param request_body [RequestBody] The request body definition
      # @return [Hash] Request body object with description, required, and content
      def build_request_body(request_body)
        {
          description: request_body.description.to_s,
          required: request_body.required,
          content: {
            request_body_media_type(request_body) => {schema: SchemaEmitter.schema_without_description(request_body)}
          }
        }
      end

      # Return the OpenAPI media type for a request body definition.
      #
      # @param request_body [RequestBody] The request body definition
      # @return [String] OpenAPI media type
      def request_body_media_type(request_body)
        (request_body.type == "multipart") ? "multipart/form-data" : "application/json"
      end

      # Build the components section of the OpenAPI specification.
      #
      # @return [Hash] Components hash with schemas and optional securitySchemes
      def build_components
        result = {
          schemas: components.to_h { |component| SchemaEmitter.property_to_json(component.name, component) }
        }
        result[:securitySchemes] = security_schemes.transform_values(&:to_openapi) if security_schemes.any?
        result
      end

      # Rewrite 3.0-style +nullable: true+ schemas into their OpenAPI 3.1 form,
      # where null is expressed through the type system instead of a keyword:
      # a typed schema gains "null" in its type array, an anyOf gains a
      # +{type: "null"}+ branch, and a bare $ref is wrapped in an anyOf (a $ref
      # cannot carry sibling type information).
      #
      # @param node [Object] Emitted specification data (pre key-stringification)
      # @return [Object] The transformed data
      def convert_nullable_to_type_arrays(node)
        case node
        when Hash
          transformed = node.to_h { |key, value| [key, convert_nullable_to_type_arrays(value)] }
          convert_nullable_schema(transformed)
        when Array
          node.map { |value| convert_nullable_to_type_arrays(value) }
        else
          node
        end
      end

      def convert_nullable_schema(schema)
        return schema unless schema[:nullable] == true

        if schema.key?(:type)
          schema.delete(:nullable)
          schema[:type] = Array(schema[:type]) + ["null"]
          schema
        elsif schema.key?(:anyOf)
          schema.delete(:nullable)
          schema[:anyOf] += [{type: "null"}]
          schema
        elsif (ref = schema[:$ref] || schema["$ref"])
          {anyOf: [{"$ref" => ref}, {type: "null"}]}
        else
          # Not a schema this transform understands (e.g. literal example data);
          # leave it untouched.
          schema
        end
      end

      # Recursively transform all keys in a nested hash/array structure.
      #
      # @param obj [Hash, Array, Object] The object to transform
      # @yield [Symbol, String] Block to transform each key
      # @return [Hash, Array, Object] The object with transformed keys
      #
      # @example
      #   deep_transform_keys({a: {b: 1}}, &:to_s)  # => {"a" => {"b" => 1}}
      def deep_transform_keys(obj, &block)
        case obj
        when Hash
          obj.transform_keys(&block).transform_values { |v| deep_transform_keys(v, &block) }
        when Array
          obj.map { |v| deep_transform_keys(v, &block) }
        else
          obj
        end
      end
    end
  end
end
