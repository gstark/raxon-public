# frozen_string_literal: true

module Raxon
  # Response object for API endpoint handlers.
  #
  # This class wraps Rack::Response and provides convenience methods for building
  # HTTP responses in endpoint handlers. It delegates to Rack::Response for the
  # heavy lifting while providing a clean DSL for common operations.
  #
  # @example
  #   endpoint.handler do |request, response|
  #     response.code = :ok
  #     response.body = { success: true }
  #   end
  class Response
    attr_reader :rack_response

    # HTTP status code mappings
    STATUS_CODES = {
      continue: 100,
      switching_protocols: 101,
      processing: 102,
      early_hints: 103,

      ok: 200,
      created: 201,
      accepted: 202,
      non_authoritative_information: 203,
      no_content: 204,
      reset_content: 205,
      partial_content: 206,
      multi_status: 207,
      already_reported: 208,
      im_used: 226,

      multiple_choices: 300,
      moved_permanently: 301,
      found: 302,
      see_other: 303,
      not_modified: 304,
      use_proxy: 305,
      temporary_redirect: 307,
      permanent_redirect: 308,

      bad_request: 400,
      unauthorized: 401,
      payment_required: 402,
      forbidden: 403,
      not_found: 404,
      method_not_allowed: 405,
      not_acceptable: 406,
      proxy_authentication_required: 407,
      request_timeout: 408,
      conflict: 409,
      gone: 410,
      length_required: 411,
      precondition_failed: 412,
      payload_too_large: 413,
      uri_too_long: 414,
      unsupported_media_type: 415,
      range_not_satisfiable: 416,
      expectation_failed: 417,
      im_a_teapot: 418,
      misdirected_request: 421,
      unprocessable_entity: 422,
      locked: 423,
      failed_dependency: 424,
      too_early: 425,
      upgrade_required: 426,
      precondition_required: 428,
      too_many_requests: 429,
      request_header_fields_too_large: 431,
      unavailable_for_legal_reasons: 451,

      internal_server_error: 500,
      not_implemented: 501,
      bad_gateway: 502,
      service_unavailable: 503,
      gateway_timeout: 504,
      http_version_not_supported: 505,
      variant_also_negotiates: 506,
      insufficient_storage: 507,
      loop_detected: 508,
      not_extended: 510,
      network_authentication_required: 511
    }.freeze

    # Initialize a new Response with an underlying Rack::Response.
    #
    # @param endpoint [Raxon::OpenApi::Endpoint, nil] Optional endpoint for accessing route metadata
    def initialize(endpoint = nil)
      @rack_response = Rack::Response.new
      @rack_response.status = 200
      @rack_response["content-type"] = "application/json"
      @custom_body = nil
      @halted = false
      @endpoint = endpoint
    end

    # Set the response status code.
    # Delegates to Rack::Response#status=
    #
    # @param value [Symbol, Integer] Status code symbol (e.g., :ok, :not_found) or numeric code
    #
    # @example
    #   response.code = :ok          # Sets status to 200
    #   response.code = :not_found   # Sets status to 404
    #   response.code = 201          # Sets status to 201
    def code=(value)
      @rack_response.status = if value.is_a?(Symbol)
        STATUS_CODES[value] || raise(ArgumentError, "Unknown status code symbol: #{value}")
      else
        value
      end
    end

    # Get the current status code.
    # Delegates to Rack::Response#status
    #
    # @return [Integer] The HTTP status code
    #
    # @example
    #   response.code = :ok
    #   response.code  # => 200
    def code
      @rack_response.status
    end

    # Set the response body.
    # Accepts Hash, Array, String, or any object that responds to to_json.
    #
    # @param value [Hash, Array, String, Object] The response body
    #
    # @example
    #   response.body = { success: true }
    #   response.body = "Plain text response"
    def body=(value)
      @custom_body = value
    end

    # Get the response body.
    #
    # @return [Hash, Array, String, Object] The response body
    def body
      @custom_body
    end

    # Set the response body to HTML content and update content-type header.
    # This is a convenience method that sets both the body and content-type in one call.
    #
    # @param value [String] The HTML content to set as the response body
    #
    # @example
    #   response.html_body = "<h1>Hello World</h1>"
    #   response.html_body = html(name: "John", title: "Welcome")
    def html_body=(value)
      @rack_response["content-type"] = "text/html"
      @custom_body = value
    end

    # Render an ERB template with the given local variables.
    # Uses the pre-compiled ERB template stored in the endpoint for efficiency.
    #
    # @param locals [Hash] Local variables to make available in the ERB template
    # @return [String] The rendered HTML content
    # @raise [Raxon::Error] If the endpoint has no ERB template configured
    #
    # @example
    #   # In routes/users/$id/get.rb
    #   response.html_body = html(user: user, title: "User Profile")
    #   # This will render the pre-compiled routes/users/$id/get.html.erb template
    def html(**locals)
      unless @endpoint&.erb_template
        raise Raxon::Error, "Template not found"
      end

      # Use ERB's native result_with_hash for context handling.
      @endpoint.erb_template.result_with_hash(locals)
    end

    # Get the current status code.
    # Delegates to Rack::Response#status
    #
    # @return [Integer] The HTTP status code
    def status_code
      @rack_response.status
    end

    # Halt processing - no further before blocks or handlers will be called.
    #
    # When called in a before block or handler, this prevents any remaining
    # before blocks and the handler from executing. The current response will
    # be returned immediately to the client.
    #
    # This method raises a HaltException that is caught by the Router to
    # stop request processing.
    #
    # @raise [Raxon::HaltException] Always raises to stop processing
    #
    # @example
    #   endpoint.before do |request, response|
    #     unless request.headers["Authorization"]
    #       response.code = :unauthorized
    #       response.body = { error: "Unauthorized" }
    #       response.halt
    #     end
    #   end
    def halt
      @halted = true
      raise Raxon::HaltException.new(self)
    end

    # Check if processing has NOT been halted.
    #
    # @return [Boolean] true if halt has NOT been called, false otherwise
    def runnable?
      !@halted
    end

    # Check if processing has been halted.
    #
    # @return [Boolean] true if halt has been called, false otherwise
    def halted?
      @halted
    end

    # Convert this response to a Rack-compatible response array.
    # Serializes the body to JSON if it's a Hash or Array.
    #
    # @return [Array] Rack response array [status, headers, body]
    def to_rack
      # If a custom body was set, serialize it and write to Rack response
      if @custom_body
        body_content = if @custom_body.is_a?(String)
          @custom_body
        else
          JSON.generate(@custom_body)
        end

        # Clear any existing body and write the new content
        @rack_response.body.clear if @rack_response.body.respond_to?(:clear)
        @rack_response.write(body_content)
      end

      # Return the Rack response finish result
      @rack_response.finish
    end

    # Set a response header.
    # Delegates to Rack::Response#[]=
    #
    # @param key [String] Header name
    # @param value [String] Header value
    #
    # @example
    #   response.header "X-Custom-Header", "value"
    def header(key, value)
      @rack_response[key] = value
    end

    # Get response headers.
    # Delegates to Rack::Response#headers
    #
    # @return [Hash] The response headers
    def headers
      @rack_response.headers
    end

    private

    # Write directly to the Rack response body.
    # Delegates to Rack::Response#write
    #
    # @param str [String] String to write to response body
    #
    # @example
    #   response.write "Hello "
    #   response.write "World"
    def write(str)
      @rack_response.write(str)
    end

    # Set a cookie.
    # Delegates to Rack::Response#set_cookie
    #
    # @param key [String] Cookie name
    # @param value [Hash, String] Cookie value or hash with cookie options
    #
    # @example
    #   response.set_cookie "user_id", value: "123", path: "/", httponly: true
    def set_cookie(key, value)
      @rack_response.set_cookie(key, value)
    end

    # Delete a cookie.
    # Delegates to Rack::Response#delete_cookie
    #
    # @param key [String] Cookie name
    # @param value [Hash] Cookie options (path, domain, etc.)
    #
    # @example
    #   response.delete_cookie "user_id"
    def delete_cookie(key, value = {})
      @rack_response.delete_cookie(key, value)
    end

    # Redirect to a URL.
    # Delegates to Rack::Response#redirect
    #
    # @param target [String] URL to redirect to
    # @param status [Integer] HTTP status code (default: 302)
    #
    # @example
    #   response.redirect "/login", 302
    def redirect(target, status = 302)
      @rack_response.redirect(target, status)
    end
  end
end
