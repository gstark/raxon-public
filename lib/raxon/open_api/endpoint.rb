# frozen_string_literal: true

module Raxon
  module OpenApi
    # Represents an API endpoint with operations, parameters, and responses.
    #
    # An endpoint defines a path with one or more HTTP operations (GET, POST, etc.),
    # parameters, and possible responses. It's used to generate OpenAPI path definitions.
    #
    # @example Define a simple endpoint
    #   endpoint = Endpoint.new
    #   endpoint.path "/users/{id}"
    #   endpoint.operation [:get, :put]
    #   endpoint.parameters do |params|
    #     params.define :id, type: :string, in: :path
    #   end
    #   endpoint.response 200, type: :object, as: :User
    #
    class Endpoint
      attr_reader :operations
      attr_reader :responses
      attr_reader :before_blocks
      attr_reader :after_blocks
      attr_reader :metadata_blocks
      attr_reader :handler_block
      attr_accessor :method
      attr_accessor :route_file_path
      attr_accessor :erb_template
      attr_accessor :route_context

      # Initialize a new endpoint with empty operations, responses, and parameters.
      # Can optionally specify path and method for routing purposes.
      #
      # @param path [String, nil] Optional URL path for the endpoint
      # @param method [String, nil] Optional HTTP method (get, post, etc.)
      def initialize
        @path = nil
        @method = nil
        @route_file_path = nil
        @erb_template = nil
        @route_context = nil
        @operations = []
        @description = nil
        @summary = nil
        @operation_id = nil
        @tags = []
        @deprecated = false
        @security = nil
        @validate_response = nil
        @responses = {}
        @response_schemas = nil
        @parameters = Parameters.new
        @request_body = nil
        @request_schema = nil
        @request_schema_generated = false
        @before_blocks = []
        @after_blocks = []
        @metadata_blocks = []
        @handler_block = nil
      end

      # Get or set the endpoint path.
      #
      # @param args [Array] Optional path string
      # @return [String, nil] The path if called without arguments
      #
      # @example
      #   endpoint.path "/api/v1/users"
      #   endpoint.path  # => "/api/v1/users"
      def path(*args)
        return @path if args.empty?

        @path = args[0]
      end

      # Get or set the endpoint description.
      #
      # @param args [Array] Optional description string
      # @return [String, nil] The description if called without arguments
      #
      # @example
      #   endpoint.description "Get user by ID"
      #   endpoint.description  # => "Get user by ID"
      def description(*args)
        return @description if args.empty?

        @description = args[0]
      end

      # Get or set the OpenAPI operation summary.
      #
      # @param args [Array] Optional summary string
      # @return [String, nil]
      def summary(*args)
        return @summary if args.empty?

        @summary = args[0]
      end

      # Get or set the OpenAPI operationId.
      #
      # @param args [Array] Optional operationId string
      # @return [String, nil]
      def operation_id(*args)
        return @operation_id if args.empty?

        @operation_id = args[0]
      end

      # Get or set OpenAPI operation tags.
      #
      # @param values [Array<String, Symbol, Array>] Tags to assign
      # @return [Array<String, Symbol>]
      def tags(*values)
        return @tags if values.empty?

        @tags = values.flatten
      end

      # Get or set whether the OpenAPI operation is deprecated.
      #
      # @param args [Array] Optional boolean flag
      # @return [Boolean]
      def deprecated(*args)
        return @deprecated if args.empty?

        @deprecated = args[0]
      end

      # Get or set OpenAPI security requirements.
      #
      # Accepts either a full OpenAPI security requirement array/hash or a scheme
      # name plus optional scopes.
      #
      # @param requirement [Symbol, String, Hash, Array, nil]
      # @param scopes [Array<String>] Scopes for scheme-name shorthand
      # @return [Array<Hash>, Hash, nil]
      def security(requirement = nil, scopes: [])
        return @security if requirement.nil?

        @security = case requirement
        when Array
          requirement
        when Hash
          [requirement]
        else
          [{requirement => scopes}]
        end
      end

      # Get or set per-endpoint response validation override.
      #
      # When nil, the global Raxon.configuration.response_validation setting is
      # used. false disables validation for this endpoint, and true forces the
      # configured validation failure behavior even if the global setting is false.
      #
      # @param args [Array] Optional boolean override
      # @return [Boolean, nil]
      def validate_response(*args)
        return @validate_response if args.empty?

        @validate_response = args[0]
      end

      # Add a before hook that will be called before the handler.
      # Multiple before hooks can be added and will be executed in the order they were defined.
      #
      # @yield [request, response] The before block that runs before the handler
      # @yieldparam request [Object] The request object (typically Rack::Request or Raxon::Request)
      # @yieldparam response [Object] The response object (Raxon::Response)
      #
      # @example
      #   endpoint.before do |request, response|
      #     response.header "X-Request-ID", SecureRandom.uuid
      #   end
      #
      #   endpoint.before do |request, response|
      #     response.header "X-Start-Time", Time.now.to_s
      #   end
      def before(&block)
        @before_blocks << block
      end

      # Add an after hook that will be called after the handler.
      # Multiple after hooks can be added and will be executed in the order they were defined.
      #
      # @yield [request, response] The after block that runs after the handler
      # @yieldparam request [Object] The request object (typically Rack::Request or Raxon::Request)
      # @yieldparam response [Object] The response object (Raxon::Response)
      #
      # @example
      #   endpoint.after do |request, response|
      #     response.header "X-Processing-Time", Time.now.to_s
      #   end
      #
      #   endpoint.after do |request, response|
      #     response.header "X-Response-ID", SecureRandom.uuid
      #   end
      def after(&block)
        @after_blocks << block
      end

      # Add a metadata block that will be called to build request metadata.
      # Multiple metadata blocks can be added and will be executed in the order they were defined.
      # Metadata blocks are executed from parent to child in the route hierarchy, with each
      # block's changes merged into the metadata hash.
      #
      # @yield [request, response, metadata] The metadata block that builds request metadata
      # @yieldparam request [Object] The request object (typically Rack::Request or Raxon::Request)
      # @yieldparam response [Object] The response object (Raxon::Response)
      # @yieldparam metadata [Hash] The metadata hash to populate
      #
      # @example
      #   endpoint.metadata do |request, response, metadata|
      #     metadata[:user_id] = request.params[:user_id]
      #     metadata[:request_time] = Time.now
      #   end
      def metadata(&block)
        @metadata_blocks << block
      end

      # Check if this endpoint has any metadata blocks.
      #
      # @return [Boolean] true if one or more metadata blocks are defined
      def has_metadata?
        !@metadata_blocks.empty?
      end

      # Add HTTP operations to this endpoint.
      #
      # @param verbs [Symbol, Array<Symbol>] HTTP verbs like :get, :post, :put, :delete
      #
      # @example
      #   endpoint.operation :get
      #   endpoint.operation [:get, :post]
      def operation(verbs)
        @operations.concat(Array(verbs)).uniq!
      end

      # Configure endpoint parameters or return the parameters object.
      #
      # @yield [Parameters] The parameters object for configuration
      # @return [Parameters] The parameters object if no block given
      #
      # @example
      #   endpoint.parameters do |params|
      #     params.define :id, type: :string, in: :path # required by default
      #     params.define :limit, type: :number, in: :query # optional by default
      #   end
      def parameters(&block)
        if block_given?
          yield @parameters
        else
          @parameters
        end
      end

      # Configure endpoint request body or return the request body object.
      #
      # @param options [Hash] Request body options (type, description, required, etc.)
      # @yield [RequestBody] The request body object for configuration
      # @return [RequestBody, nil] The request body object if no arguments given
      #
      # @example
      #   endpoint.request_body type: :object, description: "User data", required: true do |body|
      #     body.property :name, type: :string
      #     body.property :email, type: :string
      #   end
      def request_body(options = nil, &block)
        if options.nil?
          @request_body
        else
          invalidate_request_schema
          @request_body = RequestBody.new(**options)
          yield @request_body if block_given?
        end
      end

      # Alias for request_body with a shorter route-file API.
      #
      # @param options [Hash, nil] Request body options
      # @yield [RequestBody] The request body object for configuration
      # @return [RequestBody, nil] The request body object when called without arguments
      #
      # @example
      #   endpoint.body type: :object do |body|
      #     body.property :name, type: :string
      #   end
      def body(options = nil, &block)
        request_body(options, &block)
      end

      # Define a path parameter.
      #
      # Path parameters are required by default.
      #
      # @param name [Symbol, String] Parameter name
      # @param options [Hash] Parameter options
      # @yield [Parameter] The parameter object for further configuration
      # @return [Parameter] The created parameter
      def path_param(name, **options, &block)
        define_parameter(name, :path, true, options, &block)
      end

      # Define a query string parameter.
      #
      # Query parameters are optional by default.
      #
      # @param name [Symbol, String] Parameter name
      # @param options [Hash] Parameter options
      # @yield [Parameter] The parameter object for further configuration
      # @return [Parameter] The created parameter
      def query_param(name, **options, &block)
        define_parameter(name, :query, false, options, &block)
      end

      # Define a header parameter.
      #
      # Header parameters are optional by default.
      #
      # @param name [Symbol, String] Parameter name
      # @param options [Hash] Parameter options
      # @yield [Parameter] The parameter object for further configuration
      # @return [Parameter] The created parameter
      def header_param(name, **options, &block)
        define_parameter(name, :header, false, options, &block)
      end

      # Define a cookie parameter.
      #
      # Cookie parameters are optional by default.
      #
      # @param name [Symbol, String] Parameter name
      # @param options [Hash] Parameter options
      # @yield [Parameter] The parameter object for further configuration
      # @return [Parameter] The created parameter
      def cookie_param(name, **options, &block)
        define_parameter(name, :cookie, false, options, &block)
      end

      # Define a response for this endpoint.
      #
      # @param status [Integer] HTTP status code (e.g., 200, 404, 500)
      # @param options [Hash] Response options including type, description, etc.
      # @yield [Response] The response object for further configuration
      #
      # @example
      #   endpoint.response 200, type: :object, as: :User, description: "User found"
      #   endpoint.response 404, type: :object, description: "User not found" do |response|
      #     response.property :error, type: :string
      #   end
      def response(status, options, &block)
        @response_schemas = nil
        @responses[status] = Response.new(**options)
        yield @responses[status] if block_given?
        @responses[status]
      end

      # Define a standard validation error response for this endpoint.
      #
      # @param status [Symbol, Integer] HTTP status code (default: 400)
      # @param description [String] Response description
      # @yield [Response] The response object for customization
      # @return [Response] The created response
      #
      # @example
      #   endpoint.validation_error_response
      def validation_error_response(status = 400, description: "Validation error", &block)
        standard_error_response(status, description: description, include_details: true, &block)
      end

      # Define a standard unauthorized response for this endpoint.
      #
      # @param description [String] Response description
      # @yield [Response] The response object for customization
      # @return [Response] The created response
      #
      # @example
      #   endpoint.unauthorized_response
      def unauthorized_response(description: "Unauthorized", &block)
        standard_error_response(401, description: description, include_details: false, &block)
      end

      # Define a standard not found response for this endpoint.
      #
      # @param description [String] Response description
      # @yield [Response] The response object for customization
      # @return [Response] The created response
      #
      # @example
      #   endpoint.not_found_response
      def not_found_response(description: "Not found", &block)
        standard_error_response(404, description: description, include_details: false, &block)
      end

      # Define a standard error response for this endpoint.
      #
      # @param status [Symbol, Integer] HTTP status code (default: 500)
      # @param description [String] Response description
      # @yield [Response] The response object for customization
      # @return [Response] The created response
      #
      # @example
      #   endpoint.error_response 500
      def error_response(status = 500, description: "Error", &block)
        standard_error_response(status, description: description, include_details: true, &block)
      end

      # Define a standard validation-error response for this endpoint.
      #
      # Documents the canonical validation-error body: an `errors` array of
      # human-readable messages (e.g. ActiveModel `full_messages`). This matches
      # the shape produced by the application's exception/record-invalid render
      # helpers.
      #
      # @param status [Symbol, Integer] HTTP status code (default: :unprocessable_entity)
      # @param description [String] Response description (default: "Validation error")
      #
      # @example
      #   endpoint.exception_error
      #   endpoint.exception_error :bad_request, description: "Invalid request"
      def exception_error(status = :unprocessable_entity, description: "Validation error")
        response(status, type: :object, description: description) do |resp|
          resp.property :errors, type: :array, of: :string, description: "Validation error messages"
        end
      end

      # Set the request handler for this endpoint.
      #
      # The handler block will be executed in the context of the route's isolated
      # class instance, giving it access to:
      # - Methods defined with `def` in the same route file
      # - HandlerHelpers methods (included in the route context)
      # - Instance variables shared with before/after blocks of the same endpoint
      #
      # @yield [request, response, metadata] The handler block that processes requests
      # @yieldparam request [Object] The request object (typically Rack::Request or Raxon::Request)
      # @yieldparam response [Object] The response object (Raxon::Response)
      # @yieldparam metadata [Hash] The metadata hash built from route hierarchy
      #
      # @example
      #   endpoint.handler do |request, response|
      #     response.code = :ok
      #     response.body = { success: true }
      #   end
      def handler(&block)
        @handler_block = block
      end

      # Generate a Dry::Schema validator for this endpoint's request parameters and body.
      #
      # @return [Dry::Schema::Params, nil] The generated schema, or nil if no parameters
      #
      # @example
      #   schema = endpoint.request_schema
      #   result = schema.call(params)
      def request_schema
        return @request_schema if @request_schema || @request_schema_generated

        @request_schema = Raxon::OpenApi::RequestSchemaGenerator.new(@parameters, @request_body).to_dry_schema
        @request_schema_generated = true
        @request_schema
      end

      # Generate Dry::Schema validators for this endpoint's responses.
      #
      # @return [Hash<Integer, Dry::Schema::Params>] Hash of status codes to schemas
      #
      # @example
      #   schemas = endpoint.response_schemas
      #   result = schemas[200].call(response_body)
      def response_schemas
        @response_schemas ||= @responses.transform_values do |response|
          Raxon::OpenApi::ResponseSchemaGenerator.new(response).to_dry_schema
        end.compact
      end

      # Check if this endpoint has any before blocks.
      #
      # @return [Boolean] true if one or more before blocks are defined
      def has_before?
        !@before_blocks.empty?
      end

      # Check if this endpoint has any after blocks.
      #
      # @return [Boolean] true if one or more after blocks are defined
      def has_after?
        !@after_blocks.empty?
      end

      # Check if this endpoint has a handler block.
      #
      # @return [Boolean] true if a handler block is defined
      def has_handler?
        !@handler_block.nil?
      end

      # Create a new instance of the route context class.
      #
      # The route context is an anonymous class that was created when the route
      # file was loaded. It includes HandlerHelpers and any methods defined with
      # `def` in the route file.
      #
      # For endpoints without a route context (e.g., programmatically created),
      # returns an instance of a default context class that includes HandlerHelpers.
      # This maintains backwards compatibility.
      #
      # @return [Object] An instance of the route context
      def create_context_instance
        if @route_context
          @route_context.new
        else
          default_context_class.new
        end
      end

      # Returns the default context class for endpoints without a route context.
      #
      # This class includes HandlerHelpers, providing backwards compatibility
      # for programmatically created endpoints.
      #
      # @return [Class] The default context class
      def default_context_class
        @default_context_class ||= Class.new { include Raxon::HandlerHelpers }
      end

      private

      def standard_error_response(status, description:, include_details:, &block)
        response(status, type: :object, description: description) do |resp|
          resp.property :error, type: :string, description: "Error message"
          resp.property :details, type: :object, description: "Error details", required: false if include_details
          block&.call(resp)
        end
      end

      def define_parameter(name, location, default_required, options, &block)
        parameter_options = options.merge(
          in: location,
          required: options.fetch(:required, default_required)
        )
        invalidate_request_schema
        @parameters.define(name, parameter_options, &block)
      end

      def invalidate_request_schema
        @request_schema = nil
        @request_schema_generated = false
      end
    end
  end
end
