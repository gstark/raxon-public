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

      # Which options are meaningful for each scheme type. Setting an option that
      # does not belong to the type (e.g. flows on an apiKey scheme) is rejected,
      # both because it produces an invalid document and because it is usually a
      # mistake.
      FIELDS_BY_TYPE = {
        "apiKey" => %i[description name in],
        "http" => %i[description scheme bearer_format],
        "oauth2" => %i[description flows],
        "openIdConnect" => %i[description open_id_connect_url]
      }.freeze

      # The OAuth2 flow names and the fields each flow may contain, per the
      # OpenAPI spec. The generated document is public, so flows are validated
      # against this allowlist — anything else (a client_secret, say) is refused
      # rather than emitted. Note "password" is a legitimate *flow name*, not a
      # credential field, so the structural allowlist keeps it while still
      # rejecting secret-bearing fields inside any flow.
      OAUTH2_FLOWS = %w[authorizationCode implicit password clientCredentials].freeze
      OAUTH2_FLOW_FIELDS = %w[authorizationUrl tokenUrl refreshUrl scopes].freeze

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

        validate_options_for_type!(options)
        validate_flows!(options[:flows]) if options.key?(:flows)

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

      private

      # Reject options that do not apply to this scheme's type.
      #
      # @raise [ArgumentError]
      def validate_options_for_type!(options)
        allowed = FIELDS_BY_TYPE.fetch(@type)
        invalid = options.keys - allowed
        return if invalid.empty?

        raise ArgumentError,
          "Option(s) #{invalid.join(", ")} are not valid for a #{@type} security scheme " \
          "(allowed: #{allowed.join(", ")})."
      end

      # Validate an OAuth2 flows object against the OpenAPI structure. The
      # generated document is public, so only the standard flow names and fields
      # are permitted — a secret-bearing key such as client_secret is refused
      # rather than emitted.
      #
      # @raise [ArgumentError]
      def validate_flows!(flows)
        raise ArgumentError, "flows must be a Hash of OAuth2 flow definitions." unless flows.is_a?(Hash)

        flows.each do |flow_name, flow|
          unless OAUTH2_FLOWS.include?(flow_name.to_s)
            raise ArgumentError, "Unknown OAuth2 flow #{flow_name.inspect} (allowed: #{OAUTH2_FLOWS.join(", ")})."
          end

          raise ArgumentError, "The OAuth2 #{flow_name} flow must be a Hash." unless flow.is_a?(Hash)

          extra = flow.keys.map(&:to_s) - OAUTH2_FLOW_FIELDS
          next if extra.empty?

          raise ArgumentError,
            "Invalid field(s) in the OAuth2 #{flow_name} flow: #{extra.join(", ")} " \
            "(allowed: #{OAUTH2_FLOW_FIELDS.join(", ")}). The generated document is public — " \
            "never put secrets in flows; keep them in the authenticator block or a secret store."
        end
      end
    end
  end
end
