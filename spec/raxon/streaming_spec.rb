# frozen_string_literal: true

require "spec_helper"
require "raxon/test"

RSpec.describe Raxon::StreamingBody do
  def drain(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    chunks
  end

  it "requires a block" do
    expect { described_class.new }.to raise_error(ArgumentError, /block/)
  end

  it "runs the block only when iterated and yields each written chunk" do
    ran = false
    body = described_class.new do |out|
      ran = true
      out.write("a")
      out << "b"
      out.write(3)
    end

    expect(ran).to be(false)
    expect(drain(body)).to eq(%w[a b 3])
    expect(ran).to be(true)
  end

  it "closes after each, even when the block raises" do
    body = described_class.new { |_out| raise "boom" }

    expect { body.each { |_chunk| } }.to raise_error(RuntimeError, "boom")
    expect(body).to be_closed
  end

  it "does not run the block when closed before each" do
    ran = false
    body = described_class.new { |_out| ran = true }

    body.close
    expect(drain(body)).to eq([])
    expect(ran).to be(false)
  end

  [IOError, Errno::EPIPE, Errno::ECONNRESET].each do |error_class|
    it "swallows #{error_class} raised by the server write" do
      body = described_class.new do |out|
        out.write("first")
        out.write("second")
      end

      seen = []
      expect do
        body.each do |chunk|
          seen << chunk
          raise error_class, "client went away"
        end
      end.not_to raise_error

      expect(seen).to eq(["first"])
      expect(body).to be_closed
    end
  end
end

RSpec.describe Raxon::SSE do
  let(:chunks) { [] }
  let(:out) { Raxon::StreamingBody::Writer.new { |chunk| chunks << chunk } }
  let(:sse) { described_class.new(out) }

  it "formats a named event with a JSON-encoded payload" do
    sse.event("token", {text: "hi"})

    expect(chunks).to eq(["event: token\ndata: {\"text\":\"hi\"}\n\n"])
  end

  it "sends a String payload as-is" do
    sse.event("log", "plain text")

    expect(chunks).to eq(["event: log\ndata: plain text\n\n"])
  end

  it "splits a multi-line String across data lines" do
    sse.event("log", "line one\nline two\n")

    expect(chunks).to eq(["event: log\ndata: line one\ndata: line two\ndata: \n\n"])
  end

  it "emits id and retry fields when given" do
    sse.event("tick", {n: 1}, id: 42, retry_ms: 5000)

    expect(chunks).to eq(["id: 42\nevent: tick\nretry: 5000\ndata: {\"n\":1}\n\n"])
  end

  it "writes an unnamed event with data" do
    sse.data([1, 2])

    expect(chunks).to eq(["data: [1,2]\n\n"])
  end

  it "writes a comment keepalive" do
    sse.comment
    sse.comment("ping")

    expect(chunks).to eq([": \n\n", ": ping\n\n"])
  end

  it "chains" do
    sse.event("a", 1).event("b", 2)

    expect(chunks.length).to eq(2)
  end
end

RSpec.describe Raxon::Response, "#stream" do
  def drain(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    body.close if body.respond_to?(:close)
    chunks
  end

  it "requires a block" do
    expect { described_class.new.stream(content_type: "text/plain") }.to raise_error(ArgumentError)
  end

  it "refuses to stream when a body is already set" do
    response = described_class.new
    response.body = {a: 1}

    expect { response.stream(content_type: "text/plain") { |_out| } }
      .to raise_error(Raxon::Error, /already has a body/)
  end

  it "marks the response as streaming and sets the content type" do
    response = described_class.new
    expect(response).not_to be_streaming

    response.stream(content_type: "text/plain") { |_out| }

    expect(response).to be_streaming
    expect(response.headers["content-type"]).to eq("text/plain")
  end

  it "returns a StreamingBody from to_rack with no content-length" do
    response = described_class.new
    response.code = :accepted
    response.header "x-thing", "1"
    response.stream(content_type: "text/plain") { |out| out.write("chunk") }

    status, headers, body = response.to_rack

    expect(status).to eq(202)
    expect(headers).to eq({"content-type" => "text/plain", "x-thing" => "1"})
    expect(headers).not_to have_key("content-length")
    expect(body).to be_a(Raxon::StreamingBody)
    expect(drain(body)).to eq(["chunk"])
  end

  it "keeps cookies and drops the content-length when a Rack::Response was created" do
    response = described_class.new
    response.set_cookie "sid", value: "abc", path: "/"
    response.write "buffered"  # sets a content-length on the Rack::Response
    response.stream(content_type: "text/plain") { |out| out.write("streamed") }

    _status, headers, body = response.to_rack

    expect(headers["set-cookie"]).to include("sid=abc")
    expect(headers["content-type"]).to eq("text/plain")
    expect(headers).not_to have_key("content-length")
    expect(drain(body)).to eq(["streamed"])
  end

  it "#sse sets the event-stream headers and yields an SSE writer" do
    response = described_class.new
    response.sse { |events| events.event("done", {ok: true}) }

    _status, headers, body = response.to_rack

    expect(headers["content-type"]).to eq("text/event-stream")
    expect(headers["cache-control"]).to eq("no-cache")
    expect(drain(body)).to eq(["event: done\ndata: {\"ok\":true}\n\n"])
  end
end

RSpec.describe "streaming through the Router" do
  def drain(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    body.close if body.respond_to?(:close)
    chunks
  end

  it "streams chunks written by the handler, after the after blocks ran" do
    order = []

    define_route("routes/stream/get.rb") do |endpoint|
      endpoint.handler do |_request, response|
        response.stream(content_type: "text/plain") do |out|
          order << :stream
          out.write("one")
          out.write("two")
        end
      end
      endpoint.after do |_request, response|
        order << :after
        response.header "x-after", "yes"
      end
    end

    status, headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/stream"))

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/plain")
    expect(headers["x-after"]).to eq("yes")
    expect(headers).not_to have_key("content-length")
    expect(order).to eq([:after])
    expect(drain(body)).to eq(%w[one two])
    expect(order).to eq([:after, :stream])
  end

  it "ignores the return value of a handle block that streamed" do
    define_route("routes/stream/get.rb") do |endpoint|
      endpoint.response 200, content_type: "text/event-stream"
      endpoint.handle do |_request, response|
        response.sse { |events| events.event("done", {}) }
        {this: "is not the body"}
      end
    end

    status, headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/stream"))

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/event-stream")
    expect(drain(body)).to eq(["event: done\ndata: {}\n\n"])
  end

  it "skips response validation for a streaming response" do
    Raxon.configure { |config| config.response_validation = :raise }

    define_route("routes/stream/get.rb") do |endpoint|
      endpoint.response 200, type: :object do |r|
        r.property :must_have, type: :string
      end
      endpoint.handler do |_request, response|
        response.stream(content_type: "text/plain") { |out| out.write("x") }
      end
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/stream"))

    expect(status).to eq(200)
    expect(drain(body)).to eq(["x"])
  end

  it "answers HEAD with the stream headers and never runs the block" do
    ran = false

    define_route("routes/stream/get.rb") do |endpoint|
      endpoint.handler do |_request, response|
        response.stream(content_type: "text/plain") do |out|
          ran = true
          out.write("x")
        end
      end
    end

    status, headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/stream", method: "HEAD"))

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("text/plain")
    expect(body).to eq([])
    expect(ran).to be(false)
  end

  it "reads a streamed body through Raxon::Test" do
    define_route("routes/stream/get.rb") do |endpoint|
      endpoint.handler do |_request, response|
        response.sse do |events|
          events.event("token", {text: "a"})
          events.event("token", {text: "b"})
        end
      end
    end

    client = Object.new.extend(Raxon::Test::Methods)
    result = client.get("/stream")

    expect(result.status).to eq(200)
    expect(result.headers["content-type"]).to eq("text/event-stream")
    expect(result.body).to eq("event: token\ndata: {\"text\":\"a\"}\n\nevent: token\ndata: {\"text\":\"b\"}\n\n")
  end
end
