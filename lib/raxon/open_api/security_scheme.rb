# frozen_string_literal: true

module Raxon
  module OpenApi
    # A reusable OpenAPI security scheme definition.
    #
    # Security schemes are declared once on the specification and referenced by
    # name from endpoints via +endpoint.security+. They are emitted under
    # +components.securitySchemes+ in the generated document.
    #
    # A scheme may also carry an authenticator block. When an endpoint declares
    # a security requirement whose schemes all have authenticators, the router
    # enforces it: the blocks run before the endpoint's before blocks and a
    # falsy return produces a 401 response. Schemes without a block are
    # documentation-only.
    #
    # @example API key in a header, enforced at runtime
    #   Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) do |request, metadata|
    #     metadata[:current_user] = User.find_by_api_key(request.header("X-API-Key"))
    #   end
    #
    # @example Documentation-only bearer scheme
    #   Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer, bearer_format: "JWT")
    class SecurityScheme
      # Accepted scheme types, normalized to their OpenAPI spelling.
      TYPES = {
        "apiKey" => "apiKey",
        "api_key" => "apiKey",
        "http" => "http",
        "oauth2" => "oauth2",
        "openIdConnect" => "openIdConnect",
        "open_id_connect" => "openIdConnect"
      }.freeze

      ALLOWED_OPTIONS = %i[description name in scheme bearer_format flows open_id_connect_url].freeze

      attr_reader :name, :type, :authenticator

      # @param name [Symbol, String] Registry name used by endpoint.security references
      # @param type [Symbol, String] One of :apiKey, :http, :oauth2, :openIdConnect
      # @param options [Hash] OpenAPI scheme fields: description, name (e.g. the
      #   header name for apiKey), in, scheme, bearer_format, flows, open_id_connect_url
      # @param authenticator [Proc] Optional block enforcing the scheme at runtime;
      #   receives (request, metadata, scopes) and authenticates by returning truthy
      def initialize(name, type:, **options, &authenticator)
        unknown = options.keys - ALLOWED_OPTIONS
        raise ArgumentError, "Unknown security scheme options: #{unknown.join(", ")}" if unknown.any?

        @name = name.to_sym
        @type = TYPES[type.to_s] || raise(ArgumentError, "Unknown security scheme type: #{type.inspect} (expected one of :apiKey, :http, :oauth2, :openIdConnect)")
        @options = options
        @authenticator = authenticator
      end

      # The OpenAPI security scheme object for components.securitySchemes.
      #
      # @return [Hash]
      def to_openapi
        definition = {type: @type}
        definition[:description] = @options[:description] if @options[:description]
        definition[:name] = @options[:name].to_s if @options[:name]
        definition[:in] = @options[:in].to_s if @options[:in]
        definition[:scheme] = @options[:scheme].to_s if @options[:scheme]
        definition[:bearerFormat] = @options[:bearer_format] if @options[:bearer_format]
        definition[:flows] = @options[:flows] if @options[:flows]
        definition[:openIdConnectUrl] = @options[:open_id_connect_url] if @options[:open_id_connect_url]
        definition
      end
    end
  end
end
