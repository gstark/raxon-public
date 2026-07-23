# frozen_string_literal: true

module Raxon
  # Runs a matched route hierarchy against a request and response.
  #
  # Where an Endpoint *describes* a route (path, parameters, responses, schemas),
  # EndpointInvocation *executes* one: it drives the lifecycle stages for the
  # matched hierarchy and dispatches the selected endpoint's handler with request
  # and response validation around it. Keeping this out of Endpoint leaves the
  # endpoint a pure spec and gives the Router a single verb to call.
  #
  # The lifecycle it runs (global around/before/after, instrumentation, halt, and
  # exception handling stay in the Router):
  #
  #   1. metadata blocks, parent -> child
  #   2. before blocks, parent -> child
  #   3. the selected endpoint's handler, with request + response validation
  #   4. after blocks, child -> parent
  #
  # A before block that halts raises HaltException, which unwinds past the handler
  # and after blocks to the Router (flow control), matching the documented order.
  #
  # @example
  #   Raxon::EndpointInvocation.new(handler_endpoint, endpoints)
  #     .run(request, response, metadata)
  class EndpointInvocation
    # @param handler_endpoint [Raxon::OpenApi::Endpoint] The selected endpoint
    #   whose handler runs (and whose schemas validate the request/response).
    # @param endpoints [Array<Raxon::OpenApi::Endpoint>] The matched hierarchy,
    #   ordered parent to child.
    def initialize(handler_endpoint, endpoints)
      @handler_endpoint = handler_endpoint
      @endpoints = endpoints
    end

    # Run the hierarchy lifecycle for this request.
    #
    # @param request [Raxon::Request]
    # @param response [Raxon::Response]
    # @param metadata [Hash]
    # @return [void]
    def run(request, response, metadata)
      metadata.merge!(@handler_endpoint.static_metadata) if @handler_endpoint.respond_to?(:static_metadata)
      run_metadata_blocks(request, response, metadata)
      return unless authenticate(request, response, metadata)

      run_before_blocks(request, response, metadata)
      run_handler(request, response, metadata)
      run_after_blocks(request, response, metadata)
    end

    private

    # Enforce the endpoint's declared security requirements.
    #
    # OpenAPI semantics: the requirements array is an OR (any one grants
    # access) and the schemes within a requirement are an AND (all must pass).
    # A requirement is enforceable only when every scheme it references has an
    # authenticator block; requirements referencing declared-but-unenforced
    # (documentation-only) schemes are skipped, and when every requirement is
    # documentation-only nothing runs (backwards compatible).
    #
    # A requirement naming a scheme that was never declared is a different case:
    # almost always a typo in +endpoint.security+ or a scheme defined after the
    # route loaded. The endpoint was meant to be protected, so we fail closed
    # (401) rather than admit the request — the previous behavior silently left
    # such endpoints wide open while the generated document advertised them as
    # secured.
    #
    # Authenticator blocks receive (request, metadata, scopes) and grant access
    # by returning truthy. When no enforceable requirement passes, the response
    # becomes a 401 and the rest of the lifecycle (before blocks, handler,
    # after blocks) is skipped.
    #
    # @return [Boolean] true when the request may proceed
    def authenticate(request, response, metadata)
      # Read before wrapping: #security is nil on the overwhelming majority of
      # endpoints, and Array(nil) allocates an empty array per request to ask
      # whether it is empty.
      declared = @handler_endpoint.security
      return true if declared.nil?

      requirements = Array(declared)
      return true if requirements.empty?

      schemes = Raxon::OpenApi::DSL.security_schemes

      references_undeclared_scheme = requirements.any? do |requirement|
        requirement.keys.any? { |name| !schemes.key?(name.to_sym) }
      end
      return deny(response) if references_undeclared_scheme

      enforceable = requirements.select do |requirement|
        requirement.keys.all? { |name| schemes[name.to_sym].authenticator }
      end
      return true if enforceable.empty?

      granted = enforceable.any? do |requirement|
        requirement.all? do |name, scopes|
          schemes[name.to_sym].authenticator.call(request, metadata, scopes)
        end
      end
      return true if granted

      deny(response)
    end

    # Set the response to a 401 and signal that the lifecycle should stop.
    #
    # @return [false]
    def deny(response)
      response.code = :unauthorized
      response.body = {error: "Unauthorized"}
      false
    end

    # Metadata blocks run parent to child, each in its endpoint's context.
    def run_metadata_blocks(request, response, metadata)
      @endpoints.each do |endpoint|
        next unless endpoint.has_metadata?

        context = request.endpoint_context(endpoint)
        endpoint.metadata_blocks.each do |block|
          execute_block_in_context(context, block, request, response, metadata)
        end
      end
    end

    # Before blocks run parent to child. A halt raises HaltException, which
    # propagates to the Router and skips the handler and after blocks.
    def run_before_blocks(request, response, metadata)
      @endpoints.each do |endpoint|
        next unless endpoint.has_before?

        context = request.endpoint_context(endpoint)
        endpoint.before_blocks.each do |block|
          execute_block_in_context(context, block, request, response, metadata)
        end
      end
    end

    # After blocks run child to parent. A halt here also propagates to the Router.
    def run_after_blocks(request, response, metadata)
      @endpoints.reverse_each do |endpoint|
        next unless endpoint.has_after?

        context = request.endpoint_context(endpoint)
        endpoint.after_blocks.each do |block|
          execute_block_in_context(context, block, request, response, metadata)
        end
      end
    end

    # Dispatch the selected endpoint's handler, validating the request before and
    # the response after.
    #
    # Accessing request.params triggers parameter validation. A JSON parse error
    # or validation failure short-circuits to 400 without running the handler. A
    # halt from an earlier stage never reaches here: HaltException unwinds past
    # the handler to the Router.
    def run_handler(request, response, metadata)
      return unless @handler_endpoint.has_handler?

      request.params

      return bad_request(response, "Invalid JSON in request body") if request.json_parse_error
      return validation_failed(response, request) if request.validation_errors

      context_endpoint = @handler_endpoint.respond_to?(:leaf) ? @handler_endpoint.leaf : @handler_endpoint
      context = request.endpoint_context(context_endpoint)
      result = execute_block_in_context(context, @handler_endpoint.handler_block, request, response, metadata)
      map_handler_result(result, response) if @handler_endpoint.respond_to?(:handler_mode) && @handler_endpoint.handler_mode == :return_value

      validate_response_body(response)
    end

    def map_handler_result(result, response)
      return if result.nil?
      if result.is_a?(Raxon::Outcome)
        response.code = result.status
        result.headers.each { |key, value| response.header(key, value) }
        response.body = represent(result.body)
        return
      end

      successes = @handler_endpoint.responses.keys.select { |status| status.between?(200, 299) }
      if successes.length > 1
        raise Raxon::Error, "Return-value handler in #{@handler_endpoint.route_file_path} has multiple 2xx responses; return Raxon::Outcome or use handler"
      end
      response.code = successes.first || 200
      response.body = represent(result)
    end

    def represent(value)
      declaration = @handler_endpoint.respond_to?(:representation) && @handler_endpoint.representation
      return value unless declaration

      entry = declaration[:entry]
      entry.adapter.call(entry.resource, value, collection: declaration[:collection], params: declaration[:params])
    end

    # Write the response for a failed request validation.
    #
    # 400 by default: the request was malformed — a missing field, a value of
    # the wrong type. 422 when the request was well-formed but carried content
    # the endpoint refuses, which today means an upload whose extension is
    # outside the declared allowlist.
    #
    # Errors are reported together either way, so a request with both a missing
    # field and a rejected upload lists both; only the status differs.
    #
    # @return [void]
    def validation_failed(response, request)
      code = request.validation_unprocessable? ? :unprocessable_entity : :bad_request
      if (profile = validation_error_profile)
        response.code = profile.fetch(:status)
        response.body = profile[:body] ? profile[:body].call("Validation failed", request.validation_errors) : {error: "Validation failed", details: request.validation_errors}
        return
      end
      write_error(response, code, "Validation failed", request.validation_errors)
    end

    def validation_error_profile
      return unless @handler_endpoint.respond_to?(:validation_profile)

      name = @handler_endpoint.validation_profile
      name && Raxon.configuration.validation_error_profiles[name]
    end

    # @return [void]
    def bad_request(response, error, details = nil)
      write_error(response, :bad_request, error, details)
    end

    # @return [void]
    def write_error(response, code, error, details = nil)
      response.code = code
      body = {error: error}
      body[:details] = details if details
      response.body = body
      nil
    end

    # Execute a block in the given context instance.
    #
    # With a context instance, instance_exec runs the block with `self` set to it,
    # giving access to route-file methods and instance variables. Without one
    # (backwards compatibility for programmatic endpoints), the block is called
    # directly.
    def execute_block_in_context(context_instance, block, request, response, metadata)
      if context_instance
        context_instance.instance_exec(request, response, metadata, &block)
      else
        block.call(request, response, metadata)
      end
    end

    # Validate the response body against the schema for its status code.
    #
    # @param response [Raxon::Response]
    # @return [void]
    def validate_response_body(response)
      # Ask whether validation runs at all before looking the schema up: schemas
      # are compiled on first use, so an app with validation off should never
      # compile one.
      validation_mode = response_validation_mode
      return if validation_mode == false
      return unless response.body

      status_code = response.status_code
      schema = @handler_endpoint.response_schemas[status_code]
      return unless schema

      # Validate the coerced data, not the raw body: a handler may have returned a
      # serializer object that config.body_serializer turns into the hash/array
      # the schema describes.
      result = schema.call(response.serializable_body)
      return if result.success?

      handle_response_validation_failure(response, status_code, result.errors.to_h, validation_mode)
    end

    def response_validation_mode
      configured_mode = Raxon.configuration.response_validation
      return false if @handler_endpoint.validate_response == false
      return :error_response if @handler_endpoint.validate_response == true && configured_mode == false

      configured_mode
    end

    def handle_response_validation_failure(response, status_code, errors, validation_mode)
      case validation_mode
      when :raise
        raise Raxon::ResponseValidationError.new(status_code: status_code, errors: errors)
      when :log
        warn response_validation_failure_message(status_code, errors)
      else # :error_response, true, or any other configured value
        write_response_validation_error(response, status_code, errors)
      end
    end

    def write_response_validation_error(response, status_code, errors)
      response.code = :internal_server_error
      response.body = response_validation_error_body(status_code, errors)
    end

    def response_validation_error_body(status_code, errors)
      body = {
        error: "Response validation failed",
        status_code: status_code
      }
      body[:details] = errors if Raxon.configuration.expose_validation_details
      body
    end

    def response_validation_failure_message(status_code, errors)
      body = response_validation_error_body(status_code, errors)
      "[Raxon] Response validation failed for status #{status_code}: #{body.inspect}"
    end
  end
end
