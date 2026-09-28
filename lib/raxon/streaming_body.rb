# frozen_string_literal: true

module Raxon
  # A Rack body that produces its chunks on demand.
  #
  # {Response#stream} records a block; the Router returns this body in the Rack
  # tuple, and the block runs only when the server iterates the body with #each.
  # By then the status and headers are already on the wire, so the block can
  # take as long as it needs (an LLM completion, a long export) and every
  # +out.write+ reaches the client at once.
  #
  # The body never carries a Content-Length, so the server uses chunked
  # transfer encoding (HTTP/1.1) or framing (HTTP/2) and the client reads
  # chunks as they arrive.
  #
  # A client that closes the connection mid-stream makes the server raise from
  # the write (IOError, EPIPE, ECONNRESET). Those are swallowed here: a closed
  # tab is not an application error and must not surface in the server log as
  # one. Any other exception propagates to the server, which logs it; at that
  # point the status has been sent, so Raxon's error handling cannot answer
  # with a 500.
  class StreamingBody
    # Exceptions a server raises when the client has gone away mid-write.
    DISCONNECT_ERRORS = [IOError, Errno::EPIPE, Errno::ECONNRESET].freeze

    # The object the stream block receives. Each #write hands one chunk to the
    # server immediately.
    class Writer
      def initialize(&emit)
        @emit = emit
      end

      # Send one chunk to the client.
      #
      # @param chunk [#to_s]
      # @return [Writer] self, for chaining
      def write(chunk)
        @emit.call(chunk.to_s)
        self
      end
      alias_method :<<, :write
    end

    # @param block [Proc] Receives a {Writer}; runs inside #each
    def initialize(&block)
      raise ArgumentError, "StreamingBody requires a block" unless block

      @block = block
      @closed = false
    end

    # Run the stream block, yielding each written chunk to the server.
    #
    # @yield [String] one chunk
    # @return [void]
    def each(&emit)
      return if @closed

      @block.call(Writer.new(&emit))
    rescue *DISCONNECT_ERRORS
      # The client disconnected; there is nobody left to answer.
    ensure
      close
    end

    # Mark the body finished. Idempotent. A body closed before #each (a HEAD
    # request whose GET body is discarded) never runs the block.
    #
    # @return [void]
    def close
      @closed = true
    end

    # @return [Boolean]
    def closed?
      @closed
    end
  end
end
