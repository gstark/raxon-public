# frozen_string_literal: true

module Raxon
  # Wrapper around Rack::Request providing convenience methods for API handlers.
  #
  # This class wraps a Rack::Request and delegates to it for all HTTP request
  # handling while providing a clean DSL for common operations in endpoint handlers.
  #
  # @example
  #   endpoint.handler do |request, response|
  #     user_id = request.params["id"]
  #     content_type = request.content_type
  #     is_json = request.json?
  #     response.body = { user_id: user_id }
  #   end
  class Request
    attr_reader :rack_request, :endpoint, :validation_errors, :json_parse_error

    # Initialize a new Request wrapper.
    #
    # @param rack_request [Rack::Request] The underlying Rack request object
    # @param endpoint [Raxon::OpenApi::Endpoint, nil] Optional endpoint for parameter validation
    def initialize(rack_request, endpoint = nil)
      @rack_request = rack_request
      @endpoint = endpoint
      @validation_errors = nil
      @validated_params = nil
      @json_parse_error = false
    end

    # Get request parameters with validation and type coercion.
    #
    # If an endpoint with a request_schema is available, this method will:
    # 1. Parse JSON body if content-type is application/json
    # 2. Merge with path/query parameters from routing
    # 3. Validate through endpoint's request_schema (if available)
    # 4. Return validated/coerced params
    #
    # If validation fails, the raw params are returned and errors are available
    # via the validation_errors method.
    #
    # @return [Hash] The request parameters (validated if schema available)
    def params
      return @validated_params if @validated_params

      # Parse JSON body FIRST before accessing rack_request.params
      # (accessing params can consume the body stream)
      json_body = parse_json_body

      # Handle JSON parsing error
      return @validated_params if @json_parse_error

      # Assemble all parameters from different sources
      base_params = assemble_params(json_body)

      # Validate and store parameters
      validate_and_store_params(base_params)

      @validated_params
    end

    # Parse JSON body from request if content type is JSON.
    #
    # @return [Hash, nil] Parsed JSON body or nil if not JSON or empty
    #
    # @private
    def parse_json_body
      return nil unless json?

      body_content = body_string
      return nil if body_content.empty?

      begin
        JSON.parse(body_content, symbolize_names: true)
      rescue JSON::ParserError
        @json_parse_error = true
        @validated_params = {}
        nil
      end
    end

    # Assemble all request parameters from various sources.
    #
    # Merges parameters from:
    # 1. Rack query/form parameters
    # 2. JSON body (if present)
    # 3. Router path parameters (if present)
    #
    # @param json_body [Hash, nil] Parsed JSON body
    # @return [Hash] Merged parameters
    #
    # @private
    def assemble_params(json_body)
      # Start with base params from Rack (query and form params)
      base_params = @rack_request.params.symbolize_keys

      # Merge JSON body if present
      if json_body.is_a?(Hash)
        base_params = base_params.merge(json_body)
      end

      # Merge path parameters from router (if present in env)
      if @rack_request.env["router.params"]
        base_params = base_params.merge(@rack_request.env["router.params"].symbolize_keys)
      end

      base_params
    end

    # Validate assembled parameters and store the result.
    #
    # Uses the endpoint's request_schema for validation if available.
    # Sets @validated_params and @validation_errors accordingly.
    #
    # @param base_params [Hash] The parameters to validate
    # @return [void]
    #
    # @private
    def validate_and_store_params(base_params)
      if @endpoint&.request_schema
        result = @endpoint.request_schema.call(base_params)
        if result.success?
          @validated_params = result.to_h
        else
          @validation_errors = result.errors.to_h
          @validated_params = base_params
        end
      else
        @validated_params = base_params
      end
    end

    # Get the request path.
    # Delegates to Rack::Request#path
    #
    # @return [String] The request path
    def path
      @rack_request.path
    end

    # Get the full request path including query string.
    # Delegates to Rack::Request#fullpath
    #
    # @return [String] The full path with query string
    def fullpath
      @rack_request.fullpath
    end

    # Get the request method.
    # Delegates to Rack::Request#request_method
    #
    # @return [String] The HTTP method (GET, POST, etc.)
    def method
      @rack_request.request_method
    end

    # Check if request is a GET request.
    # Delegates to Rack::Request#get?
    #
    # @return [Boolean] True if GET request
    def get?
      @rack_request.get?
    end

    # Check if request is a POST request.
    # Delegates to Rack::Request#post?
    #
    # @return [Boolean] True if POST request
    def post?
      @rack_request.post?
    end

    # Check if request is a PUT request.
    # Delegates to Rack::Request#put?
    #
    # @return [Boolean] True if PUT request
    def put?
      @rack_request.put?
    end

    # Check if request is a PATCH request.
    # Delegates to Rack::Request#patch?
    #
    # @return [Boolean] True if PATCH request
    def patch?
      @rack_request.patch?
    end

    # Check if request is a DELETE request.
    # Delegates to Rack::Request#delete?
    #
    # @return [Boolean] True if DELETE request
    def delete?
      @rack_request.delete?
    end

    # Get request headers.
    # Returns HTTP_* environment variables as a hash.
    #
    # @return [Hash] The request headers
    def headers
      @rack_request.env.select { |k, _v| k.start_with?("HTTP_") }
    end

    # Get request headers as a normalized hash.
    # Converts HTTP_* environment variables to standard header names.
    #
    # For example, HTTP_AUTHORIZATION becomes "Authorization",
    # HTTP_X_CUSTOM_HEADER becomes "X-Custom-Header"
    #
    # @return [Hash] The normalized request headers
    #
    # @example
    #   request.headers_hash # => { "Authorization" => "Bearer token", "X-Custom-Header" => "value" }
    def headers_hash
      headers.transform_keys do |key|
        # Remove HTTP_ prefix and convert to proper header case
        key.sub(/^HTTP_/, "")
          .split("_")
          .map(&:capitalize)
          .join("-")
      end
    end

    # Get a specific header value.
    # Delegates to Rack::Request#get_header
    #
    # @param name [String] Header name
    # @return [String, nil] Header value
    #
    # @example
    #   request.header("HTTP_AUTHORIZATION")
    def header(name)
      @rack_request.get_header(name)
    end

    # Get the content-type header.
    # Delegates to Rack::Request#content_type
    #
    # @return [String, nil] The content type
    def content_type
      @rack_request.content_type
    end

    # Check if request has JSON content type.
    #
    # @return [Boolean] True if content type is application/json
    def json?
      content_type&.include?("application/json")
    end

    # Get the request body.
    # Delegates to Rack::Request#body
    #
    # @return [IO] The request body IO object
    def body
      @rack_request.body
    end

    # Read and return the request body as a string.
    #
    # @return [String] The request body content
    def body_string
      body.rewind if body.respond_to?(:rewind)
      content = body.respond_to?(:read) ? body.read : ""
      body.rewind if body.respond_to?(:rewind)
      content
    end

    # Parse JSON request body.
    #
    # @return [Hash, Array, nil] Parsed JSON or nil if parsing fails
    def json
      JSON.parse(body_string)
    rescue JSON::ParserError
      nil
    end

    # Get cookies.
    # Delegates to Rack::Request#cookies
    #
    # @return [Hash] The request cookies
    def cookies
      @rack_request.cookies
    end

    # Get the request scheme (http or https).
    # Delegates to Rack::Request#scheme
    #
    # @return [String] The request scheme
    def scheme
      @rack_request.scheme
    end

    # Check if request is using HTTPS.
    # Delegates to Rack::Request#ssl?
    #
    # @return [Boolean] True if HTTPS
    def ssl?
      @rack_request.ssl?
    end

    # Get the host with port.
    # Delegates to Rack::Request#host_with_port
    #
    # @return [String] The host with port
    def host_with_port
      @rack_request.host_with_port
    end

    # Get the base URL.
    # Delegates to Rack::Request#base_url
    #
    # @return [String] The base URL
    def base_url
      @rack_request.base_url
    end

    # Get the full URL.
    # Delegates to Rack::Request#url
    #
    # @return [String] The full URL
    def url
      @rack_request.url
    end

    # Get the client IP address.
    # Delegates to Rack::Request#ip
    #
    # @return [String] The client IP
    def ip
      @rack_request.ip
    end

    # Get the remote IP address.
    #
    # Attempts to determine the true client IP by checking proxy headers
    # in the following order:
    # 1. X-Forwarded-For (takes the first/leftmost IP if multiple)
    # 2. X-Real-IP
    # 3. Falls back to the standard IP from Rack
    #
    # @return [String] The remote IP address
    def remote_ip
      # Check X-Forwarded-For header (may contain multiple IPs)
      forwarded_for = header("HTTP_X_FORWARDED_FOR")
      if forwarded_for && !forwarded_for.empty?
        # Take the first IP (leftmost) as it's typically the original client
        return forwarded_for.split(",").first.strip
      end

      # Check X-Real-IP header
      real_ip = header("HTTP_X_REAL_IP")
      return real_ip.strip if real_ip && !real_ip.empty?

      # Fall back to standard IP
      ip
    end

    # Get the user agent.
    # Delegates to Rack::Request#user_agent
    #
    # @return [String, nil] The user agent string
    def user_agent
      @rack_request.user_agent
    end

    # Get the domain part of the host.
    #
    # Extracts the domain from the host, excluding subdomains and the top-level domain portion.
    # The tld_length parameter specifies how many domain levels to treat as the TLD.
    #
    # @param tld_length [Integer] Number of domain levels in the TLD (default: 1)
    # @return [String, nil] The domain portion of the host
    #
    # @example
    #   # For host "www.example.com" with tld_length=1
    #   request.domain # => "example.com"
    #
    # @example
    #   # For host "dev.www.example.co.uk" with tld_length=2
    #   request.domain(2) # => "example.co.uk"
    def domain(tld_length = 1)
      host = @rack_request.host
      return nil if host.nil? || host.empty?

      extract_domain(host, tld_length)
    end

    # Get all subdomains as a single string.
    #
    # Returns all subdomains concatenated with dots, excluding the domain and TLD.
    # The tld_length parameter specifies how many domain levels to treat as the TLD.
    #
    # @param tld_length [Integer] Number of domain levels in the TLD (default: 1)
    # @return [String] The subdomain portion (empty string if no subdomains)
    #
    # @example
    #   # For host "dev.www.example.com" with tld_length=1
    #   request.subdomain # => "dev.www"
    #
    # @example
    #   # For host "www.example.co.uk" with tld_length=2
    #   request.subdomain(2) # => "www"
    def subdomain(tld_length = 1)
      subdomains(tld_length).join(".")
    end

    # Get all subdomains as an array.
    #
    # Returns subdomains as an array of strings, excluding the domain and TLD.
    # The tld_length parameter specifies how many domain levels to treat as the TLD.
    #
    # @param tld_length [Integer] Number of domain levels in the TLD (default: 1)
    # @return [Array<String>] Array of subdomain parts
    #
    # @example
    #   # For host "dev.www.example.com" with tld_length=1
    #   request.subdomains # => ["dev", "www"]
    #
    # @example
    #   # For host "example.com" with tld_length=1
    #   request.subdomains # => []
    def subdomains(tld_length = 1)
      host = @rack_request.host
      return [] if host.nil? || host.empty?

      extract_subdomains(host, tld_length)
    end

    # Get the request environment.
    # Delegates to Rack::Request#env
    #
    # @return [Hash] The Rack environment hash
    def env
      @rack_request.env
    end

    private

    # Extract the domain portion from a host string.
    #
    # @param host [String] The host string
    # @param tld_length [Integer] Number of domain levels in the TLD
    # @return [String, nil] The domain portion
    #
    # @private
    def extract_domain(host, tld_length)
      return nil if host.include?(":")  # IP address with port
      return nil if host.match?(/\A\d+\.\d+\.\d+\.\d+\z/)  # IPv4 address
      return nil if host.match?(/\A\[.*\]\z/)  # IPv6 address

      parts = host.split(".")
      return nil if parts.length <= tld_length

      parts.last(1 + tld_length).join(".")
    end

    # Extract subdomains from a host string.
    #
    # @param host [String] The host string
    # @param tld_length [Integer] Number of domain levels in the TLD
    # @return [Array<String>] Array of subdomain parts
    #
    # @private
    def extract_subdomains(host, tld_length)
      return [] if host.include?(":")  # IP address with port
      return [] if host.match?(/\A\d+\.\d+\.\d+\.\d+\z/)  # IPv4 address
      return [] if host.match?(/\A\[.*\]\z/)  # IPv6 address

      parts = host.split(".")
      return [] if parts.length <= (1 + tld_length)

      parts[0..-(2 + tld_length)]
    end
  end
end
