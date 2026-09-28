# frozen_string_literal: true

module Raxon
  # Rack::CommonLogger that redacts secrets in the query string.
  #
  # CommonLogger writes the raw query string, so ?token=abc puts the token in
  # the log. This writes the query string with each value whose key matches
  # +config.filter_parameters+ replaced by [FILTERED]. The other pairs stay as
  # the client sent them.
  class RequestLogger < Rack::CommonLogger
    # @param query [String] A raw query string
    # @param filter [Raxon::ParameterFilter]
    # @return [String] The query string with filtered values redacted
    def self.filter_query(query, filter = Raxon.configuration.parameter_filter)
      query.split(/([&;])/).map do |part|
        key, separator, _value = part.partition("=")
        next part if separator.empty?

        name = begin
          Rack::Utils.unescape(key)
        rescue ArgumentError
          key
        end
        filter.filter_key?(name) ? "#{key}=#{Raxon::ParameterFilter::FILTERED}" : part
      end.join
    end

    private

    def log(env, status, response_headers, began_at)
      query = env[Rack::QUERY_STRING]
      return super if query.nil? || query.empty?

      super(env.merge(Rack::QUERY_STRING => self.class.filter_query(query)), status, response_headers, began_at)
    end
  end
end
