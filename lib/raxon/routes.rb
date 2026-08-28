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

    # Maps an already-uppercase method name to a frozen instance of itself.
    # String#upcase allocates unconditionally, even when it changes nothing, and
    # #find normalizes the method on every request. Rack hands us the method
    # uppercase, so the lookup hits and the allocation disappears; anything else
    # falls back to #upcase.
    UPCASED_METHODS = (SUPPORTED_METHODS + %w[TRACE CONNECT]).to_h { |name| [name, name] }.freeze

    # A template segment that is exactly one parameter, so the trie can index it
    # as "anything here". A segment that merely contains a parameter —
    # `{name}.json` — cannot be indexed by equality and is handled separately.
    PURE_PARAM_SEGMENT = /\A\{[^{}\/]+\}\z/

    # Path parameter names, in order, straight from the template string. Scanning
    # a path with this produces the same list as Mustermann#names, which is what
    # lets an entry record its parameters without compiling its pattern. See
    # {#pattern_for}.
    PARAM_SEGMENT_NAME = /\{([^{}\/]+)\}/

    # Dynamic-route count below which the index is not worth consulting. Around
    # this many patterns, asking Mustermann each in turn costs about what
    # splitting the path and collecting candidates costs; measured at 8 routes,
    # narrowing was ~1.2us slower, and by 30 dynamic routes it is several times
    # faster.
    LINEAR_SCAN_LIMIT = 8

    # Initialize a new Routes collection.
    def initialize
      @entries_by_path = {}
      @dynamic_entries = []
      @dynamic_root = new_index_node
      @unindexable_entries = []
      @prepared_dirty = false
      @prepared_mutex = Mutex.new
    end

    # Build the prepared-route table now, if registrations have invalidated it.
    #
    # Callers that finish a batch of registrations (RouteLoader.load!) call this
    # so boot pays exactly one rebuild and no request pays any of it. Readers
    # call it too, so forgetting it costs latency on one request, not
    # correctness.
    #
    # @return [void]
    def prepare!
      ensure_prepared_routes
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
      ensure_prepared_routes
      method = UPCASED_METHODS[method] || method.upcase

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
      ensure_prepared_routes
      methods = matching_entries(path).flat_map { |entry| entry_methods(entry) }
      return [] if methods.empty?

      methods << "OPTIONS"
      SUPPORTED_METHODS & methods
    end

    # Get all registered routes in the legacy keyed shape.
    #
    # @return [Hash] Routes keyed by method/path
    def all
      ensure_prepared_routes
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
      @dynamic_root = new_index_node
      @unindexable_entries.clear
    end

    private

    def route_entry(path)
      @entries_by_path[path] ||= begin
        entry = {
          path: path,
          mustermann: nil,
          param_symbols: path.scan(PARAM_SEGMENT_NAME).map { |(name)| name.to_sym }.freeze,
          dynamic: path.include?("{"),
          all: nil,
          methods: {},
          prepared: {}
        }
        if entry[:dynamic]
          entry[:order] = @dynamic_entries.length
          @dynamic_entries << entry
          index_dynamic_entry(entry)
        end
        entry
      end
    end

    # The compiled pattern for an entry, built on first use.
    #
    # A static path is answered by an exact lookup in @entries_by_path and never
    # consults its pattern, and a dynamic one is only asked once a request
    # actually reaches the candidate scan. Building all of them at registration
    # therefore front-loads work most of which is never needed: on an app with
    # ~675 routes it cost 0.45s of boot, over half of it on static paths.
    #
    # Path parameter names come from the path string instead (PARAM_SEGMENT_NAME
    # produces the same list as Mustermann#names), so param extraction does not
    # drag the pattern back into registration.
    def pattern_for(entry)
      entry[:mustermann] ||= Mustermann.new(entry[:path])
    end

    def route_data(entry, endpoint)
      {
        endpoint: endpoint,
        mustermann: pattern_for(entry),
        entry: entry,
        path: entry[:path]
      }
    end

    def register_all_route(path, endpoint, entry)
      raise_collision("ALL", path, endpoint, entry[:all]) if entry[:all]

      entry[:all] = endpoint
      @prepared_dirty = true
    end

    def register_method_route(method, path, endpoint, entry)
      raise_collision(method, path, endpoint, entry[:methods][method]) if entry[:methods].key?(method)

      entry[:methods][method] = endpoint
      @prepared_dirty = true
    end

    def raise_collision(method, path, endpoint, existing_endpoint)
      raise Raxon::Error, "Route collision for #{method.upcase} #{path}: " \
                          "#{endpoint.route_file_path || "unknown file"} conflicts with " \
                          "#{existing_endpoint.route_file_path || "unknown file"}"
    end

    # Registration marks the prepared table dirty instead of rebuilding it.
    # Rebuilding on every register was quadratic: each of an application's N
    # registrations re-prepared all N entries. One app registered 675 routes and
    # built 404,329 EffectiveEndpoint objects, 599 per route, which was 72% of
    # its route loading. Deferring to the first read makes that one rebuild.
    def ensure_prepared_routes
      return unless @prepared_dirty

      @prepared_mutex.synchronize do
        return unless @prepared_dirty

        rebuild_prepared_routes
        @prepared_dirty = false
      end
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

        hierarchy = endpoint_hierarchy(entry[:path], method, endpoint)
        effective = EffectiveEndpoint.new(endpoint, hierarchy)
        endpoint.effective_endpoint = effective
        entry[:prepared][method] = {
          endpoint: endpoint,
          endpoints: hierarchy,
          effective_endpoint: effective
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

      hierarchy = endpoint_hierarchy(entry[:path], "GET", get_endpoint)
      effective = EffectiveEndpoint.new(get_endpoint, hierarchy)
      get_endpoint.effective_endpoint = effective
      entry[:prepared]["HEAD"] = {
        endpoint: get_endpoint,
        endpoints: hierarchy,
        effective_endpoint: effective,
        head_from_get: true
      }
    end

    # Dynamic routes are matched by asking Mustermann, one pattern at a time,
    # until one answers. That is linear in the number of dynamic routes, which
    # is fine for the handful a benchmark declares and not fine for an
    # application: fifty resources of eight routes each spend ~35us finding
    # `/api/v1/x/{id}` and ~76us finding `/api/v1/x/{id}/archive`, more than the
    # rest of the request put together.
    #
    # So patterns are indexed by their segments, and only the entries whose
    # shape can match a given path are asked. The index narrows; it does not
    # match. Mustermann still decides, and still extracts the params, so a
    # candidate that reaches it is answered exactly as before.
    #
    # Candidates come back in registration order because that is the order the
    # linear scan used, and the first pattern to match wins. Two patterns can
    # both match one path — `/a/{b}/c` and `/a/x/{c}` — and which of them
    # answers is behavior, not an implementation detail.
    #
    # @param path [String]
    # @return [Array<Hash>] Entries whose shape admits this path
    def dynamic_candidates(path)
      # Narrowing is not free: it splits the path and builds an array to hold
      # the result. Below a handful of patterns, asking all of them costs less
      # than working out which to ask, so the scan stays. This is the same
      # linear scan as before, on the same entries, in the same order.
      return @dynamic_entries if @dynamic_entries.length <= LINEAR_SCAN_LIMIT

      found = []
      collect_candidates(@dynamic_root, path.split("/", -1), 0, found)
      found.concat(@unindexable_entries) unless @unindexable_entries.empty?
      # Static is walked before dynamic, so anything drawn from both branches
      # arrives out of registration order. One candidate is the common case and
      # needs no sorting.
      found.sort_by! { |entry| entry[:order] } if found.length > 1
      found
    end

    def collect_candidates(node, segments, depth, found)
      if depth == segments.length
        entries = node[:entries]
        found.concat(entries) if entries
        return
      end

      static = node[:static][segments[depth]]
      collect_candidates(static, segments, depth + 1, found) if static

      dynamic = node[:dynamic]
      collect_candidates(dynamic, segments, depth + 1, found) if dynamic
    end

    def index_dynamic_entry(entry)
      node = @dynamic_root

      entry[:path].split("/", -1).each do |segment|
        node = if !segment.include?("{")
          node[:static][segment] ||= new_index_node
        elsif PURE_PARAM_SEGMENT.match?(segment)
          node[:dynamic] ||= new_index_node
        else
          # A segment like `{name}.json` matches by neither equality nor
          # wildcard, so it cannot be placed. Rather than guess, it stays a
          # candidate for every path and Mustermann rules on it as before.
          @unindexable_entries << entry
          return nil
        end
      end

      (node[:entries] ||= []) << entry
      sort_index_entries(node)
    end

    def sort_index_entries(node)
      node[:entries].sort_by! { |entry| entry[:order] } if node[:entries].length > 1
    end

    def new_index_node
      {static: {}, dynamic: nil, entries: nil}
    end

    def matching_entries(path)
      entries = []
      exact = @entries_by_path[path]
      entries << exact if exact

      dynamic_candidates(path).each do |entry|
        entries << entry if !entry.equal?(exact) && pattern_for(entry).match(path)
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
      dynamic_candidates(path).each do |entry|
        endpoint = entry[:methods][method]
        next unless endpoint

        match = pattern_for(entry).match(path)
        return dynamic_route_data(entry, method, match) if match
      end

      nil
    end

    def find_all_pattern_candidate(method, path)
      dynamic_candidates(path).each do |entry|
        endpoint = entry[:all]
        next unless endpoint

        match = pattern_for(entry).match(path)
        return dynamic_route_data(entry, method, match) if match
      end

      nil
    end

    # HEAD requests with no explicit HEAD or all route fall back to the GET
    # route; the prepared HEAD entry carries the head_from_get marker.
    def find_head_fallback_candidate(method, path)
      return nil unless method == "HEAD"

      dynamic_candidates(path).each do |entry|
        next unless entry[:methods]["GET"]

        match = pattern_for(entry).match(path)
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
