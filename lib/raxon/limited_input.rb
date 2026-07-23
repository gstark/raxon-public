# frozen_string_literal: true

module Raxon
  # Wraps a Rack input stream and raises {RequestBodyTooLarge} once more than
  # +limit+ bytes have been read from it.
  #
  # The router's early Content-Length check rejects oversized bodies cheaply,
  # but a client can lie about (or omit) Content-Length, or stream a chunked
  # body with no declared length at all. This wrapper enforces the cap where it
  # cannot be evaded: at the point the bytes are actually read, whether that is
  # Raxon reading the JSON body or Rack parsing a multipart/form-encoded body.
  #
  # It satisfies the Rack input contract (+read+, +gets+, +each+, +rewind+,
  # +close+). Rewinding resets the counter because the underlying stream position
  # also returns to the start, so a rewind-and-reread is bounded by the same cap
  # rather than double-counted.
  class LimitedInput
    # @param io [#read] The underlying Rack input stream
    # @param limit [Integer] Maximum number of bytes that may be read
    def initialize(io, limit)
      @io = io
      @limit = limit
      @read = 0
    end

    # @return [String, nil]
    def read(*args)
      track(@io.read(*args))
    end

    # @return [String, nil]
    def gets(*args)
      track(@io.gets(*args))
    end

    # @yieldparam chunk [String]
    # @return [Enumerator, self]
    def each
      return enum_for(:each) unless block_given?

      @io.each do |chunk|
        track(chunk)
        yield chunk
      end
      self
    end

    # @return [Integer]
    def rewind
      result = @io.rewind
      @read = 0
      result
    end

    # @return [void]
    def close
      @io.close if @io.respond_to?(:close)
    end

    private

    # Account for a freshly read chunk and enforce the limit.
    #
    # @param chunk [String, nil]
    # @return [String, nil] the same chunk
    # @raise [RequestBodyTooLarge] when the cumulative bytes read exceed +limit+
    def track(chunk)
      return chunk if chunk.nil?

      @read += chunk.bytesize
      raise RequestBodyTooLarge if @read > @limit

      chunk
    end
  end
end
