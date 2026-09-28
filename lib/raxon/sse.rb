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
    # @raise [ArgumentError] when +type+ or +id+ holds CR or LF, +id+ holds
    #   NUL, or +retry_ms+ is not an Integer
    def event(type, data, id: nil, retry_ms: nil)
      lines = []
      lines << "id: #{single_line(id, "id", nul: true)}" unless id.nil?
      lines << "event: #{single_line(type, "event name")}" unless type.nil?
      unless retry_ms.nil?
        raise ArgumentError, "SSE retry must be an Integer" unless retry_ms.is_a?(Integer)

        lines << "retry: #{retry_ms}"
      end
      # EventSource ends a line at CR, LF, or CRLF, so split at all three.
      encode(data).split(LINE_BREAK, -1).each { |line| lines << "data: #{line}" }

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
    # @raise [ArgumentError] when +text+ holds CR or LF
    def comment(text = "")
      @out.write(": #{single_line(text, "comment")}\n\n")
      self
    end

    # CR, LF, and CRLF each end a line in an event stream.
    LINE_BREAK = /\r\n|\r|\n/

    private

    # A value with CR or LF would end its field line early, and the text
    # after it would be read as new fields, or as a complete forged event.
    #
    # @return [String]
    # @raise [ArgumentError]
    def single_line(value, field, nul: false)
      text = value.to_s
      raise ArgumentError, "SSE #{field} must not contain CR or LF" if text.match?(/[\r\n]/)
      # The protocol ignores an id that holds NUL.
      raise ArgumentError, "SSE #{field} must not contain NUL" if nul && text.include?("\0")

      text
    end

    def encode(data)
      data.is_a?(String) ? data : Raxon::JSONEncoder.generate(data)
    end
  end
end
