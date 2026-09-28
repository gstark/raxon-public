# frozen_string_literal: true

module Raxon
  # Decides which forwarding headers a request may use, from
  # +config.trusted_proxies+, and checks the host against +config.allowed_hosts+.
  #
  # A client can send X-Forwarded-Host or X-Forwarded-Proto itself. Rack reads
  # them unconditionally, so without this a client could set base_url and
  # ssl?. Here they count only when the connection peer (REMOTE_ADDR) is a
  # trusted proxy.
  module TrustedProxies
    # The env keys Rack reads to rebuild the scheme, host, and port.
    FORWARDED_URL_HEADERS = %w[
      HTTP_FORWARDED
      HTTP_X_FORWARDED_HOST
      HTTP_X_FORWARDED_PORT
      HTTP_X_FORWARDED_PROTO
      HTTP_X_FORWARDED_SCHEME
      HTTP_X_FORWARDED_SSL
    ].freeze

    # Anchored copies of the Regexp entries in +config.allowed_hosts+, keyed by
    # the configured Regexp, so a request does not compile a new one.
    ANCHORED_HOST_PATTERNS = Hash.new do |cache, entry|
      cache[entry] = Regexp.new("\\A(?:#{entry.source})\\z", entry.options)
    end

    module_function

    # The configured trusted proxies as IPAddr matchers. Malformed entries are
    # dropped so a bad config value can never widen trust.
    #
    # @return [Array<IPAddr>]
    def matchers
      Array(Raxon.configuration.trusted_proxies).filter_map do |proxy|
        proxy.is_a?(IPAddr) ? proxy : IPAddr.new(proxy.to_s)
      rescue IPAddr::Error
        nil
      end
    end

    # Whether +address+ parses as an IP inside a trusted proxy range. An
    # unparseable address is not trusted.
    #
    # @param address [String, nil]
    # @param matchers [Array<IPAddr>]
    # @return [Boolean]
    def trusted?(address, matchers = self.matchers)
      return false if address.nil? || matchers.empty?

      ip = IPAddr.new(address)
      matchers.any? { |matcher| matcher.include?(ip) }
    rescue IPAddr::Error
      false
    end

    # A Rack::Request to read the scheme, host, and port from. It is
    # +rack_request+ itself when the peer is a trusted proxy or no forwarding
    # header is present. Otherwise it is a request over a copy of the env
    # without the forwarding headers.
    #
    # @param rack_request [Rack::Request]
    # @return [Rack::Request]
    def url_request(rack_request)
      env = rack_request.env
      return rack_request unless FORWARDED_URL_HEADERS.any? { |key| env.key?(key) }
      return rack_request if trusted?(env["REMOTE_ADDR"])

      Rack::Request.new(env.except(*FORWARDED_URL_HEADERS))
    end

    # Whether the request's host is in +config.allowed_hosts+. Always true
    # when the list is nil.
    #
    # A String entry matches the host exactly, ignoring case. A String that
    # starts with "." matches that domain and every subdomain. A Regexp must
    # match the whole host.
    #
    # @param rack_request [Rack::Request]
    # @return [Boolean]
    def host_allowed?(rack_request)
      allowed = Raxon.configuration.allowed_hosts
      return true if allowed.nil?

      host = url_request(rack_request).host.to_s.downcase
      Array(allowed).any? { |entry| host_matches?(entry, host) }
    end

    # @param entry [String, Regexp]
    # @param host [String]
    # @return [Boolean]
    def host_matches?(entry, host)
      case entry
      when Regexp
        ANCHORED_HOST_PATTERNS[entry].match?(host)
      else
        pattern = entry.to_s.downcase
        if pattern.start_with?(".")
          host == pattern.delete_prefix(".") || host.end_with?(pattern)
        else
          host == pattern
        end
      end
    end
  end
end
