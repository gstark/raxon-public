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

    # Whether a validation failure was a content rejection (422) rather than a
    # malformed request (400). Only meaningful when validation_errors is set.
    #
    # @return [Boolean]
    def validation_unprocessable?
      @validation_unprocessable
    end

    # Initialize a new Request wrapper.
    #
    # @param rack_request [Rack::Request] The underlying Rack request object
    # @param endpoint [Raxon::OpenApi::Endpoint, nil] Optional endpoint for parameter validation
    def initialize(rack_request, endpoint = nil)
      @rack_request = rack_request
      @endpoint = endpoint
      @validation_errors = nil
      @validation_unprocessable = false
      @validated_params = nil
      @path_params = nil
      @query_params = nil
      @body_params = nil
      @form_params = nil
      @json_parse_error = false
      @parsed_json_body = nil
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
    attr_reader :metadata

    # Handed to the resolver in place of the form and JSON sources when the
    # request has no body. Frozen and shared: the resolver only reads and merges
    # its sources, and a fresh empty hash per request is the allocation this
    # avoids.
    EMPTY_SOURCE = {}.freeze

    # Media types whose body Rack parses into form params.
    FORM_MEDIA_TYPES = ["application/x-www-form-urlencoded", "multipart/form-data"].freeze

    # Whether the request provably carries no body, so the form and JSON sources
    # are empty without reading anything.
    #
    # Reading them is not free: Rack::Request#POST parses the input, and both
    # sources consult the content type. A GET without a body pays that on every
    # request that resolves params, to learn that there is nothing there.
    #
    # Conservative on every axis, because the cost of being wrong is a silently
    # ignored body. A declared content type means the request is describing a
    # body, whatever the framing says, so it is read as before. A
    # Transfer-Encoding header means the length is framed some other way and is
    # unknown here. Only a request that declares no content type and either no
    # length or a length of zero is treated as empty.
    #
    # @return [Boolean]
    #
    # @private
    def bodyless?
      return false if @rack_request.content_type
      return false if @rack_request.get_header("HTTP_TRANSFER_ENCODING")

      content_length = @rack_request.get_header("CONTENT_LENGTH")
      content_length.nil? || content_length.empty? || content_length == "0"
    end

    # Get path parameters extracted by the router from dynamic route segments.
    #
    # The router matches the raw request path, so each value arrives as the
    # client encoded it. Values are percent-decoded once here: /users/a%20b
    # gives "a b". A "+" stays a "+", since only a query string uses it for a
    # space.
    #
    # @return [Hash] Path parameters with symbol keys and decoded values
    # @raise [Raxon::InvalidPathParameter] when a value decodes to invalid UTF-8
    def path_params
      @path_params ||= begin
        params = @rack_request.env["router.params"]
        params ? decode_path_params(symbolize_params(params)) : {}
      end
    end

    # Get query string parameters only.
    #
    # @return [Hash] Query parameters with symbol keys
    def query_params
      @query_params ||= @rack_request.GET.transform_keys(&:to_sym)
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

      @parsed_json_body = parse_json_body
      @body_params = @parsed_json_body.is_a?(Hash) ? @parsed_json_body : {}
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
        post_params = @rack_request.POST.transform_keys(&:to_sym)
        if post_params.empty? && form_content_type?
          @rack_request.params.transform_keys(&:to_sym).except(*query_params.keys)
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
      @validation_unprocessable = result.unprocessable
      @validated_params = result.params
    end

    # The params if #params already ran, or nil. Reading this never parses
    # the body.
    #
    # @return [Hash, nil]
    #
    # @private
    def resolved_params
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
        parsed = JSON.parse(body_content, symbolize_names: true)
      rescue JSON::ParserError
        @json_parse_error = true
        return nil
      end

      # JSON has no Infinity, but a number too large for a Float, such as
      # 1e400, parses to one. It passes a float check and makes an integer
      # coercion raise FloatDomainError, so treat it as unparseable.
      if non_finite?(parsed)
        @json_parse_error = true
        return nil
      end

      parsed
    end

    # Whether this request can skip param resolution entirely.
    #
    # A bare GET/HEAD with no query string and no body has nothing to resolve
    # when its endpoint declares no request schema, or declares only plain
    # string path parameters. The router already matched those values, and
    # resolution would return exactly the path params. So #params returns
    # them directly, without materializing any sources or running dry-schema.
    #
    # @return [Boolean]
    #
    # @private
    def simple_get_without_validation?
      # Asks whether a schema is declared rather than for the schema itself, so
      # the fast path never compiles one.
      return false unless @endpoint && @endpoint.request_body.nil?
      return false unless !@endpoint.request_schema? || @endpoint.path_params_only?
      return false unless @rack_request.get? || @rack_request.head?
      return false unless @rack_request.query_string.empty?

      content_length = @rack_request.get_header("CONTENT_LENGTH")
      content_length.nil? || content_length == "" || content_length == "0"
    end

    # The param resolver for a request that matched no endpoint. There is
    # nothing declared to filter by, so it keeps every key.
    UNMATCHED_RESOLVER = ParamResolver.new(keep_undeclared: true)

    # The param resolver for this request's endpoint. The endpoint builds it
    # once and every request shares it.
    #
    # @return [Raxon::ParamResolver]
    #
    # @private
    def resolver
      @endpoint ? @endpoint.param_resolver : UNMATCHED_RESOLVER
    end

    # Materialize the request sources for the resolver.
    #
    # JSON is parsed before form params are read, because reading the form body
    # consumes the Rack stream (the body-stream ordering constraint).
    #
    # Headers and cookies are passed as thunks rather than values: they are read
    # only for parameters declared `in: :header` or `in: :cookie`, which most
    # endpoints have none of, and #headers allocates a hash of every HTTP_* env
    # key. The other four feed the lenient merge on every request, so deferring
    # them would only trade a hash for a Proc.
    #
    # @return [Raxon::ParamResolver::Sources]
    #
    # @private
    def collect_sources
      if bodyless?
        json = EMPTY_SOURCE
        form = EMPTY_SOURCE
        body_present = false
      else
        json = body_params
        form = form_params
        body_present = json? ? !@parsed_json_body.nil? : !form.empty?
        # A top-level array has no keys, so it goes under :body, where an
        # array request body's schema looks for it.
        json = {body: @parsed_json_body} if @parsed_json_body.is_a?(Array)
      end

      ParamResolver::Sources.new(
        query: query_params,
        form: form,
        json: json,
        path: path_params,
        deferred: self,
        json_parse_error: @json_parse_error,
        body_present: body_present
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
    # Matches the media type exactly, ignoring parameters such as charset:
    # application/json, or a structured syntax suffix such as
    # application/vnd.api+json. A substring match would accept
    # "text/plain; application/json", which a browser sends cross-site
    # without a CORS preflight.
    #
    # @return [Boolean] True if the media type is JSON
    def json?
      type = @rack_request.media_type
      return false unless type

      type == "application/json" || (type.start_with?("application/") && type.end_with?("+json"))
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
    #
    # Forwarding headers (X-Forwarded-Proto and the like) count only when the
    # connection peer is one of +config.trusted_proxies+. See
    # {Raxon::TrustedProxies}. The same rule applies to every URL method below.
    #
    # @return [String] The request scheme
    def scheme
      url_request.scheme
    end

    # Check if request is using HTTPS.
    #
    # @return [Boolean] True if HTTPS
    def ssl?
      url_request.ssl?
    end

    # Get the host, without the port.
    #
    # @return [String] The host
    def host
      url_request.host
    end

    # Get the host with port.
    #
    # @return [String] The host with port
    def host_with_port
      url_request.host_with_port
    end

    # Get the base URL.
    #
    # @return [String] The base URL
    def base_url
      url_request.base_url
    end

    # Get the full URL.
    #
    # @return [String] The full URL
    def url
      url_request.url
    end

    # Get the client IP address.
    # Delegates to Rack::Request#ip
    #
    # @return [String] The client IP
    def ip
      @rack_request.ip
    end

    # Get the client IP address, honoring X-Forwarded-For only for trusted proxies.
    #
    # SECURITY: X-Forwarded-For is set by clients and is trivially forgeable, so
    # the leftmost entry must never be trusted blindly — a client can prepend a
    # fake address, and a proxy that *appends* leaves the forgery in place. This
    # instead walks the forwarding chain (the X-Forwarded-For entries followed by
    # the actual connection peer, REMOTE_ADDR) from right to left, discarding
    # every hop that is one of +config.trusted_proxies+, and returns the first
    # address that is not. With no trusted proxies configured (the default), it
    # returns REMOTE_ADDR, which cannot be spoofed by a request header.
    #
    # Note that Rack's own #ip also parses X-Forwarded-For, so it is NOT a safe
    # substitute here.
    #
    # @return [String] The client IP address
    #
    # @example
    #   Raxon.configure { |c| c.trusted_proxies = ["10.0.0.0/8"] }
    #   request.remote_ip # => the first non-10.x address from the right of XFF
    def remote_ip
      remote_addr = @rack_request.get_header("REMOTE_ADDR")
      matchers = TrustedProxies.matchers
      return remote_addr || ip if matchers.empty?

      forwarded = header("HTTP_X_FORWARDED_FOR").to_s.split(",").map(&:strip).reject(&:empty?)
      chain = forwarded + [remote_addr].compact

      client = chain.rfind { |address| !TrustedProxies.trusted?(address, matchers) }
      client || remote_addr || ip
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
      host = self.host
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
      host = self.host
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

    # The Rack::Request that URL methods read, with untrusted forwarding
    # headers removed.
    #
    # @return [Rack::Request]
    def url_request
      @url_request ||= TrustedProxies.url_request(@rack_request)
    end

    # Whether a parsed JSON value holds a Float that is not finite.
    #
    # @param value [Object]
    # @return [Boolean]
    def non_finite?(value)
      case value
      when Float then !value.finite?
      when Hash then value.each_value.any? { |item| non_finite?(item) }
      when Array then value.any? { |item| non_finite?(item) }
      else false
      end
    end

    # Percent-decode each path parameter value.
    #
    # @param params [Hash] Path parameters as the router matched them
    # @return [Hash] The same keys with decoded values
    # @raise [Raxon::InvalidPathParameter] when a value decodes to invalid UTF-8
    #
    # @private
    def decode_path_params(params)
      params.transform_values do |value|
        # PATH_INFO is binary; the decoded bytes are meant as UTF-8.
        decoded = Rack::Utils.unescape_path(value).force_encoding(Encoding::UTF_8)
        raise InvalidPathParameter, "Path parameter is not valid UTF-8" unless decoded.valid_encoding?

        decoded
      end
    end

    # Determine whether the request content type is a form submission.
    #
    # @return [Boolean] true for URL-encoded or multipart form requests
    #
    # @private
    def symbolize_params(params)
      params.each_key do |key|
        return params.transform_keys(&:to_sym) unless key.is_a?(Symbol)
      end

      params
    end

    def form_content_type?
      FORM_MEDIA_TYPES.include?(@rack_request.media_type)
    end

    # Extract the domain portion from a host string.
    #
    # @param host [String] The host string
    # @param tld_length [Integer] Number of domain levels in the TLD
    # @return [String, nil] The domain portion
    #
    # @private
    def extract_domain(host, tld_length)
      return nil if host.include?(":")  # IP address with port, or IPv6
      return nil if host.match?(/\A\d+\.\d+\.\d+\.\d+\z/)  # IPv4 address

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
      return [] if host.include?(":")  # IP address with port, or IPv6
      return [] if host.match?(/\A\d+\.\d+\.\d+\.\d+\z/)  # IPv4 address

      parts = host.split(".")
      return [] if parts.length <= (1 + tld_length)

      parts[0..-(2 + tld_length)]
    end
  end
end
