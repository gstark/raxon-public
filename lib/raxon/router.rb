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
    end

    # Rack application entry point.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response tuple [status, headers, body]
    def call(env)
      @route_reloader&.reload_if_changed

      rack_request = Rack::Request.new(env)

      return payload_too_large_response if request_body_too_large?(rack_request)

      route_data = Raxon::RouteLoader.routes.find(rack_request.request_method, rack_request.path)

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

        allowed = Raxon::RouteLoader.routes.allowed_methods(rack_request.path)
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

      wrapper_request = Raxon::Request.new(rack_request, endpoint)
      wrapper_response = Raxon::Response.new(endpoint)
      wrapper_response.request = wrapper_request

      # Store request and response in env for error handler access
      env["raxon.request"] = wrapper_request
      env["raxon.response"] = wrapper_response

      begin
        execute_request(wrapper_request, wrapper_response, endpoint, endpoints)
      rescue Raxon::HaltException => e
        # HaltException carries the response - use it instead of wrapper_response
        # This allows halt to be called with a custom response
        wrapper_response = e.response
      end

      rack_response = wrapper_response.to_rack
      rack_response = strip_head_body(rack_response) if route_data[:head_from_get]
      debug_log { "[Raxon] Returning: status=#{rack_response[0]}, headers=#{rack_response[1].inspect}" }
      rack_response
    end

    private

    def debug_log
      return unless ENV["RAXON_DEBUG"]

      warn yield
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

      begin
        if config.around_blocks.empty? && !config.rails_compatible_instrumentation
          execute_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
        else
          execute_wrapped_request_pipeline(request, response, handler_endpoint, endpoints, metadata, config)
        end
      rescue Raxon::HaltException
        raise # Let HaltException propagate (flow control)
      rescue => exception
        handler = find_exception_handler(exception, config.exception_handlers)
        if handler
          handler.call(exception, request, response, metadata)
        else
          raise # Propagate to ErrorHandler middleware
        end
      end
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

      # Wrap with instrumentation if enabled
      if config.rails_compatible_instrumentation
        Instrumentation.instrument_request(request, response, handler_endpoint) do
          wrapped_execution.call
        end
      else
        wrapped_execution.call
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
        wrapper_response = e.response
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
        response = e.response
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

      content_length.to_i > max
    end

    def payload_too_large_response
      [
        413,
        {"content-type" => "application/json"},
        [%({"error":"Payload Too Large"})]
      ]
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
