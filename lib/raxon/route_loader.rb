require "erb"

module Raxon
  class RouteLoader
    VALID_HTTP_METHODS = %w[all get post put patch delete head options].freeze
    ACTUAL_HTTP_METHODS = %w[get post put patch delete head options].freeze

    class << self
      attr_accessor :catchall, :registered_files, :routes

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
      # @return [Routes] The collection of registered routes
      # @example
      #   routes = Raxon::RouteLoader.load!
      #   routes.find(:GET, "/api/v1/users")
      def load!
        directory = Raxon.configuration.routes_directory
        route_files = Dir.glob(File.join(directory, "**", "*.rb"))

        # Sort files to ensure all.rb files are loaded first, ordered by depth
        sorted_files = route_files.sort_by do |file|
          is_all = file.end_with?("all.rb")
          depth = file.count("/")
          # all.rb files first (0), then other files (1), both sorted by depth then path
          [is_all ? 0 : 1, depth, file]
        end

        sorted_files.each do |file|
          load file
        end

        routes
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

      # Register a route from a file path and configuration block.
      #
      # This method is called by route files using the Raxon::RouteLoader.register helper.
      # It extracts routing information from the file path, creates an endpoint
      # via the OpenAPI DSL, executes the configuration block, and stores the
      # endpoint in the routes collection.
      #
      # @param file_path [String] The absolute path to the route file
      # @param block [Proc] Configuration block that receives the endpoint and
      #   configures its metadata (description, responses, handler, etc.)
      # @return [void]
      # @example
      #   Raxon::RouteLoader.register("/routes/api/v1/users/get.rb") do |endpoint|
      #     endpoint.description "Get all users"
      #     endpoint.response 200, type: :array, of: :User
      #     endpoint.handler { |request, response| ... }
      #   end
      def register(file_path, &block)
        expanded_path = File.expand_path(file_path)
        return if registered_files.include?(expanded_path)

        registered_files.add(expanded_path)

        directory = Raxon.configuration.routes_directory
        extract_route_info(file_path, directory) => {path:, method:, param_names:}

        # Determine which HTTP methods to register for
        methods_to_register = if method == "all"
          ACTUAL_HTTP_METHODS
        else
          [method]
        end

        # Register endpoint for each method
        methods_to_register.each do |http_method|
          OpenApi::DSL.endpoint do |endpoint|
            configure_endpoint(endpoint, file_path, path, http_method)

            # Pre-compile ERB template if it exists
            compile_erb_template(endpoint, file_path)

            # Execute the block to configure the endpoint
            block.call(endpoint)

            # Store the endpoint with the Routes collection
            routes.register(http_method.upcase, path, endpoint)
          end
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
        OpenApi::DSL.endpoint do |endpoint|
          endpoint.path("/*")
          endpoint.method = "all"
          endpoint.operation(:get)

          block.call(endpoint)

          @catchall = endpoint
        end
      end

      private

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
      def configure_endpoint(endpoint, file_path, path, method)
        endpoint.path(path)
        endpoint.method = method
        endpoint.operation(method.to_sym)
        endpoint.route_file_path = file_path
      end

      # Extract routing information from a file path.
      #
      # Parses the file path to determine the HTTP method (from filename),
      # the API path (from directory structure), and any path parameters.
      # Converts $param style parameters to {param} OpenAPI format.
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

      # Convert path parts, converting $param to {param} format.
      #
      # Transforms path segments that start with $ (e.g., "$id") into OpenAPI
      # parameter format (e.g., "{id}"). Collects the parameter names for later use.
      #
      # @param parts [Array<String>] Path segments (e.g., ["api", "v1", "users", "$id"])
      # @return [Array<(Array, Array)>] Tuple of:
      #   - path_parts [Array<String>] Converted segments (e.g., ["api", "v1", "users", "{id}"])
      #   - param_names [Array<String>] Extracted parameter names (e.g., ["id"])
      # @example
      #   convert_path_to_parts_with_params(["api", "v1", "users", "$id"])
      #   # => [["api", "v1", "users", "{id}"], ["id"]]
      #
      # @private
      def convert_path_to_parts_with_params(parts)
        param_names = []
        path_parts = parts.map do |part|
          if part.start_with?("$")
            param_name = part[1..]
            param_names << param_name
            "{#{param_name}}"
          else
            part
          end
        end

        [path_parts, param_names]
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
        endpoint.erb_template = ERB.new(template_content)
      end
    end

    # Initialize routes storage
    self.registered_files = Set.new
    self.routes = Routes.new
  end
end
