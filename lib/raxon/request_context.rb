# frozen_string_literal: true

module Raxon
  # Request-scoped application context shared by lifecycle blocks and handlers.
  #
  # RequestContext is the recommended place to store application state that is
  # computed while processing one request and needed by later lifecycle stages.
  # Common examples include authenticated users, request IDs, authorization
  # decisions, loaded records, or timing data.
  #
  # The context is intentionally hash-like and symbol-keyed. String keys are
  # normalized to symbols so `context[:current_user]` and
  # `context["current_user"]` address the same value.
  #
  # It also provides optional method-style access for concise route code:
  #
  # @example Hash-style access
  #   request.context[:current_user] = user
  #   request.context[:current_user] # => user
  #
  # @example Method-style access
  #   request.context.current_user = user
  #   request.context.current_user # => user
  #
  # @example Sharing state across lifecycle stages
  #   before do |request, response, metadata|
  #     request.context.current_user = authenticate!(request)
  #   end
  #
  #   handler do |request, response, metadata|
  #     response.body = { user_id: request.context.current_user.id }
  #   end
  #
  # @note `request.context` and the legacy `metadata` handler argument share
  #   the same backing hash. Prefer `request.context` in new code; `metadata`
  #   remains supported for compatibility.
  # @note Method-style readers only return values for keys that are present.
  #   Missing keys raise `NoMethodError`, which helps catch typos.
  class RequestContext
    include Enumerable

    # Initialize a context around an existing hash.
    #
    # @param data [Hash] backing storage for the context. The router passes the
    #   same hash as the legacy metadata argument so both APIs stay synchronized.
    def initialize(data = {})
      @data = data
    end

    # Read a context value.
    #
    # @param key [String, Symbol] context key; normalized to a symbol
    # @return [Object, nil] stored value, or nil when absent
    def [](key)
      @data[key.to_sym]
    end

    # Write a context value.
    #
    # @param key [String, Symbol] context key; normalized to a symbol
    # @param value [Object] value to store for this request
    # @return [Object] the stored value
    def []=(key, value)
      @data[key.to_sym] = value
    end

    # Fetch a context value using Hash#fetch semantics.
    #
    # @param key [String, Symbol] context key; normalized to a symbol
    # @param args [Array] optional default value, matching Hash#fetch
    # @yield Optional fallback block, matching Hash#fetch
    # @return [Object] stored or fallback value
    # @raise [KeyError] when the key is missing and no fallback is provided
    def fetch(key, *args, &block)
      @data.fetch(key.to_sym, *args, &block)
    end

    # Check whether a key exists in the context.
    #
    # @param key [String, Symbol] context key; normalized to a symbol
    # @return [Boolean]
    def key?(key)
      @data.key?(key.to_sym)
    end
    alias_method :has_key?, :key?
    alias_method :include?, :key?

    # Delete a context value.
    #
    # @param key [String, Symbol] context key; normalized to a symbol
    # @return [Object, nil] deleted value, or nil when absent
    def delete(key)
      @data.delete(key.to_sym)
    end

    # Iterate over context key/value pairs.
    #
    # @yieldparam key [Symbol]
    # @yieldparam value [Object]
    # @return [Enumerator, RequestContext] enumerator when no block is given;
    #   otherwise returns the context
    def each(&block)
      return enum_for(:each) unless block

      @data.each(&block)
      self
    end

    # @return [Boolean] true when no context values have been stored
    def empty?
      @data.empty?
    end

    # @return [Array<Symbol>] currently stored keys
    def keys
      @data.keys
    end

    # @return [Array<Object>] currently stored values
    def values
      @data.values
    end

    # Return the backing hash.
    #
    # This intentionally returns the live hash, not a copy, so callers that need
    # legacy metadata interop can pass it through directly. Use `dup.to_h` if a
    # snapshot is needed.
    #
    # @return [Hash]
    def to_h
      @data
    end

    # Return a shallow copy of this context and its current data.
    #
    # @return [RequestContext]
    def dup
      self.class.new(@data.dup)
    end

    # Provide method-style accessors for stored context values.
    #
    # Assignments such as `context.current_user = user` write the
    # `:current_user` key. Readers such as `context.current_user` work only when
    # the key exists; missing keys fall through to Ruby's normal NoMethodError.
    def method_missing(method_name, *args, &block)
      method_string = method_name.to_s

      if method_string.end_with?("=") && args.size == 1
        self[method_string.chomp("=")] = args.first
      elsif args.empty? && block.nil? && key?(method_name)
        self[method_name]
      else
        super
      end
    end

    # Report method-style readers/writers as supported when applicable.
    #
    # Writers are always accepted because assigning a new context key is valid.
    # Readers are accepted only for keys currently present in the backing hash.
    #
    # @param method_name [Symbol]
    # @param include_private [Boolean]
    # @return [Boolean]
    def respond_to_missing?(method_name, include_private = false)
      method_string = method_name.to_s
      method_string.end_with?("=") || key?(method_name) || super
    end
  end
end
