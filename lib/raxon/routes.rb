module Raxon
  # Manages a collection of routes and provides route matching functionality.
  #
  # Routes encapsulates the storage and lookup of API routes, handling both
  # exact matches and pattern-based matching with parameter extraction.
  class Routes
    include Enumerable

    # Initialize a new Routes collection.
    def initialize
      @entries_by_path = {}
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

      if (route_data = exact_route_data(method, path))
        return route_data_with_hierarchy(route_data, method)
      end

      find_pattern_match(method, path)
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
    end

    private

    def route_entry(path)
      @entries_by_path[path] ||= {
        path: path,
        mustermann: Mustermann.new(path),
        all: nil,
        methods: {}
      }
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
    end

    def register_method_route(method, path, endpoint, entry)
      raise_collision(method, path, endpoint, entry[:methods][method]) if entry[:methods].key?(method)

      entry[:methods][method] = endpoint
    end

    def raise_collision(method, path, endpoint, existing_endpoint)
      raise Raxon::Error, "Route collision for #{method.upcase} #{path}: " \
                          "#{endpoint.route_file_path || "unknown file"} conflicts with " \
                          "#{existing_endpoint.route_file_path || "unknown file"}"
    end

    def exact_route_data(method, path)
      entry = @entries_by_path[path]
      return unless entry

      endpoint = entry[:methods][method] || entry[:all]
      route_data(entry, endpoint) if endpoint
    end

    # Build route data with the endpoint hierarchy for the given path.
    #
    # Collects all matching parent route entries and returns them sorted by depth,
    # allowing before blocks to execute in order. At each level, checks for all.rb
    # endpoints first, then method-specific endpoints.
    #
    # @param final_route_data [Hash] The route data for the most specific path
    # @param method [String] HTTP method
    # @return [Hash] Route data with endpoints array
    def route_data_with_hierarchy(final_route_data, method)
      endpoints = []

      canonical_hierarchy_entries(final_route_data[:path]).each do |entry|
        append_endpoint(endpoints, entry[:all])
        append_endpoint(endpoints, entry[:methods][method])
      end

      append_endpoint(endpoints, final_route_data[:endpoint]) if endpoints.empty?

      result = {
        endpoint: final_route_data[:endpoint],
        endpoints: endpoints
      }

      result[:params] = final_route_data[:params] if final_route_data[:params]

      result
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
      matching_route = find_pattern_candidate(method, path) || find_all_pattern_candidate(path)

      route_data_with_hierarchy(matching_route, method) if matching_route
    end

    def find_pattern_candidate(method, path)
      @entries_by_path.each_value do |entry|
        endpoint = entry[:methods][method]
        next unless endpoint

        match = entry[:mustermann].match(path)
        return route_data(entry, endpoint).merge(params: match.named_captures.transform_keys(&:to_sym)) if match
      end

      nil
    end

    def find_all_pattern_candidate(path)
      @entries_by_path.each_value do |entry|
        endpoint = entry[:all]
        next unless endpoint

        match = entry[:mustermann].match(path)
        return route_data(entry, endpoint).merge(params: match.named_captures.transform_keys(&:to_sym)) if match
      end

      nil
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
