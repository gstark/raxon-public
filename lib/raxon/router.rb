module Raxon
  # Rack-compatible router that loads routes from the configured directory.
  #
  # The Router uses the Raxon configuration system to determine where
  # to load routes from. This allows configuration through either the
  # environment variable or Raxon.configure block.
  #
  # Example:
  #   Raxon.configure do |config|
  #     config.routes_directory = "app/routes"
  #   end
  #
  #   app = Raxon::Router.new
  class Router
    extend Dry::Initializer

    # Optional Rack application to handle unmatched routes.
    # If provided, requests that don't match any Raxon route will be delegated
    # to this application instead of returning a 404. This allows embedding
    # Raxon in a larger Rack stack (e.g., Rails).
    #
    # @example
    #   Raxon.configure do |config|
    #     config.routes_directory = "app/routes"
    #   end
    #
    #   app = Raxon::Router.new
    #
    # @example With fallback app
    #   router = Raxon::Router.new(fallback: Rails.application)
    option :fallback, optional: true

    def initialize(**options)
      super
      # Load handler helpers when router is initialized
      Raxon.load_helpers
      # Load routes from the configured directories so `run Raxon::Server.new`
      # works without an explicit boot-time RouteLoader.load!. Already-loaded
      # files are tracked and skipped, so apps (and tests) that load or define
      # routes beforehand are unaffected.
      Raxon::RouteLoader.load!
      @route_reloader = Raxon::RouteReloader.new if Raxon.configuration.reload_routes?
      # Read once rather than per #debug_log call. ENV[] is a getenv, and the
      # lifecycle logging calls debug_log on every request whether or not it is
      # enabled, which cost ~0.24us of a ~7us plaintext response. The tradeoff
      # is that RAXON_DEBUG has to be set before the router is built, which is
      # how it was already used: the server builds one router at boot.
      @debug = !ENV["RAXON_DEBUG"].nil?
    end

    # Rack application entry point.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response tuple [status, headers, body]
    def call(env)
      @route_reloader&.reload_if_changed

      rack_request = Rack::Request.new(env)

      return payload_too_large_response if request_body_too_large?(rack_request)

      apply_body_size_limit(env)

      # Read the registry once. Under hot reloading a reload can publish a new
      # one between the lookup and the allowed-methods check below, and
      # answering a single request from two generations would be incoherent.
      routes = Raxon::RouteLoader.routes
      path = request_path(rack_request)
      route_data = routes.find(rack_request.request_method, path)

      if route_data.nil?
        # Try catchall endpoint first
        if Raxon::RouteLoader.catchall
          debug_log { "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, using catchall" }
          return execute_catchall(env, rack_request)
        end

        # If a fallback app is configured, delegate to it for unmatched routes
        if fallback
          debug_log { "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, delegating to fallback" }
          result = fallback.call(env)
          debug_log { "[Raxon] Fallback returned: status=#{result[0]}, headers=#{result[1].inspect}, body_class=#{result[2].class}" }
          return result
        end

        allowed = routes.allowed_methods(path)
        if allowed.any?
          if rack_request.request_method == "OPTIONS"
            debug_log { "[Raxon] Automatic OPTIONS response for #{rack_request.path}: #{allowed.join(", ")}" }
            return auto_options_response(allowed)
          end

          debug_log { "[Raxon] Method not allowed: #{rack_request.request_method} #{rack_request.path}, allowed: #{allowed.join(", ")}" }
          return method_not_allowed_response(allowed)
        end

        debug_log { "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, no fallback configured, returning 404" }
        return not_found_response(rack_request)
      end

      debug_log { "[Raxon] Route matched: #{rack_request.request_method} #{rack_request.path} -> #{route_data[:endpoint].route_file_path}" }

      # Set route params in env for Request to access
      if route_data[:params]
        env["router.params"] = route_data[:params]
      end

      endpoint = route_data[:endpoint]
      endpoints = route_data[:endpoints]
      effective_endpoint = route_data[:effective_endpoint] || endpoint

      wrapper_request = Raxon::Request.new(rack_request, effective_endpoint)
      wrapper_response = Raxon::Response.new(endpoint)
      wrapper_response.request = wrapper_request

      # Store request and response in env for error handler access
      env["raxon.request"] = wrapper_request
      env["raxon.response"] = wrapper_response

      begin
        execute_request(wrapper_request, wrapper_response, effective_endpoint, endpoints)
      rescue Raxon::HaltException => e
        wrapper_response = response_from_halt(e, wrapper_response)
      rescue Raxon::RequestBodyTooLarge
        return payload_too_large_response
      rescue Rack::BadRequest => e
        return malformed_request_response(e)
      end

      rack_response = wrapper_response.to_rack
      rack_response = strip_head_body(rack_response) if route_data[:head_from_get]
      debug_log { "[Raxon] Returning: status=#{rack_response[0]}, headers=#{rack_response[1].inspect}" }
      rack_response
    end

    private

    # Resolve a caught HaltException into the response to send. Response#halt
    # carries a prepared response; Raxon.halt carries a code/body/headers tuple,
    # which is applied to the response the Router already owns so headers and
    # other state set earlier in the request survive.
    #
    # @param exception [Raxon::HaltException]
    # @param owned_response [Raxon::Response]
    # @return [Raxon::Response]
    def response_from_halt(exception, owned_response)
      return exception.response if exception.carries_response?

      owned_response.code = exception.code if exception.code
      exception.headers&.each { |name, value| owned_response.header(name, value) }
      owned_response.body = exception.body if exception.body?
      owned_response
    end

    def debug_log
      return unless @debug

      warn yield
    end

    # The path to route on.
    #
    # Rack::Request#path builds script_name + path_info, allocating a string per
    # request to describe a path the env already holds. Mounted under a prefix
    # that concatenation is the whole point, so it still happens; unmounted —
    # every standalone Raxon app — PATH_INFO already is the path.
    #
    # @param rack_request [Rack::Request]
    # @return [String]
    def request_path(rack_request)
      script_name = rack_request.script_name
      return rack_request.path_info if script_name.nil? || script_name.empty?

      rack_request.path
    end

    # Executes a request with global before/after/around blocks wrapping the route hierarchy.
    #
    # Execution order:
    # 1. Global around blocks (outermost to innermost, wrapping everything)
    # 2. Global before blocks (in order)
    # 3. Route hierarchy metadata blocks (parent to child)
    # 4. Route hierarchy before blocks (parent to child)
    # 5. Handler
    # 6. Route hierarchy after blocks (child to parent)
    # 7. Global after blocks (in order)
    #
    # @param request [Raxon::Request] The request object
    # @param response [Raxon::Response] The response object
    # @param handler_endpoint [Raxon::OpenApi::Endpoint] The endpoint with the handler
    # @param endpoints [Array<Raxon::OpenApi::Endpoint>] The endpoint hierarchy (parent to child)
    def execute_request(request, response, handler_endpoint, endpoints)
      config = Raxon.configuration
      metadata = request.metadata

      if config.around_blocks.empty? && !config.rails_compatible_instrumentation
        dispatch_with_exception_handlers(request, response, metadata, config) do
          execute_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
        end
      else
        execute_wrapped_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
      end
    end

    # Runs the block, dispatching rescuable exceptions to configured handlers.
    # Must run INSIDE instrumentation so the logged status reflects what the
    # handler wrote to the response (previously the log claimed the pre-error
    # status, e.g. "200 OK" for a request whose handler answered 422). The
    # handled exception is stashed in request metadata so instrumentation can
    # still include it in the payload despite it never propagating.
    def dispatch_with_exception_handlers(request, response, metadata, config)
      yield
    rescue Raxon::HaltException
      raise # Let HaltException propagate (flow control)
    rescue Raxon::RequestBodyTooLarge
      raise # Always a 413 (see Router#call); never a user-handled error
    rescue Rack::BadRequest
      raise # A malformed request is a 400/413 (see Router#call), not an app error
    rescue => exception
      handler = find_exception_handler(exception, config.exception_handlers)
      raise unless handler # Propagate to ErrorHandler middleware

      request.metadata[:handled_exception] = exception
      handler.call(exception, request, response, metadata)
    end

    def execute_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
      # Execute global before blocks
      config.before_blocks.each do |before_block|
        before_block.call(request, response, metadata)
      end

      # Execute the matched route hierarchy
      EndpointInvocation.new(handler_endpoint, endpoints).run(request, response, metadata)

      # Execute global after blocks
      config.after_blocks.each do |after_block|
        after_block.call(request, response, metadata)
      end
    end

    def execute_wrapped_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
      core_execution = proc do
        execute_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
      end

      # Wrap with around blocks (first registered is outermost)
      wrapped_execution = config.around_blocks.reverse.reduce(core_execution) do |inner, around_block|
        proc { around_block.call(request, response, metadata, &inner) }
      end

      # Wrap with instrumentation if enabled. Exception handlers run inside
      # the instrumented block so the logged status is the handler's status.
      if config.rails_compatible_instrumentation
        Instrumentation.instrument_request(request, response, handler_endpoint) do
          dispatch_with_exception_handlers(request, response, metadata, config) do
            wrapped_execution.call
          end
        end
      else
        dispatch_with_exception_handlers(request, response, metadata, config) do
          wrapped_execution.call
        end
      end
    end

    def execute_catchall(env, rack_request)
      endpoint = Raxon::RouteLoader.catchall

      wrapper_request = Raxon::Request.new(rack_request, endpoint)
      wrapper_response = Raxon::Response.new(endpoint)
      wrapper_response.request = wrapper_request

      env["raxon.request"] = wrapper_request
      env["raxon.response"] = wrapper_response

      begin
        execute_request(wrapper_request, wrapper_response, endpoint, [endpoint])
      rescue Raxon::HaltException => e
        wrapper_response = response_from_halt(e, wrapper_response)
      rescue Raxon::RequestBodyTooLarge
        return payload_too_large_response
      rescue Rack::BadRequest => e
        return malformed_request_response(e)
      end

      rack_response = wrapper_response.to_rack
      debug_log { "[Raxon] Catchall returning: status=#{rack_response[0]}, headers=#{rack_response[1].inspect}" }
      rack_response
    end

    # HEAD requests served by the GET route (see Routes#prepare_head_fallback)
    # must not send a body; headers (including content-type) stand as computed.
    def strip_head_body(rack_response)
      body = rack_response[2]
      body.close if body.respond_to?(:close)

      [rack_response[0], rack_response[1], []]
    end

    def auto_options_response(allowed)
      [
        204,
        {"allow" => allowed.join(", ")},
        []
      ]
    end

    def method_not_allowed_response(allowed)
      [
        405,
        {"content-type" => "application/json", "allow" => allowed.join(", ")},
        [%({"error":"Method Not Allowed"})]
      ]
    end

    def not_found_response(rack_request)
      handler = Raxon.configuration.not_found_handler
      return default_not_found_response unless handler

      request = Raxon::Request.new(rack_request)
      response = Raxon::Response.new
      response.request = request
      response.code = :not_found
      response.body = {error: "Not Found"}

      begin
        handler.call(request, response)
      rescue Raxon::HaltException => e
        response = response_from_halt(e, response)
      end

      response.to_rack
    end

    def default_not_found_response
      [
        404,
        {"content-type" => "application/json"},
        [%({"error":"Not Found"})]
      ]
    end

    # Whether the declared request body exceeds the configured maximum.
    #
    # This is an early, cheap guard on the Content-Length header so oversized
    # bodies are rejected before Raxon reads them into memory. It is a first line
    # of defense, not a complete one (a client can lie about Content-Length or
    # stream a chunked body); pair it with a body-limiting proxy/middleware for
    # untrusted traffic.
    def request_body_too_large?(rack_request)
      max = Raxon.configuration.max_request_body_size
      return false unless max

      content_length = rack_request.get_header("CONTENT_LENGTH")
      return false if content_length.nil? || content_length.empty?

      # Parse strictly: String#to_i would read "999999999garbage" as a valid
      # length and silently truncate, letting a lie about Content-Length slip
      # past the guard. A header that does not parse as a non-negative integer
      # is itself malformed, so reject it when a limit is in force.
      parsed = begin
        Integer(content_length, 10)
      rescue ArgumentError, TypeError
        return true
      end

      parsed.negative? || parsed > max
    end

    # Wrap the Rack input in a size-enforcing stream so an over-limit body is
    # rejected mid-read even when Content-Length lies or is absent (chunked
    # transfer). The early Content-Length check above is the cheap first pass;
    # this is the one that cannot be evaded. No-op when no limit is configured.
    def apply_body_size_limit(env)
      max = Raxon.configuration.max_request_body_size
      return unless max

      input = env["rack.input"]
      return unless input

      env["rack.input"] = Raxon::LimitedInput.new(input, max)
    end

    def payload_too_large_response
      [
        413,
        {"content-type" => "application/json"},
        [%({"error":"Payload Too Large"})]
      ]
    end

    # Turn a Rack parse/limit failure into a client error response. Multipart
    # part/size-limit breaches are 413; every other malformed request (bad
    # encoding, conflicting parameter types, over-nested params, ...) is 400.
    # Handled here in the router, so these expected client errors become a clean
    # response instead of a 500 — and never reach the exception-tracking path.
    #
    # @param exception [Rack::BadRequest]
    # @return [Array] Rack response tuple
    def malformed_request_response(exception)
      return payload_too_large_response if rack_size_limit_error?(exception)

      [
        400,
        {"content-type" => "application/json"},
        [%({"error":"Bad Request"})]
      ]
    end

    # Whether a Rack::BadRequest is a multipart part/size-limit breach (413) as
    # opposed to a malformed-parse error (400). Guarded with const_defined? so it
    # stays correct across Rack 3.x point releases.
    #
    # @param exception [Rack::BadRequest]
    # @return [Boolean]
    def rack_size_limit_error?(exception)
      %i[MultipartPartLimitError MultipartTotalPartLimitError].any? do |name|
        Rack::Multipart.const_defined?(name) && exception.is_a?(Rack::Multipart.const_get(name))
      end
    end

    # Find the most specific exception handler for an exception.
    #
    # Walks up the exception's ancestor chain from most specific to least specific,
    # returning the first matching handler found.
    #
    # @param exception [Exception] The exception to find a handler for
    # @param handlers [Hash<Class, Proc>] Registered exception handlers
    # @return [Proc, nil] The matching handler block, or nil if no match
    def find_exception_handler(exception, handlers)
      return nil if handlers.empty?

      ancestor = exception.class.ancestors.find { |ancestor| handlers.key?(ancestor) }

      ancestor ? handlers[ancestor] : nil
    end
  end
end
