require "erb"

module Raxon
  class RouteLoader
    VALID_HTTP_METHODS = %w[all get post put patch delete head options].freeze
    ACTUAL_HTTP_METHODS = %w[get post put patch delete head options].freeze

    # Thread-local holding the in-progress registry during {load!}. Only the
    # loading thread sees it; every other thread keeps reading the published
    # registry until the load finishes. See {load!}.
    STAGING_KEY = :raxon_route_staging

    class << self
      attr_accessor :catchall
      attr_writer :registered_files, :routes

      # The live route registry.
      #
      # While this thread is inside {load!} it returns the registry being built,
      # so route files register into the staging copy. Every other thread — an
      # in-flight request, say — keeps seeing the previously published registry
      # until the load completes and swaps it in.
      #
      # @return [Routes]
      def routes
        Thread.current[STAGING_KEY]&.fetch(:routes) || @routes
      end

      # @return [Set<String>] absolute paths of route files already registered
      # @see routes
      def registered_files
        Thread.current[STAGING_KEY]&.fetch(:registered_files) || @registered_files
      end

      # Load all routes from the configured routes directory.
      #
      # Discovers all .rb files in the routes directory and its subdirectories,
      # loads them, and registers the routes. The directory structure determines
      # the API path, and the filename determines the HTTP method.
      #
      # Files are loaded in a specific order:
      # 1. all.rb files first (sorted by depth, shallowest to deepest)
      # 2. Other method files (sorted by depth, then alphabetically)
      #
      # This ensures all.rb routes are registered before method-specific routes.
      #
      # Each route file is loaded in an isolated context (anonymous class) so that
      # methods defined with `def` are scoped to that file and don't pollute the
      # global namespace.
      #
      # Files already registered are skipped, so calling this repeatedly is
      # additive rather than a rebuild. Use {reload!} to rebuild from disk.
      #
      # @return [Routes] The collection of registered routes
      # @example
      #   routes = Raxon::RouteLoader.load!
      #   routes.find(:GET, "/api/v1/users")
      def load!
        load_route_files
        routes.prepare!
        routes
      end

      # Rebuild the registry from disk, publishing the result atomically.
      #
      # Hot reloading runs while requests are in flight, so the previous
      # approach — clear the live registry, then repopulate it in place — left
      # every route unroutable for the duration of the load. That window is not
      # an instant: it is a glob plus a read and eval of every route file, and a
      # request landing inside it 404s (or falls through to the catchall) for
      # routes that plainly exist.
      #
      # Route files here register into a staging registry that only the loading
      # thread can see; other threads keep reading the published one until a
      # single assignment swaps it in. A reader therefore observes either the
      # complete old registry or the complete new one, never a partial build.
      #
      # If a route file raises, nothing is published and the previous registry
      # keeps serving — the failure surfaces on the request that triggered the
      # reload, and fixing the file recovers, exactly as before.
      #
      # @return [Routes] The newly published collection of registered routes
      def reload!
        staged = {routes: Routes.new, registered_files: Set.new}

        Thread.current[STAGING_KEY] = staged
        begin
          load_route_files
        ensure
          Thread.current[STAGING_KEY] = nil
        end

        @routes = staged[:routes]
        @registered_files = staged[:registered_files]
        routes
      end

      # Discover and evaluate every route file, in the order the DSL requires,
      # registering into whichever registry is currently in scope (the live one,
      # or a staging copy when called from {reload!}).
      #
      # @return [void]
      #
      # @private
      def load_route_files
        directories = expanded_routes_directories
        roots = PathContainment.resolve_roots(directories)
        route_files = directories.flat_map do |directory|
          Dir.glob(File.join(directory, "**", "*.rb"), File::FNM_DOTMATCH)
        end

        # Sort files to ensure all.rb files are loaded first, ordered by depth
        sorted_files = route_files.sort_by do |file|
          is_all = file.end_with?("all.rb")
          depth = file.count("/")
          # all.rb files first (0), then other files (1), both sorted by depth then path
          [is_all ? 0 : 1, depth, file]
        end

        already_loaded = registered_files

        sorted_files.each do |file|
          # {define} already refuses to register a file twice, but it does so
          # after the file has been read and evaluated, so a second load! still
          # paid for every file. An app that loads routes at boot and then builds
          # a Router does exactly that: the mount re-read and re-evaluated all of
          # them for nothing. Skipping here is the same decision, made before the
          # work rather than after.
          #
          # {reload!} stages an empty set, so a rebuild from disk still loads
          # everything.
          next if already_loaded.include?(File.expand_path(file))

          guard_contained!(file, roots)
          load_route_in_isolation(file)
        end
      end

      # Refuse to load a route file whose real path escapes the configured
      # routes tree via a symlink. See {Raxon::PathContainment}.
      #
      # @param file [String] the globbed route file path
      # @param roots [Array<String>] real paths of the configured routes dirs
      # @raise [Raxon::Error] when the file resolves outside every root
      # @return [void]
      #
      # @private
      def guard_contained!(file, roots)
        return if PathContainment.contained?(file, roots)

        raise Raxon::Error, "Refusing to load route file outside routes_directory: #{file} " \
                            "(it resolves outside the configured routes tree — check for a symlink)."
      end

      # Load a route file in an isolated context.
      #
      # Creates an anonymous class for each route file and evaluates the file
      # content within that class. This ensures that any methods defined with
      # `def` become instance methods of the anonymous class rather than polluting
      # the global namespace (main).
      #
      # This is namespace isolation, not a security sandbox: the file is executed
      # with `class_eval` and has full process privileges (constants, Kernel,
      # filesystem, network). Route directories must be trusted — see
      # {Raxon::PathContainment} and docs/security.md.
      #
      # The anonymous class includes HandlerHelpers, so shared helpers are available
      # alongside file-specific methods.
      #
      # @param file [String] Path to the route file
      # @return [void]
      #
      # @private
      def load_route_in_isolation(file)
        content = File.read(file)

        # Create an isolated class for this route file
        # Methods defined with `def` will become instance methods of this class
        route_context = Class.new do
          include Raxon::HandlerHelpers
        end

        # Store context in thread-local so register() can access it
        Thread.current[:raxon_route_context] = route_context

        # Evaluate file content in the class context
        # Pass file path and line number for accurate stack traces
        route_context.class_eval(content, file, 1)
      ensure
        Thread.current[:raxon_route_context] = nil
      end

      # Reset the routes collection to empty state.
      #
      # Clears all registered routes and catchall. Useful for testing or reloading
      # routes in a fresh state.
      #
      # @return [Routes] The empty routes collection
      def reset!
        @registered_files = Set.new
        @routes = Routes.new
        @catchall = nil
      end

      # Define a route from a file path and configuration block.
      #
      # This is the internal registration engine. Route files use the public
      # `Raxon.route` DSL, which infers the file path from the call site and
      # delegates here. It extracts routing information from the file path,
      # creates an endpoint via the OpenAPI DSL, executes the configuration
      # block, and stores the endpoint in the routes collection.
      #
      # @param file_path [String] The absolute path to the route file
      # @param block [Proc] Configuration block that receives the endpoint and
      #   configures its metadata (description, responses, handler, etc.)
      # @return [void]
      # @example
      #   Raxon::RouteLoader.define("/routes/api/v1/users/get.rb") do |endpoint|
      #     endpoint.description "Get all users"
      #     endpoint.response 200, type: :array, of: :User
      #     endpoint.handler { |request, response| ... }
      #   end
      def define(file_path, &block)
        expanded_path = File.expand_path(file_path)
        return if registered_files.include?(expanded_path)

        registered_files.add(expanded_path)

        directory = routes_directory_for(file_path)
        extract_route_info(file_path, directory) => {path:, method:, param_names:}

        # Capture the route context (anonymous class) for isolated method scoping
        # This may be nil for programmatic registration (backwards compatibility)
        route_context = Thread.current[:raxon_route_context]

        OpenApi::DSL.endpoint do |endpoint|
          configure_endpoint(endpoint, file_path, path, method, param_names)

          # Pre-compile ERB template if it exists
          compile_erb_template(endpoint, file_path)

          # Pass the route context to the endpoint for isolated execution
          endpoint.route_context = route_context

          # Execute the block to configure the endpoint
          block.call(endpoint)

          # Store the endpoint with the Routes collection
          routes.register(method.upcase, path, endpoint)
        end
      end

      # Register a catchall endpoint for unmatched routes.
      #
      # This method registers an endpoint that will be used when no other route
      # matches the request. The catchall endpoint receives the same request,
      # response, and metadata arguments as regular endpoints.
      #
      # @param block [Proc] Configuration block that receives the endpoint and
      #   configures its metadata (description, responses, handler, etc.)
      # @return [void]
      # @example
      #   Raxon::RouteLoader.register_catchall do |endpoint|
      #     endpoint.description "Handle unmatched routes"
      #     endpoint.response 404, type: :object do |response|
      #       response.property :error, type: :string
      #     end
      #     endpoint.handler do |request, response, metadata|
      #       response.code = :not_found
      #       response.body = { error: "Not Found" }
      #     end
      #   end
      def register_catchall(&block)
        # Built directly (not via OpenApi::DSL.endpoint) so the catchall's
        # synthetic "/*" path never appears in the generated OpenAPI document.
        endpoint = OpenApi::Endpoint.new
        endpoint.path("/*")
        endpoint.method = "all"
        endpoint.operation(:get)

        block.call(endpoint)

        @catchall = endpoint
      end

      private

      # Return the configured routes directories as an array.
      #
      # Supports the historical single String value and the new multi-directory
      # Array value. Nil entries are ignored so applications can conditionally
      # append engine paths.
      #
      # @return [Array<String>]
      def routes_directories
        Array(Raxon.configuration.routes_directory).compact
      end

      # Return configured route directories as expanded absolute paths.
      #
      # @return [Array<String>]
      def expanded_routes_directories
        routes_directories.map { |directory| File.expand_path(directory) }.uniq
      end

      # Find the configured routes directory that contains the given file.
      #
      # When multiple directories are configured, a route file's path should be
      # made relative to the directory it was loaded from. This lets application
      # and engine route trees be unioned without including their filesystem
      # prefixes in the URL path.
      #
      # @param file_path [String]
      # @return [String]
      # @raise [Raxon::Error] If no configured routes directory contains file_path
      def routes_directory_for(file_path)
        expanded_file_path = File.expand_path(file_path)

        expanded_routes_directories
          .select { |directory| expanded_file_path == directory || expanded_file_path.start_with?(directory + File::SEPARATOR) }
          .max_by(&:length) || raise(Raxon::Error, "Route file #{file_path} is not inside configured routes_directory: #{routes_directories.join(", ")}")
      end

      # Configure basic endpoint properties from route info.
      #
      # Sets the path, method, and operation on the endpoint object.
      # This is called internally during route registration to set up
      # the base endpoint properties before the user's configuration block
      # is executed.
      #
      # @param endpoint [Endpoint] The endpoint to configure
      # @param path [String] The URL path (e.g., "/api/v1/users/{id}")
      # @param method [String] The HTTP method in lowercase (e.g., "get", "post")
      # @return [void]
      #
      # @private
      def configure_endpoint(endpoint, file_path, path, method, param_names = [])
        endpoint.path(path)
        endpoint.method = method
        endpoint.operation((method == "all") ? ACTUAL_HTTP_METHODS.map(&:to_sym) : method.to_sym)
        endpoint.route_file_path = file_path
        endpoint.infer_path_parameters(param_names)
      end

      # Extract routing information from a file path.
      #
      # Parses the file path to determine the HTTP method (from filename),
      # the API path (from directory structure), and any path parameters.
      # Converts $param or __param__ style parameters to {param} OpenAPI format.
      #
      # @param file_path [String] Absolute or relative path to the route file
      # @param routes_directory [String] The configured routes directory
      # @return [Hash{Symbol => Object}] Hash with keys:
      #   - :path [String] The API path with {param} placeholders
      #   - :method [String] The HTTP method in lowercase
      #   - :param_names [Array<String>] Names of path parameters
      # @example
      #   extract_route_info("routes/api/v1/users/$id/get.rb", "routes")
      #   # => {path: "/api/v1/users/{id}", method: "get", param_names: ["id"]}
      # @example
      #   extract_route_info("routes/api/v1/users/__id__/get.rb", "routes")
      #   # => {path: "/api/v1/users/{id}", method: "get", param_names: ["id"]}
      #
      # @private
      def extract_route_info(file_path, routes_directory)
        # Extract path and method from file path
        # Example: routes/api/v1/users/get.rb with routes_directory="routes"
        # Should extract: path = /api/v1/users, method = get
        # Example with params: routes/api/v1/users/$id/get.rb
        # Should extract: path = /api/v1/users/{id}, method = get

        # Get the relative path from the routes directory
        expanded_routes_dir = File.expand_path(routes_directory)
        expanded_file_path = File.expand_path(file_path)
        relative_path = expanded_file_path.sub(/^#{Regexp.escape(expanded_routes_dir)}\//, "")

        parts = relative_path.split("/")

        # Extract and validate HTTP method from filename
        method = extract_and_validate_method(parts.pop)

        # Convert path parts, extracting parameter names
        path_parts, param_names = convert_path_to_parts_with_params(parts)

        # Build final path
        path = build_path_from_parts(path_parts)

        {path:, method:, param_names:}
      end

      # Extract HTTP method from method file and validate it.
      #
      # Extracts the filename (without .rb extension), converts to lowercase,
      # and validates that it's a supported HTTP method. Raises an error if
      # the method is invalid.
      #
      # @param method_file [String] Filename like "get.rb" or "post.rb"
      # @return [String] The HTTP method in lowercase
      # @raise [Raxon::Error] If method is not a valid HTTP verb
      # @example
      #   extract_and_validate_method("get.rb")
      #   # => "get"
      #   extract_and_validate_method("invalid.rb")
      #   # => Raxon::Error: Invalid HTTP method...
      #
      # @private
      def extract_and_validate_method(method_file)
        method = File.basename(method_file, ".rb").downcase
        validate_http_method(method, method_file)
        method
      end

      # Validate that a method is a legitimate HTTP verb.
      #
      # Checks if the provided method is in the list of valid HTTP methods
      # (get, post, put, patch, delete, head, options). Raises an error with
      # helpful message if invalid.
      #
      # @param method [String] The HTTP method to validate
      # @param method_file [String] The original filename for error reporting
      # @return [void]
      # @raise [Raxon::Error] If method is not valid
      #
      # @private
      def validate_http_method(method, method_file)
        return if VALID_HTTP_METHODS.include?(method)

        raise Raxon::Error, "Invalid HTTP method in filename: #{method_file}. " \
                            "Must be one of: #{VALID_HTTP_METHODS.join(", ")}"
      end

      # Convert path parts, converting $param or __param__ to {param} format.
      #
      # Transforms path segments that start with $ (e.g., "$id") or use dunder
      # syntax (e.g., "__id__") into OpenAPI parameter format (e.g., "{id}").
      # Collects the parameter names for later use.
      #
      # @param parts [Array<String>] Path segments (e.g., ["api", "v1", "users", "$id"])
      # @return [Array<(Array, Array)>] Tuple of:
      #   - path_parts [Array<String>] Converted segments (e.g., ["api", "v1", "users", "{id}"])
      #   - param_names [Array<String>] Extracted parameter names (e.g., ["id"])
      # @example
      #   convert_path_to_parts_with_params(["api", "v1", "users", "$id"])
      #   # => [["api", "v1", "users", "{id}"], ["id"]]
      # @example
      #   convert_path_to_parts_with_params(["api", "v1", "users", "__id__"])
      #   # => [["api", "v1", "users", "{id}"], ["id"]]
      #
      # @private
      def convert_path_to_parts_with_params(parts)
        param_names = []
        path_parts = parts.map do |part|
          param_name = extract_param_name(part)
          if param_name
            param_names << param_name
            "{#{param_name}}"
          else
            part
          end
        end

        [path_parts, param_names]
      end

      # Extract parameter name from a path segment.
      #
      # Supports two syntaxes:
      # - Dollar prefix: $id, $user_id
      # - Dunder (double underscore): __id__, __user_id__
      #
      # @param part [String] A path segment
      # @return [String, nil] The parameter name if this is a parameter segment, nil otherwise
      #
      # @private
      def extract_param_name(part)
        if part.start_with?("$")
          part[1..]
        elsif part.start_with?("__") && part.end_with?("__") && part.length > 4
          part[2..-3]
        end
      end

      # Build the final URL path from path parts.
      #
      # Joins path segments with forward slashes and adds a leading slash
      # to create a complete API path.
      #
      # @param path_parts [Array<String>] Path segments to join (e.g., ["api", "v1", "users"])
      # @return [String] The complete URL path with leading slash (e.g., "/api/v1/users")
      # @example
      #   build_path_from_parts(["api", "v1", "users", "{id}"])
      #   # => "/api/v1/users/{id}"
      #
      # @private
      def build_path_from_parts(path_parts)
        "/" + path_parts.join("/")
      end

      # Pre-compile ERB template if it exists for the route.
      #
      # Checks if a corresponding .html.erb file exists for the route file,
      # and if so, reads and compiles it into an ERB object stored in the endpoint.
      # This allows for efficient template rendering without re-parsing on each request.
      #
      # @param endpoint [Endpoint] The endpoint to configure with the template
      # @param file_path [String] Absolute path to the route file
      # @return [void]
      #
      # @private
      def compile_erb_template(endpoint, file_path)
        template_path = file_path.sub(/\.rb$/, ".html.erb")
        return unless File.exist?(template_path)

        template_content = File.read(template_path)
        endpoint.erb_template = Raxon::Template.new(template_content)
      end
    end

    # Initialize routes storage
    self.registered_files = Set.new
    self.routes = Routes.new
  end
end
