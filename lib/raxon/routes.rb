module Raxon
  # Manages a collection of routes and provides route matching functionality.
  #
  # Routes encapsulates the storage and lookup of API routes, handling both
  # exact matches and pattern-based matching with parameter extraction.
  class Routes
    include Enumerable

    # Initialize a new Routes collection.
    def initialize
      @routes = {}
    end

    def each(&block)
      @routes.each(&block)
    end

    def size
      @routes.size
    end

    def empty?
      @routes.empty?
    end

    # Register a route with its endpoint data.
    #
    # @param method [String] HTTP method in uppercase
    # @param path [String] URL path (e.g., "/api/v1/users/{id}")
    # @param endpoint [Endpoint] The endpoint to register
    #
    # @return [void]
    def register(method, path, endpoint)
      key = route_key(method, path)
      @routes[key] = {
        endpoint: endpoint,
        mustermann: Mustermann.new(path)
      }
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
      # Try exact match first (for routes without parameters)
      exact_key = route_key(method, path)
      if @routes[exact_key]
        return route_data_with_hierarchy(@routes[exact_key], method, path)
      end

      # Then try pattern matching for dynamic routes
      find_pattern_match(method, path)
    end

    # Get all registered routes.
    #
    # @return [Hash] The internal routes hash
    def all
      @routes
    end

    # Reset all routes.
    #
    # @return [void]
    def reset
      @routes.clear
    end

    private

    # Build route data with the endpoint hierarchy for the given path.
    #
    # Collects all matching parent paths (those that are prefixes of the request path)
    # and returns them sorted by depth, allowing before blocks to execute in order.
    # At each level, checks for "all.rb" endpoints first, then method-specific endpoints.
    #
    # @param final_route_data [Hash] The route data for the most specific path
    # @param method [String] HTTP method
    # @param path [String] Request path
    # @return [Hash] Route data with endpoints array
    def route_data_with_hierarchy(final_route_data, method, path)
      endpoints = []
      path_parts = path.split("/").reject(&:empty?)

      # Collect all matching parent paths
      # At each level, check for all.rb routes first to ensure they execute before method-specific routes
      (1..path_parts.length).each do |i|
        parent_path = "/" + path_parts[0...i].join("/")

        # Check each actual HTTP method to find all.rb routes at this level
        # We need to check all methods because all.rb registers under each method
        RouteLoader::ACTUAL_HTTP_METHODS.each do |all_method|
          all_key = route_key(all_method.upcase, parent_path)
          if @routes[all_key] && @routes[all_key][:endpoint].route_file_path&.end_with?("all.rb")
            # Only add if not already added (all.rb endpoints are registered for each method)
            unless endpoints.include?(@routes[all_key][:endpoint])
              endpoints << @routes[all_key][:endpoint]
            end
            break # Found the all.rb for this level, no need to check other methods
          end
        end

        # Then check for method-specific route at this level
        parent_key = route_key(method, parent_path)
        if @routes[parent_key] && !@routes[parent_key][:endpoint].route_file_path&.end_with?("all.rb")
          endpoints << @routes[parent_key][:endpoint]
        end
      end

      # If no parents found, use the final endpoint
      endpoints << final_route_data[:endpoint] if endpoints.empty?

      result = {
        endpoint: final_route_data[:endpoint],
        endpoints: endpoints
      }

      # Preserve params if they exist in the final route data
      result[:params] = final_route_data[:params] if final_route_data[:params]

      result
    end

    # Find a route by pattern matching with parameter extraction.
    #
    # @param method [String] HTTP method
    # @param path [String] Request path
    # @return [Hash, nil] Route data with extracted params if found, nil otherwise
    def find_pattern_match(method, path)
      method_upcase = method.upcase
      matching_route = nil

      @routes.each do |route_key, route_data|
        # Fast skip if the method does not match
        next if route_key[:method] != method_upcase

        match = route_data[:mustermann].match(path)

        # If there is a match, take the named captures,
        # transforming the keys into symbols and merge
        # that hash into the existing route data.
        if match
          matching_route = route_data.merge(params: match.named_captures.transform_keys(&:to_sym))
          break
        end
      end

      # Build hierarchy if we found a match
      if matching_route
        route_data_with_hierarchy(matching_route, method, path)
      end
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
