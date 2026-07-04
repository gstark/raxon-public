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
    # authenticator block; requirements referencing documentation-only schemes
    # are skipped, and when no requirement is enforceable the declaration is
    # documentation-only and nothing runs (backwards compatible).
    #
    # Authenticator blocks receive (request, metadata, scopes) and grant access
    # by returning truthy. When no enforceable requirement passes, the response
    # becomes a 401 and the rest of the lifecycle (before blocks, handler,
    # after blocks) is skipped.
    #
    # @return [Boolean] true when the request may proceed
    def authenticate(request, response, metadata)
      requirements = Array(@handler_endpoint.security)
      return true if requirements.empty?

      schemes = Raxon::OpenApi::DSL.security_schemes
      enforceable = requirements.select do |requirement|
        requirement.keys.all? { |name| schemes[name.to_sym]&.authenticator }
      end
      return true if enforceable.empty?

      granted = enforceable.any? do |requirement|
        requirement.all? do |name, scopes|
          schemes[name.to_sym].authenticator.call(request, metadata, scopes)
        end
      end
      return true if granted

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
      return bad_request(response, "Validation failed", request.validation_errors) if request.validation_errors

      context = request.endpoint_context(@handler_endpoint)
      execute_block_in_context(context, @handler_endpoint.handler_block, request, response, metadata)

      validate_response_body(response)
    end

    # @return [void]
    def bad_request(response, error, details = nil)
      response.code = :bad_request
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
      status_code = response.status_code
      schema = @handler_endpoint.response_schemas[status_code]

      return unless schema && response.body

      validation_mode = response_validation_mode
      return if validation_mode == false

      result = schema.call(response.body)
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
