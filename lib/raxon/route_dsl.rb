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

    # Endpoint methods whose block receives a DSL object (a Response,
    # RequestBody, Parameters, or Parameter) rather than request-time
    # arguments. A zero-arity block given to one of these is evaluated with that
    # object as the receiver, so a route file can write
    #
    #   response 200, type: :object do
    #     property :success, type: :boolean
    #   end
    #
    # Blocks for every other method (handler, handle, before, after, metadata)
    # run per request and pass through untouched.
    NESTED_BLOCK_METHODS = %i[
      response default_response
      validation_error_response unauthorized_response not_found_response error_response
      request_body body parameters
      path_param query_param header_param cookie_param
    ].to_set.freeze

    # Delegate the endpoint API, giving declaration blocks their DSL receiver.
    def method_missing(method_name, *args, **kwargs, &block)
      return super unless @endpoint.respond_to?(method_name)

      block = NestedDSL.wrap(block) if NESTED_BLOCK_METHODS.include?(method_name)
      @endpoint.public_send(method_name, *args, **kwargs, &block)
    end

    def respond_to_missing?(method_name, include_private = false)
      @endpoint.respond_to?(method_name, include_private) || super
    end

    # Proxy for nested OpenAPI DSL objects such as Response, RequestBody,
    # Parameters, Parameter, and Property. Every block these objects take
    # (`property`, `define`) receives another DSL object, so every zero-arity
    # block is evaluated against a proxy for it, at any depth.
    class NestedDSL
      # @param block [Proc, nil]
      # @return [Proc, nil] the block, or for a zero-arity block, one that
      #   evaluates it with the yielded DSL object as the receiver
      def self.wrap(block)
        return block unless block&.arity&.zero?

        proc { |target| new(target).instance_eval(&block) }
      end

      def initialize(target)
        @target = target
      end

      def method_missing(method_name, *args, **kwargs, &block)
        return super unless @target.respond_to?(method_name)

        @target.public_send(method_name, *args, **kwargs, &self.class.wrap(block))
      end

      def respond_to_missing?(method_name, include_private = false)
        @target.respond_to?(method_name, include_private) || super
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
