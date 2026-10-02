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
  #   3. the selected endpoint's handler, with request validation
  #   4. after blocks, child -> parent
  #
  # Response validation is a separate call, {#validate_response}. The Router
  # makes it after the global after blocks, so it checks the body that is sent.
  #
  # A before block that halts raises HaltException, which unwinds past the handler
  # and after blocks to the Router (flow control), matching the documented order.
  #
  # @example
  #   invocation = Raxon::EndpointInvocation.new(handler_endpoint, endpoints)
  #   invocation.run(request, response, metadata)
  #   invocation.validate_response(request, response)
  class EndpointInvocation
    # @param handler_endpoint [Raxon::OpenApi::Endpoint] The selected endpoint
    #   whose handler runs (and whose schemas validate the request/response).
    # @param endpoints [Array<Raxon::OpenApi::Endpoint>] The matched hierarchy,
    #   ordered parent to child.
    def initialize(handler_endpoint, endpoints)
      @handler_endpoint = handler_endpoint
      @endpoints = endpoints
      @handler_ran = false
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

    # Validate the response body against the schema for its status code.
    #
    # Runs only when the handler ran. A 400 for an invalid request or a 401
    # from an authenticator is Raxon's own answer, not the handler's.
    #
    # @param request [Raxon::Request]
    # @param response [Raxon::Response]
    # @return [void]
    def validate_response(request, response)
      validate_response_body(request, response) if @handler_ran
    end

    private

    # Enforce the endpoint's declared security requirements.
    #
    # OpenAPI semantics: the requirements array is an OR (any one grants
    # access) and the schemes within a requirement are an AND (all must pass).
    #
    # Enforcement fails closed. A scheme grants access only through its
    # authenticator block; a scheme without one can never pass, so a
    # requirement naming it fails. Before this rule, such requirements were
    # skipped, which let an AND with one blockless scheme admit a request with
    # no credentials, and let a child route's documentation-only +security+
    # replace an enforced parent requirement.
    #
    # The one exception is a scheme declared +enforce: false+: the application
    # authenticates elsewhere, so when every scheme the endpoint names is one,
    # nothing runs here. Naming both kinds, in one requirement or across
    # alternatives, has no safe reading (skip the check, or reject callers the
    # other code would admit), so it raises.
    #
    # A requirement naming a scheme that was never declared is almost always a
    # typo or a scheme defined after the route loaded, and also fails closed.
    #
    # Authenticator blocks receive (request, metadata, scopes) and grant access
    # by returning truthy. When no requirement passes, the response becomes a
    # 401 and the rest of the lifecycle (before blocks, handler, after blocks)
    # is skipped.
    #
    # @return [Boolean] true when the request may proceed
    # @raise [Raxon::Error] when the requirements mix enforce: false and enforced schemes
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
        requirement.keys.any? { |name| !schemes.key?(name) }
      end
      return deny(response, requirements, schemes) if references_undeclared_scheme

      documentation_only = requirements.flat_map do |requirement|
        requirement.keys.map { |name| schemes[name].documentation_only? }
      end
      if documentation_only.any?
        return true if documentation_only.all?

        raise Raxon::Error, "Security requirements #{requirements.inspect} in #{@handler_endpoint.route_file_path} " \
          "mix enforce: false schemes with enforced ones"
      end

      granted = requirements.any? do |requirement|
        requirement.all? do |name, scopes|
          authenticator = schemes[name].authenticator
          authenticator&.call(request, metadata, scopes)
        end
      end
      return true if granted

      deny(response, requirements, schemes)
    end

    # Set the response to a 401 and signal that the lifecycle should stop.
    #
    # A 401 must carry WWW-Authenticate (RFC 9110 section 15.5.2), with one
    # challenge for each declared scheme the requirements name.
    #
    # An authenticator that recognizes the caller but finds too little scope
    # should answer 403 instead: Raxon.halt(code: :forbidden, ...).
    #
    # @return [false]
    def deny(response, requirements, schemes)
      response.code = :unauthorized
      response.body = {error: "Unauthorized"}
      realm = Raxon.configuration.openapi_title
      challenges = requirements.flat_map(&:keys).uniq.filter_map { |name| schemes[name]&.challenge(realm) }.uniq
      response.header("www-authenticate", challenges.join(", ")) if challenges.any?
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

    # Dispatch the selected endpoint's handler, validating the request first.
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
      @handler_ran = true
    end

    def map_handler_result(result, response)
      # A handle block that streamed returns whatever its last expression was
      # (often the response itself); that is not a body.
      return if response.streaming?
      return if result.nil?
      if result.is_a?(Raxon::Outcome)
        response.code = result.status
        result.headers.each { |key, value| response.header(key, value) }
        response.body = represent(result.body, status: result.status)
        return
      end

      successes = @handler_endpoint.responses.keys.select { |status| status.between?(200, 299) }
      if successes.length > 1
        raise Raxon::Error, "Return-value handler in #{@handler_endpoint.route_file_path} has multiple 2xx responses; return Raxon::Outcome or use handler"
      end
      response.code = successes.first || 200
      response.body = represent(result)
    end

    # Serialize a handler's return value through the endpoint's representation.
    # An Outcome passes its status, and only the status +represents+ declared
    # is serialized: an error Outcome (a 404 or 422 body) is not the resource
    # and goes out as the handler wrote it.
    def represent(value, status: nil)
      declaration = @handler_endpoint.respond_to?(:representation) && @handler_endpoint.representation
      return value unless declaration
      return value if status && Raxon::OpenApi::DocumentBuilder.status_to_code(status) != declaration[:status]

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
      return unless name

      Raxon.configuration.validation_error_profiles.fetch(name) do
        raise Raxon::Error, "Unknown validation_profile #{name.inspect} in #{@handler_endpoint.route_file_path}"
      end
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

    def validate_response_body(request, response)
      # Ask whether validation runs at all before looking the schema up: schemas
      # are compiled on first use, so an app with validation off should never
      # compile one.
      validation_mode = response_validation_mode
      return if validation_mode == false
      # A streamed body does not exist yet; it is produced after this pipeline
      # returns, chunk by chunk, so there is nothing to check against a schema.
      return if response.streaming?
      return unless response.body

      status_code = response.status_code
      schema = @handler_endpoint.response_schemas[status_code]
      return unless schema

      # Validate the coerced data, not the raw body: a handler may have returned a
      # serializer object that config.body_serializer turns into the hash/array
      # the schema describes, or a JSON::Fragment of pre-encoded JSON.
      result = schema.call(response.validation_body)
      return if result.success?

      handle_response_validation_failure(request, response, status_code, result.errors.to_h, validation_mode)
    end

    def response_validation_mode
      configured_mode = Raxon.configuration.response_validation
      return false if @handler_endpoint.validate_response == false
      return :error_response if @handler_endpoint.validate_response == true && configured_mode == false

      configured_mode
    end

    def handle_response_validation_failure(request, response, status_code, errors, validation_mode)
      case validation_mode
      when :raise
        raise Raxon::ResponseValidationError.new(status_code: status_code, errors: errors)
      when :log
        log_response_validation_failure(request, status_code, errors)
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

    # Log a failure to config.logger, or to stderr without one.
    #
    # The log is server-side, so it always has the field errors, whatever
    # expose_validation_details says about the client. The errors are dry-schema
    # messages ("is missing", "must be a string"), never the values. The route
    # and request line say which handler to fix.
    def log_response_validation_failure(request, status_code, errors)
      message = "[Raxon] Response validation failed: #{request.method} #{request.path} " \
        "(#{@handler_endpoint.route_file_path || "no route file"}) status #{status_code}: #{errors.inspect}"
      message = message.gsub(/[[:cntrl:]]/, " ")

      logger = Raxon.configuration.logger
      if logger.respond_to?(:warn)
        logger.warn(message)
      else
        warn message
      end
    end
  end
end
