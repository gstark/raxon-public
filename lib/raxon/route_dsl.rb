# frozen_string_literal: true

module Raxon
  # Public shorthand DSL used by route files via `Raxon.route do ... end`.
  #
  # The shorthand is the sole route-file API. It infers the route file path
  # from the call site and delegates to the internal RouteLoader.define engine.
  class RouteDSL
    # @param endpoint [Raxon::OpenApi::Endpoint]
    def initialize(endpoint)
      @endpoint = endpoint
    end

    # Define a response and, for zero-arity blocks, evaluate the nested response
    # DSL with the response object as the receiver. This enables:
    #
    #   response 200, type: :object do
    #     property :success, type: :boolean
    #   end
    def response(status, options, &block)
      @endpoint.response(status, options, &wrap_nested_block(block))
    end

    # Define a request body and, for zero-arity blocks, evaluate the nested body
    # DSL with the request body object as the receiver.
    def request_body(options = nil, &block)
      return @endpoint.request_body if options.nil?

      @endpoint.request_body(options, &wrap_nested_block(block))
    end

    # Alias for request_body in the concise route DSL.
    def body(options = nil, &block)
      return @endpoint.body if options.nil?

      @endpoint.body(options, &wrap_nested_block(block))
    end

    # Configure parameters. Zero-arity blocks are evaluated with the parameters
    # object as the receiver so callers may write `define :id, ...` directly.
    def parameters(&block)
      return @endpoint.parameters unless block_given?

      @endpoint.parameters(&wrap_nested_block(block))
    end

    # Delegate the remaining endpoint API (`description`, `handler`, `before`,
    # `after`, etc.) unchanged.
    def method_missing(method_name, *args, **kwargs, &block)
      return super unless @endpoint.respond_to?(method_name)

      @endpoint.public_send(method_name, *args, **kwargs, &block)
    end

    def respond_to_missing?(method_name, include_private = false)
      @endpoint.respond_to?(method_name, include_private) || super
    end

    private

    def wrap_nested_block(block)
      return nil unless block
      return block unless block.arity.zero?

      proc do |nested_target|
        NestedDSL.new(nested_target).instance_eval(&block)
      end
    end

    # Small proxy for nested OpenAPI DSL objects such as Response, RequestBody,
    # and Property. It delegates all public methods and recursively supports
    # zero-arity nested `property` blocks.
    class NestedDSL
      def initialize(target)
        @target = target
      end

      def property(name, options, &block)
        @target.property(name, options, &wrap_nested_block(block))
      end

      def method_missing(method_name, *args, **kwargs, &block)
        return super unless @target.respond_to?(method_name)

        @target.public_send(method_name, *args, **kwargs, &block)
      end

      def respond_to_missing?(method_name, include_private = false)
        @target.respond_to?(method_name, include_private) || super
      end

      private

      def wrap_nested_block(block)
        return nil unless block
        return block unless block.arity.zero?

        proc do |nested_target|
          self.class.new(nested_target).instance_eval(&block)
        end
      end
    end
  end

  # Register a route from the calling route file using a concise public DSL.
  #
  # @yield The route definition. Zero-arity blocks are evaluated against a
  #   RouteDSL proxy; one-arity blocks receive the endpoint for callers that want
  #   direct access.
  # @return [void]
  #
  # @example
  #   Raxon.route do
  #     description "Health check"
  #
  #     response 200, type: :object do
  #       property :success, type: :boolean
  #     end
  #
  #     handler do |_request, response|
  #       response.code = :ok
  #       response.body = { success: true }
  #     end
  #   end
  def self.route(&block)
    raise ArgumentError, "Raxon.route requires a block" unless block

    file_path = caller_locations(1, 1).first.path

    RouteLoader.define(file_path) do |endpoint|
      if block.arity.zero?
        RouteDSL.new(endpoint).instance_eval(&block)
      else
        block.call(endpoint)
      end
    end
  end
end
