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
      @path_params = nil
      @query_params = nil
      @body_params = nil
      @form_params = nil
      @json_parse_error = false
      @resolver = nil
      @metadata = {}
      @context = nil
      @endpoint_context_endpoint = nil
      @endpoint_context = nil
      @endpoint_contexts = nil
    end

    # Get or create a context instance for an endpoint.
    #
    # Each endpoint's blocks (before, handler, after, metadata) execute in a
    # context instance that provides access to methods defined in the route file.
    # This method ensures the same instance is used for all blocks of a given
    # endpoint during a single request, allowing instance variables to be shared.
    #
    # @param endpoint [Raxon::OpenApi::Endpoint] The endpoint to get context for
    # @return [Object, nil] The context instance, or nil if endpoint has no route context
    def endpoint_context(endpoint)
      if @endpoint_contexts
        @endpoint_contexts[endpoint] ||= endpoint.create_context_instance
      elsif @endpoint_context_endpoint.nil? || @endpoint_context_endpoint.equal?(endpoint)
        @endpoint_context_endpoint = endpoint
        @endpoint_context ||= endpoint.create_context_instance
      else
        @endpoint_contexts = {
          @endpoint_context_endpoint => @endpoint_context,
          endpoint => endpoint.create_context_instance
        }
        @endpoint_contexts[endpoint]
      end
    end

    # Get request-scoped application context.
    #
    # Lazily wraps the metadata hash so simple handlers that never access
    # request.context avoid allocating a RequestContext object.
    #
    # @return [RequestContext]
    def context
      @context ||= RequestContext.new(@metadata)
    end

    # Backing hash for the legacy metadata handler argument.
    #
    # @return [Hash]
    def metadata
      @metadata
    end

    # Get path parameters extracted by the router from dynamic route segments.
    #
    # @return [Hash] Path parameters with symbol keys
    def path_params
      @path_params ||= begin
        params = @rack_request.env["router.params"]
        params ? symbolize_params(params) : {}
      end
    end

    # Get query string parameters only.
    #
    # @return [Hash] Query parameters with symbol keys
    def query_params
      @query_params ||= @rack_request.GET.symbolize_keys
    end

    # Get JSON request body parameters only.
    #
    # Returns an empty hash for non-JSON requests, empty bodies, JSON arrays,
    # and invalid JSON. Invalid JSON sets #json_parse_error to true, matching
    # #params behavior.
    #
    # @return [Hash] JSON body object parameters with symbol keys
    def body_params
      return @body_params if @body_params

      parsed_body = parse_json_body
      @body_params = parsed_body.is_a?(Hash) ? parsed_body : {}
    end

    # Get form request body parameters only.
    #
    # JSON requests intentionally return an empty hash. For URL-encoded or
    # multipart form requests, Rack::Request#POST provides body parameters
    # without query string parameters.
    #
    # @return [Hash] Form parameters with symbol keys
    def form_params
      return @form_params if @form_params

      @form_params = if json?
        {}
      else
        post_params = @rack_request.POST.symbolize_keys
        if post_params.empty? && form_content_type?
          @rack_request.params.symbolize_keys.except(*query_params.keys)
        else
          post_params
        end
      end
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

      # Gate: a bare GET with nothing to resolve short-circuits to path params
      # without materializing any sources (see CONTEXT.md "Param resolution").
      if simple_get_without_validation?
        return @validated_params = path_params
      end

      result = resolver.resolve(collect_sources)
      @validation_errors = result.errors
      @validated_params = result.params
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
        nil
      end
    end

    # Whether this request can skip param resolution entirely.
    #
    # A bare GET/HEAD against an endpoint with no request schema or body, no
    # query string, and no body has nothing to resolve, so #params can return
    # path params directly without materializing any sources.
    #
    # @return [Boolean]
    #
    # @private
    def simple_get_without_validation?
      return false unless @endpoint && @endpoint.request_schema.nil? && @endpoint.request_body.nil?
      return false unless @rack_request.get? || @rack_request.head?
      return false unless @rack_request.query_string.empty?

      content_length = @rack_request.get_header("CONTENT_LENGTH")
      content_length.nil? || content_length == "" || content_length == "0"
    end

    # The param resolver for this request's endpoint. Depends only on the two
    # spec artifacts it needs, not on the endpoint as a whole.
    #
    # @return [Raxon::ParamResolver]
    #
    # @private
    def resolver
      @resolver ||= ParamResolver.new(
        parameters: @endpoint ? @endpoint.parameters.parameters : [],
        schema: @endpoint&.request_schema,
        request_body: @endpoint&.request_body
      )
    end

    # Materialize the six request sources for the resolver.
    #
    # JSON is parsed before form params are read, because reading the form body
    # consumes the Rack stream (the body-stream ordering constraint).
    #
    # @return [Raxon::ParamResolver::Sources]
    #
    # @private
    def collect_sources
      json = body_params
      form = form_params

      ParamResolver::Sources.new(
        query: query_params,
        form: form,
        json: json,
        path: path_params,
        headers: headers,
        cookies: cookies,
        json_parse_error: @json_parse_error
      )
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

    # Determine whether the request content type is a form submission.
    #
    # @return [Boolean] true for URL-encoded or multipart form requests
    #
    # @private
    def symbolize_params(params)
      params.each_key do |key|
        return params.symbolize_keys unless key.is_a?(Symbol)
      end

      params
    end

    def form_content_type?
      content_type&.include?("application/x-www-form-urlencoded") || content_type&.include?("multipart/form-data")
    end

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
