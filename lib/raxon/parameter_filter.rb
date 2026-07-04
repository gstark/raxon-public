# frozen_string_literal: true

module Raxon
  # Redacts sensitive values from hashes before they leave the application in
  # instrumentation/APM payloads or logs.
  #
  # A key matches when its name contains (case-insensitively) any of the
  # configured filter terms. Matching values are replaced with "[FILTERED]".
  # Nested hashes and arrays are filtered recursively so secrets nested inside
  # request bodies are not leaked.
  #
  # @example
  #   filter = Raxon::ParameterFilter.new([:password, :token])
  #   filter.filter(user: "amy", password: "hunter2")
  #   # => { user: "amy", password: "[FILTERED]" }
  class ParameterFilter
    FILTERED = "[FILTERED]"

    # HTTP header names (normalized, without the HTTP_ prefix) that always carry
    # credentials and are redacted regardless of the configured param filters.
    SENSITIVE_HEADERS = %w[AUTHORIZATION COOKIE X_API_KEY X_AUTH_TOKEN PROXY_AUTHORIZATION].freeze

    # @param filters [Array<String, Symbol, Regexp>] Name fragments (or regexps)
    #   whose matching values should be redacted.
    def initialize(filters)
      @string_filters = filters.reject { |f| f.is_a?(Regexp) }.map { |f| f.to_s.downcase }
      @regexp_filters = filters.select { |f| f.is_a?(Regexp) }
    end

    # Return a copy of +data+ with sensitive values redacted.
    #
    # @param data [Hash, Array, Object]
    # @return [Hash, Array, Object]
    def filter(data)
      case data
      when Hash
        data.each_with_object({}) do |(key, value), result|
          result[key] = filter_key?(key) ? FILTERED : filter(value)
        end
      when Array
        data.map { |element| filter(element) }
      else
        data
      end
    end

    # Filter a hash of raw Rack HTTP_* headers, redacting known credential
    # headers plus any header matching the configured filters.
    #
    # @param headers [Hash] HTTP_* env slice
    # @return [Hash]
    def filter_headers(headers)
      headers.each_with_object({}) do |(key, value), result|
        normalized = key.to_s.sub(/\AHTTP_/, "").upcase
        result[key] = (SENSITIVE_HEADERS.include?(normalized) || filter_key?(key)) ? FILTERED : value
      end
    end

    private

    # @param key [String, Symbol]
    # @return [Boolean]
    def filter_key?(key)
      name = key.to_s.downcase
      @string_filters.any? { |fragment| name.include?(fragment) } ||
        @regexp_filters.any? { |pattern| pattern.match?(key.to_s) }
    end
  end
end
