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

    HALT_BODY_UNSET = Object.new.freeze
    private_constant :HALT_BODY_UNSET

    # Initialize a new Response with an underlying Rack::Response.
    #
    # @param endpoint [Raxon::OpenApi::Endpoint, nil] Optional endpoint for accessing route metadata
    def initialize(endpoint = nil)
      @rack_response = nil
      @status = 200
      @headers = {"content-type" => "application/json"}
      @custom_body = nil
      @halted = false
      @endpoint = endpoint
      @request = nil
    end

    # The request being responded to, set by the Router. Enables conditional
    # GET helpers (#etag, #last_modified) to inspect If-None-Match and
    # If-Modified-Since headers.
    #
    # @return [Raxon::Request, nil]
    attr_accessor :request

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
      status = if value.is_a?(Symbol)
        STATUS_CODES[value] || raise(ArgumentError, "Unknown status code symbol: #{value}")
      else
        value
      end

      @status = status
      @rack_response.status = status if @rack_response
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
      @rack_response ? @rack_response.status : @status
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

    # Set a 200 OK response with a JSON body.
    #
    # @param value [Hash, Array, String, Object, nil] Optional positional body
    # @param kwargs [Hash] Optional keyword body
    # @return [Response] self for chaining
    #
    # @example
    #   response.ok(success: true)
    #   response.ok({ users: [] })
    def ok(value = nil, **kwargs)
      respond_with(:ok, response_body_from(value, kwargs))
    end

    # Set a 201 Created response with a JSON body.
    #
    # @param value [Hash, Array, String, Object, nil] Optional positional body
    # @param kwargs [Hash] Optional keyword body
    # @return [Response] self for chaining
    #
    # @example
    #   response.created(user)
    #   response.created(id: 123)
    def created(value = nil, **kwargs)
      respond_with(:created, response_body_from(value, kwargs))
    end

    # Set a 204 No Content response with no body.
    #
    # @return [Response] self for chaining
    #
    # @example
    #   response.no_content
    def no_content
      respond_with(:no_content, nil)
    end

    # Set a 404 Not Found response.
    #
    # @param value [Hash, Array, String, Object, nil] Optional positional body
    # @param kwargs [Hash] Optional keyword body
    # @return [Response] self for chaining
    #
    # @example
    #   response.not_found(error: "User not found")
    def not_found(value = nil, **kwargs)
      respond_with(:not_found, response_body_from(value, kwargs, default: {error: "Not Found"}))
    end

    # Set an error response with a standard `{ error: message }` body.
    #
    # @param message [String] Error message
    # @param status [Symbol, Integer] HTTP status code (default: :bad_request)
    # @return [Response] self for chaining
    #
    # @example
    #   response.error("Unauthorized", status: :unauthorized)
    def error(message, status: :bad_request)
      respond_with(status, {error: message})
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
      header "content-type", "text/html"
      @custom_body = value
    end

    # Render an ERB template with the given local variables.
    # Uses the pre-compiled ERB template stored in the endpoint for efficiency.
    #
    # Output is HTML-escaped by default (via Raxon::Template/Erubi), so
    # user-controlled locals interpolated with +<%= %>+ cannot inject markup.
    # Use +<%== %>+ in the template for values that are intentionally raw HTML.
    #
    # @param locals [Hash] Local variables to make available in the template
    # @return [String] The rendered HTML content
    # @raise [Raxon::Error] If the endpoint has no template configured
    #
    # @example
    #   # In routes/users/$id/get.rb
    #   response.html_body = html(user: user, title: "User Profile")
    #   # This will render the pre-compiled routes/users/$id/get.html.erb template
    def html(**locals)
      unless @endpoint&.erb_template
        raise Raxon::Error, "Template not found"
      end

      @endpoint.erb_template.render(locals)
    end

    # Get the current status code.
    # Delegates to Rack::Response#status
    #
    # @return [Integer] The HTTP status code
    def status_code
      @rack_response ? @rack_response.status : @status
    end

    # Set the ETag header and halt with 304 Not Modified when the request's
    # If-None-Match header already carries a matching value.
    #
    # The value is quoted per RFC 9110 (pass an already-quoted string to use it
    # verbatim) and marked weak by default, which is appropriate for
    # semantically-equivalent JSON bodies. The freshness check only applies to
    # GET and HEAD requests; for other methods (or a response with no attached
    # request) only the header is set.
    #
    # @param value [String, #to_s] The entity tag value
    # @param weak [Boolean] Emit a weak validator (W/ prefix), default true
    # @return [String] The full ETag header value
    # @raise [Raxon::HaltException] When the request is fresh (halts with 304)
    #
    # @example
    #   endpoint.handler do |request, response|
    #     user = find_user(request.params[:id])
    #     response.etag user.cache_key  # halts with 304 when unchanged
    #     response.ok user.as_json
    #   end
    def etag(value, weak: true)
      full_etag = quote_etag(value.to_s)
      full_etag = "W/#{full_etag}" if weak
      header "etag", full_etag

      halt_not_modified if etag_fresh?(full_etag)
      full_etag
    end

    # Set the Last-Modified header and halt with 304 Not Modified when the
    # request's If-Modified-Since header is at least as recent.
    #
    # The freshness check only applies to GET and HEAD requests; for other
    # methods (or a response with no attached request) only the header is set.
    #
    # @param time [Time, #to_time] The resource's last modification time
    # @return [void]
    # @raise [Raxon::HaltException] When the request is fresh (halts with 304)
    #
    # @example
    #   response.last_modified user.updated_at
    def last_modified(time)
      time = time.to_time if time.respond_to?(:to_time)
      header "last-modified", time.httpdate

      halt_not_modified if last_modified_fresh?(time)
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
    # @param code [Symbol, Integer, nil] Optional status code to set before halting
    # @param body [Hash, Array, String, Object, nil] Optional body to set before halting
    #
    # @example
    #   endpoint.before do |request, response|
    #     unless request.headers["Authorization"]
    #       response.halt code: :unauthorized, body: { error: "Unauthorized" }
    #     end
    #   end
    def halt(code: nil, body: HALT_BODY_UNSET)
      self.code = code unless code.nil?
      self.body = body unless body.equal?(HALT_BODY_UNSET)
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

    # Access the underlying Rack::Response, creating it lazily for APIs that need
    # Rack's cookie, redirect, or streaming behavior.
    def rack_response
      return @rack_response if @rack_response

      @rack_response = Rack::Response.new
      @rack_response.status = @status
      @headers.each { |key, value| @rack_response[key] = value }
      @rack_response
    end

    # Convert this response to a Rack-compatible response array.
    # Serializes the body to JSON if it's a Hash or Array.
    #
    # @return [Array] Rack response array [status, headers, body]
    def to_rack
      if @rack_response
        # If a custom body was set, serialize it and write to Rack response
        if @custom_body
          @rack_response.body.clear if @rack_response.body.respond_to?(:clear)
          @rack_response.write(serialized_custom_body)
        end

        return @rack_response.finish
      end

      [@status, @headers, @custom_body ? [serialized_custom_body] : []]
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
      if @rack_response
        @rack_response[key] = value
      else
        @headers[key] = value
      end
    end

    # Get response headers.
    # Delegates to Rack::Response#headers
    #
    # @return [Hash] The response headers
    def headers
      @rack_response ? @rack_response.headers : @headers
    end

    private

    def respond_with(status, value)
      self.code = status
      self.body = value
      self
    end

    def response_body_from(value, kwargs, default: {})
      return value unless value.nil?
      return kwargs unless kwargs.empty?

      default
    end

    def serialized_custom_body
      @custom_body.is_a?(String) ? @custom_body : JSON.generate(@custom_body)
    end

    def quote_etag(value)
      value.start_with?('"') ? value : %("#{value}")
    end

    # Conditional freshness only applies to safe methods; a 304 answer to a
    # POST/PUT/DELETE would be wrong (RFC 9110).
    def conditional_get_request?
      return false unless @request

      %w[GET HEAD].include?(@request.rack_request.request_method)
    end

    def etag_fresh?(full_etag)
      return false unless conditional_get_request?

      if_none_match = @request.rack_request.get_header("HTTP_IF_NONE_MATCH")
      return false unless if_none_match
      return true if if_none_match.strip == "*"

      # If-None-Match uses weak comparison: the W/ prefix is ignored.
      expected = strip_weak_prefix(full_etag)
      if_none_match.split(",").any? { |candidate| strip_weak_prefix(candidate.strip) == expected }
    end

    def strip_weak_prefix(etag)
      etag.delete_prefix("W/")
    end

    def last_modified_fresh?(time)
      return false unless conditional_get_request?

      if_modified_since = @request.rack_request.get_header("HTTP_IF_MODIFIED_SINCE")
      return false unless if_modified_since

      since = begin
        Time.httpdate(if_modified_since)
      rescue ArgumentError
        nil
      end

      # Compare at whole-second granularity: HTTP dates carry no subseconds.
      !since.nil? && time.to_i <= since.to_i
    end

    def halt_not_modified
      # A 304 carries no body, so a content-type would be misleading.
      headers.delete("content-type")
      halt(code: :not_modified, body: nil)
    end

    public

    # Write directly to the Rack response body.
    # Delegates to Rack::Response#write
    #
    # @param str [String] String to write to response body
    #
    # @example
    #   response.write "Hello "
    #   response.write "World"
    def write(str)
      rack_response.write(str)
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
      rack_response.set_cookie(key, value)
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
      rack_response.delete_cookie(key, value)
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
      rack_response.redirect(target, status)
    end
  end
end
