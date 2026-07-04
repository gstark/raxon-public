module Raxon
  # Manages a collection of routes and provides route matching functionality.
  #
  # Routes encapsulates the storage and lookup of API routes, handling both
  # exact matches and pattern-based matching with parameter extraction.
  class Routes
    include Enumerable

    # HTTP methods a route can be served with, in the canonical order used for
    # Allow headers.
    SUPPORTED_METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

    # Initialize a new Routes collection.
    def initialize
      @entries_by_path = {}
      @dynamic_entries = []
    end

    def each(&block)
      return all.each unless block

      all.each(&block)
    end

    def size
      all.size
    end

    def empty?
      @entries_by_path.empty?
    end

    # Register a route with its endpoint data.
    #
    # @param method [String] HTTP method in uppercase, or ALL for an all.rb endpoint
    # @param path [String] URL path (e.g., "/api/v1/users/{id}")
    # @param endpoint [Endpoint] The endpoint to register
    #
    # @return [void]
    def register(method, path, endpoint)
      method = method.upcase
      entry = route_entry(path)

      if method == "ALL"
        register_all_route(path, endpoint, entry)
      else
        register_method_route(method, path, endpoint, entry)
      end
    end

    # Find a route by method and path.
    #
    # Returns route data if found, with params extracted from the path.
    # Tries exact match first, then pattern matching.
    #
    # The returned data includes all matching endpoints in the path hierarchy
    # (from parent paths to the most specific path), sorted by path depth.
    # This allows before blocks to execute in order from parent to child.
    #
    # @param method [String] HTTP method
    # @param path [String] Request path
    # @return [Hash, nil] Route data with endpoints array and params, or nil if not found
    def find(method, path)
      method = method.upcase

      if (entry = @entries_by_path[path]) && (prepared = entry[:prepared][method])
        return prepared
      end

      find_pattern_match(method, path)
    end

    # HTTP methods that can serve the given request path, in canonical order.
    #
    # Includes HEAD when a GET route exists (served by the automatic HEAD
    # fallback) and OPTIONS whenever the path exists at all (served by the
    # router's automatic OPTIONS response). Used for 405 Allow headers and
    # automatic OPTIONS responses.
    #
    # @param path [String] Request path
    # @return [Array<String>] Uppercase method names, empty if the path matches no route
    def allowed_methods(path)
      methods = matching_entries(path).flat_map { |entry| entry_methods(entry) }
      return [] if methods.empty?

      methods << "OPTIONS"
      SUPPORTED_METHODS & methods
    end

    # Get all registered routes in the legacy keyed shape.
    #
    # @return [Hash] Routes keyed by method/path
    def all
      @entries_by_path.each_with_object({}) do |(path, entry), routes|
        routes[route_key("ALL", path)] = route_data(entry, entry[:all]) if entry[:all]
        entry[:methods].each do |method, endpoint|
          routes[route_key(method, path)] = route_data(entry, endpoint)
        end
      end
    end

    # Reset all routes.
    #
    # @return [void]
    def reset
      @entries_by_path.clear
      @dynamic_entries.clear
    end

    private

    def route_entry(path)
      @entries_by_path[path] ||= begin
        mustermann = Mustermann.new(path)
        entry = {
          path: path,
          mustermann: mustermann,
          param_symbols: mustermann.names.map(&:to_sym).freeze,
          dynamic: path.include?("{"),
          all: nil,
          methods: {},
          prepared: {}
        }
        @dynamic_entries << entry if entry[:dynamic]
        entry
      end
    end

    def route_data(entry, endpoint)
      {
        endpoint: endpoint,
        mustermann: entry[:mustermann],
        entry: entry,
        path: entry[:path]
      }
    end

    def register_all_route(path, endpoint, entry)
      raise_collision("ALL", path, endpoint, entry[:all]) if entry[:all]

      entry[:all] = endpoint
      rebuild_prepared_routes
    end

    def register_method_route(method, path, endpoint, entry)
      raise_collision(method, path, endpoint, entry[:methods][method]) if entry[:methods].key?(method)

      entry[:methods][method] = endpoint
      rebuild_prepared_routes
    end

    def raise_collision(method, path, endpoint, existing_endpoint)
      raise Raxon::Error, "Route collision for #{method.upcase} #{path}: " \
                          "#{endpoint.route_file_path || "unknown file"} conflicts with " \
                          "#{existing_endpoint.route_file_path || "unknown file"}"
    end

    def rebuild_prepared_routes
      @entries_by_path.each_value do |entry|
        entry[:prepared].clear
        prepare_entry_routes(entry)
      end
    end

    def prepare_entry_routes(entry)
      SUPPORTED_METHODS.each do |method|
        endpoint = entry[:methods][method] || entry[:all]
        next unless endpoint

        entry[:prepared][method] = {
          endpoint: endpoint,
          endpoints: endpoint_hierarchy(entry[:path], method, endpoint)
        }
      end

      prepare_head_fallback(entry)
    end

    # A path with a GET route but no HEAD or all route still answers HEAD
    # requests by running the GET handler; the Router strips the body from the
    # response (marked here with head_from_get).
    def prepare_head_fallback(entry)
      return if entry[:prepared]["HEAD"]

      get_endpoint = entry[:methods]["GET"]
      return unless get_endpoint

      entry[:prepared]["HEAD"] = {
        endpoint: get_endpoint,
        endpoints: endpoint_hierarchy(entry[:path], "GET", get_endpoint),
        head_from_get: true
      }
    end

    def matching_entries(path)
      entries = []
      exact = @entries_by_path[path]
      entries << exact if exact

      @dynamic_entries.each do |entry|
        entries << entry if !entry.equal?(exact) && entry[:mustermann].match(path)
      end

      entries
    end

    def entry_methods(entry)
      return SUPPORTED_METHODS.dup if entry[:all]

      methods = entry[:methods].keys
      methods += ["HEAD"] if methods.include?("GET")
      methods
    end

    def endpoint_hierarchy(path_pattern, method, final_endpoint)
      endpoints = []

      canonical_hierarchy_entries(path_pattern).each do |entry|
        append_endpoint(endpoints, entry[:all])
        append_endpoint(endpoints, entry[:methods][method])
      end

      append_endpoint(endpoints, final_endpoint) if endpoints.empty?
      endpoints.freeze
    end

    def canonical_hierarchy_entries(path_pattern)
      canonical_path_prefixes(path_pattern).filter_map do |path_prefix|
        @entries_by_path[path_prefix]
      end
    end

    def canonical_path_prefixes(path_pattern)
      parts = path_pattern.split("/").reject(&:empty?)
      return ["/"] if parts.empty?

      ["/"] + parts.each_index.map do |index|
        "/" + parts.first(index + 1).join("/")
      end
    end

    def append_endpoint(endpoints, endpoint)
      return unless endpoint

      endpoints << endpoint unless endpoints.include?(endpoint)
    end

    # Find a route by pattern matching with parameter extraction.
    #
    # @param method [String] HTTP method
    # @param path [String] Request path
    # @return [Hash, nil] Route data with extracted params if found, nil otherwise
    def find_pattern_match(method, path)
      find_pattern_candidate(method, path) ||
        find_all_pattern_candidate(method, path) ||
        find_head_fallback_candidate(method, path)
    end

    def find_pattern_candidate(method, path)
      @dynamic_entries.each do |entry|
        endpoint = entry[:methods][method]
        next unless endpoint

        match = entry[:mustermann].match(path)
        return dynamic_route_data(entry, method, match) if match
      end

      nil
    end

    def find_all_pattern_candidate(method, path)
      @dynamic_entries.each do |entry|
        endpoint = entry[:all]
        next unless endpoint

        match = entry[:mustermann].match(path)
        return dynamic_route_data(entry, method, match) if match
      end

      nil
    end

    # HEAD requests with no explicit HEAD or all route fall back to the GET
    # route; the prepared HEAD entry carries the head_from_get marker.
    def find_head_fallback_candidate(method, path)
      return nil unless method == "HEAD"

      @dynamic_entries.each do |entry|
        next unless entry[:methods]["GET"]

        match = entry[:mustermann].match(path)
        return dynamic_route_data(entry, method, match) if match
      end

      nil
    end

    def dynamic_route_data(entry, method, match)
      params = {}
      entry[:param_symbols].each do |name|
        value = match[name]
        params[name] = value unless value.nil?
      end

      entry[:prepared][method].merge(params: params)
    end

    # Create a route key for storage and lookup.
    #
    # @param method [String] HTTP method
    # @param path [String] URL path
    # @return [Hash] Route key with method and path
    def route_key(method, path)
      {method: method.upcase, path:}
    end
  end
end
