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
    end

    # Rack application entry point.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response tuple [status, headers, body]
    def call(env)
      rack_request = Rack::Request.new(env)

      route_data = Raxon::RouteLoader.routes.find(rack_request.request_method, rack_request.path)

      if route_data.nil?
        # Try catchall endpoint first
        if Raxon::RouteLoader.catchall
          debug_log "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, using catchall"
          return execute_catchall(env, rack_request)
        end

        # If a fallback app is configured, delegate to it for unmatched routes
        if fallback
          debug_log "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, delegating to fallback"
          result = fallback.call(env)
          debug_log "[Raxon] Fallback returned: status=#{result[0]}, headers=#{result[1].inspect}, body_class=#{result[2].class}"
          return result
        else
          debug_log "[Raxon] No route match for #{rack_request.request_method} #{rack_request.path}, no fallback configured, returning 404"
          return not_found_response
        end
      end

      debug_log "[Raxon] Route matched: #{rack_request.request_method} #{rack_request.path} -> #{route_data[:endpoint].route_file_path}"

      # Set route params in env for Request to access
      if route_data[:params]
        env["router.params"] = route_data[:params]
      end

      endpoint = route_data[:endpoint]
      endpoints = route_data[:endpoints]

      wrapper_request = Raxon::Request.new(rack_request, endpoint)
      wrapper_response = Raxon::Response.new(endpoint)

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
      debug_log "[Raxon] Returning: status=#{rack_response[0]}, headers=#{rack_response[1].inspect}"
      rack_response
    end

    private

    def debug_log(message)
      return unless ENV["RAXON_DEBUG"]

      warn message
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
      metadata = {}

      # Build the core execution as a proc
      core_execution = proc do
        # Execute global before blocks
        config.before_blocks.each do |before_block|
          before_block.call(request, response, metadata)
        end

        # Execute route hierarchy
        execute_with_hierarchy(request, response, handler_endpoint, endpoints, metadata)

        # Execute global after blocks
        config.after_blocks.each do |after_block|
          after_block.call(request, response, metadata)
        end
      end

      # Wrap with around blocks (first registered is outermost)
      wrapped_execution = config.around_blocks.reverse.reduce(core_execution) do |inner, around_block|
        proc { around_block.call(request, response, metadata, &inner) }
      end

      begin
        wrapped_execution.call
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

    def execute_with_hierarchy(request, response, handler_endpoint, endpoints, metadata = {})
      # Build metadata from parent to child, with later values overriding earlier ones
      endpoints.each do |endpoint|
        if endpoint.has_metadata?
          endpoint.metadata_blocks.each do |metadata_block|
            metadata_block.call(request, response, metadata)
          end
        end
      end

      # Execute before blocks from parent to child
      # Multiple before blocks per endpoint are executed in the order they were defined
      # If halt is called, HaltException will be raised and caught by the caller
      endpoints.each do |endpoint|
        if endpoint.has_before?
          endpoint.before_blocks.each do |before_block|
            before_block.call(request, response, metadata)
          end
        end
      end

      # Execute the final handler with the accumulated metadata
      # If halt was called in a before block, we never get here due to the exception
      if handler_endpoint.has_handler?
        handler_endpoint.call(request, response, metadata)
      end

      # Execute after blocks from child to parent (reverse order)
      # Multiple after blocks per endpoint are executed in the order they were defined
      # If halt is called in an after block, HaltException will be raised and caught by the caller
      endpoints.reverse_each do |endpoint|
        if endpoint.has_after?
          endpoint.after_blocks.each do |after_block|
            after_block.call(request, response, metadata)
          end
        end
      end
    end

    def execute_catchall(env, rack_request)
      endpoint = Raxon::RouteLoader.catchall

      wrapper_request = Raxon::Request.new(rack_request, endpoint)
      wrapper_response = Raxon::Response.new(endpoint)

      env["raxon.request"] = wrapper_request
      env["raxon.response"] = wrapper_response

      begin
        execute_request(wrapper_request, wrapper_response, endpoint, [endpoint])
      rescue Raxon::HaltException => e
        wrapper_response = e.response
      end

      rack_response = wrapper_response.to_rack
      debug_log "[Raxon] Catchall returning: status=#{rack_response[0]}, headers=#{rack_response[1].inspect}"
      rack_response
    end

    def not_found_response
      [
        404,
        {"content-type" => "application/json"},
        [%({"error":"Not Found"})]
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
