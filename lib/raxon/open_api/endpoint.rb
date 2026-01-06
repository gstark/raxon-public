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
      attr_accessor :method
      attr_accessor :route_file_path
      attr_accessor :erb_template

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
        @operations = []
        @responses = {}
        @parameters = Parameters.new
        @request_body = nil
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
      #     params.define :id, type: :string, in: :path
      #     params.define :limit, type: :number, in: :query, required: false
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
          @request_body = RequestBody.new(**options)
          yield @request_body if block_given?
        end
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
        @responses[status] = Response.new(**options)
        yield @responses[status] if block_given?
      end

      # Define a standard exception error response for this endpoint.
      # This is a convenience method for the common error response pattern with
      # status, error_message, and errors properties.
      #
      # @param status [Symbol, Integer] HTTP status code (default: :unprocessable_entity)
      # @param description [String] Response description (default: "Validation error")
      #
      # @example
      #   endpoint.exception_error
      #   endpoint.exception_error :bad_request, description: "Invalid request"
      def exception_error(status = :unprocessable_entity, description: "Validation error")
        response(status, type: :object, description: description) do |resp|
          resp.property :status, type: :string, description: "Status of the request"
          resp.property :error_message, type: :string, description: "Error message"
          resp.property :errors, type: :object, description: "Validation errors"
        end
      end

      # Set the request handler for this endpoint.
      #
      # Extends the block's binding context with HandlerHelpers so that all
      # helper methods are available when the handler executes.
      #
      # @yield [request, response] The handler block that processes requests
      # @yieldparam request [Object] The request object (typically Rack::Request or Raxon::Request)
      # @yieldparam response [Object] The response object (Raxon::Response)
      #
      # @example
      #   endpoint.handler do |request, response|
      #     response.code = :ok
      #     response.body = { success: true }
      #   end
      def handler(&block)
        # Extend the block's binding self with HandlerHelpers
        # This is done once at definition time, not on every execution
        block_self = block.binding.eval("self")
        unless block_self.singleton_class.include?(Raxon::HandlerHelpers)
          block_self.extend(Raxon::HandlerHelpers)
        end

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
        @request_schema ||= Raxon::OpenApi::RequestSchemaGenerator.new(@parameters, @request_body).to_dry_schema
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

      # Call this endpoint with a request and response.
      # Executes the before block and handler, applying validation as needed.
      #
      # If the endpoint has parameter validation configured and the request fails
      # validation, sets a 400 Bad Request response with error details instead of
      # calling the before block or handler.
      #
      # If the endpoint has response validation configured and the response fails
      # validation, sets a 500 Internal Server Error response with error details.
      #
      # @param request [Raxon::Request] The request wrapper object
      # @param response [Raxon::Response] The response wrapper object
      # @param metadata [Hash] Optional metadata hash built from route hierarchy
      # @return [Array] Rack-compatible response array [status, headers, body]
      #
      # @example
      #   request = Raxon::Request.new(rack_request, endpoint)
      #   response = Raxon::Response.new
      #   status, headers, body = endpoint.call(request, response)
      def call(request, response, metadata = {})
        # Trigger parameter validation by accessing params
        # This will populate request.validation_errors if validation fails
        request.params

        # If JSON parsing failed, return 400 Bad Request
        if request.json_parse_error
          response.code = :bad_request
          response.body = {
            error: "Invalid JSON in request body"
          }
          return
        end

        # If validation failed, return 400 Bad Request with error details
        if request.validation_errors
          response.code = :bad_request
          response.body = {
            error: "Validation failed",
            details: request.validation_errors
          }
          return
        end

        # Stop processing if halt was called
        unless response.halted?
          # Execute the handler block if defined (can be absent for before-only endpoints)
          if @handler_block
            execute_handler_with_helpers(request, response, metadata)
          end
        end

        # Validate response body against schema for the returned status code
        validate_response_body(response)
      end

      private

      # Execute the handler block.
      #
      # The handler block was already extended with HandlerHelpers when it was
      # defined via the handler() method, so we can just call it directly.
      #
      # @param request [Raxon::Request] The request object
      # @param response [Raxon::Response] The response object
      # @param metadata [Hash] The metadata hash built from route hierarchy
      # @return [void]
      def execute_handler_with_helpers(request, response, metadata)
        @handler_block.call(request, response, metadata)
      end

      # Validate the response body against the schema for its status code.
      # Raises an error if validation fails, as this indicates a programming error.
      #
      # @param response [Raxon::Response] The response to validate
      # @return [void]
      def validate_response_body(response)
        status_code = response.status_code
        schema = response_schemas[status_code]

        # Only validate if we have a schema for this status code and a body to validate
        return unless schema && response.body

        result = schema.call(response.body)
        return if result.success?

        # Response validation failure is a server error (programming bug)
        # Replace the response with an error response
        response.code = :internal_server_error
        response.body = {
          error: "Response validation failed",
          status_code: status_code,
          details: result.errors.to_h
        }
      end
    end
  end
end
