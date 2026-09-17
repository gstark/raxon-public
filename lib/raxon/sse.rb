# frozen_string_literal: true

module Raxon
  # Formats Server-Sent Events onto a streaming writer.
  #
  # {Response#sse} yields one of these. Each call writes a complete event
  # (terminated by a blank line) so the client's EventSource dispatches it at
  # once. Payloads that are not already a String are JSON-encoded; a String is
  # sent as-is, split across +data:+ lines at each newline as the protocol
  # requires.
  #
  # @example
  #   response.sse do |events|
  #     events.event("token", {text: "Hel"})
  #     events.event("token", {text: "lo"})
  #     events.event("done", {})
  #   end
  #
  #   # On the wire:
  #   #   event: token
  #   #   data: {"text":"Hel"}
  #   #
  #   #   event: token
  #   #   data: {"text":"lo"}
  #   #
  #   #   event: done
  #   #   data: {}
  #   #
  class SSE
    # @param out [#write] The stream writer (see {StreamingBody::Writer})
    def initialize(out)
      @out = out
    end

    # Write one event.
    #
    # @param type [String, Symbol, nil] The event name; nil sends an unnamed
    #   event, which EventSource delivers to its +message+ listener
    # @param data [Object] Payload; JSON-encoded unless it is a String
    # @param id [String, Integer, nil] Optional event id for Last-Event-ID resumption
    # @param retry_ms [Integer, nil] Optional reconnection delay hint
    # @return [SSE] self, for chaining
    def event(type, data, id: nil, retry_ms: nil)
      lines = []
      lines << "id: #{id}" unless id.nil?
      lines << "event: #{type}" unless type.nil?
      lines << "retry: #{retry_ms}" unless retry_ms.nil?
      encode(data).split("\n", -1).each { |line| lines << "data: #{line}" }

      @out.write("#{lines.join("\n")}\n\n")
      self
    end

    # Write an unnamed event (delivered to EventSource's +message+ listener).
    #
    # @param data [Object] Payload; JSON-encoded unless it is a String
    # @param id [String, Integer, nil] Optional event id
    # @return [SSE] self
    def data(data, id: nil)
      event(nil, data, id: id)
    end

    # Write a comment line. Clients ignore it; send one periodically to keep an
    # idle connection open through proxies and load balancers.
    #
    # @param text [String] Comment text (default: empty, a bare keepalive)
    # @return [SSE] self
    def comment(text = "")
      @out.write(": #{text}\n\n")
      self
    end

    private

    def encode(data)
      data.is_a?(String) ? data : JSON.generate(data)
    end
  end
end
