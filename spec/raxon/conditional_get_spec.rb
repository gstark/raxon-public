# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Conditional GET" do
  let(:router) { Raxon::Router.new }

  def call(method, path, headers = {})
    env = Rack::MockRequest.env_for(path, {method: method}.merge(headers))
    router.call(env)
  end

  describe "etag" do
    before do
      define_route("routes/users/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.etag "v1"
          response.ok users: []
        end
      end
    end

    it "sets a weak ETag header by default" do
      status, headers, body = call("GET", "/users")

      expect(status).to eq(200)
      expect(headers["etag"]).to eq('W/"v1"')
      expect(JSON.parse(body.first)).to eq({"users" => []})
    end

    it "halts with 304 when If-None-Match matches" do
      status, headers, body = call("GET", "/users", "HTTP_IF_NONE_MATCH" => 'W/"v1"')

      expect(status).to eq(304)
      expect(headers["etag"]).to eq('W/"v1"')
      expect(headers).not_to have_key("content-type")
      expect(body).to eq([])
    end

    it "uses weak comparison, ignoring the W/ prefix" do
      status, = call("GET", "/users", "HTTP_IF_NONE_MATCH" => '"v1"')

      expect(status).to eq(304)
    end

    it "matches any entry in a comma-separated If-None-Match list" do
      status, = call("GET", "/users", "HTTP_IF_NONE_MATCH" => '"v0", W/"v1"')

      expect(status).to eq(304)
    end

    it "treats * as a match" do
      status, = call("GET", "/users", "HTTP_IF_NONE_MATCH" => "*")

      expect(status).to eq(304)
    end

    it "returns the full response when If-None-Match does not match" do
      status, _, body = call("GET", "/users", "HTTP_IF_NONE_MATCH" => 'W/"v0"')

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"users" => []})
    end

    it "emits a strong ETag when weak: false" do
      define_route("routes/files/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.etag "abc123", weak: false
          response.ok
        end
      end

      _, headers, = call("GET", "/files")

      expect(headers["etag"]).to eq('"abc123"')
    end

    it "does not double-quote a pre-quoted value" do
      define_route("routes/files/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.etag '"quoted"', weak: false
          response.ok
        end
      end

      _, headers, = call("GET", "/files")

      expect(headers["etag"]).to eq('"quoted"')
    end

    it "does not halt for non-GET/HEAD requests" do
      define_route("routes/users/post.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.etag "v1"
          response.created id: 1
        end
      end

      status, headers, = call("POST", "/users", "HTTP_IF_NONE_MATCH" => 'W/"v1"')

      expect(status).to eq(201)
      expect(headers["etag"]).to eq('W/"v1"')
    end

    it "answers HEAD requests with 304 via the GET fallback" do
      status, = call("HEAD", "/users", "HTTP_IF_NONE_MATCH" => 'W/"v1"')

      expect(status).to eq(304)
    end

    it "only sets the header when the response has no request attached" do
      response = Raxon::Response.new

      returned = response.etag("v1")

      expect(returned).to eq('W/"v1"')
      expect(response.headers["etag"]).to eq('W/"v1"')
      expect(response.halted?).to be(false)
    end
  end

  describe "last_modified" do
    let(:modified_at) { Time.utc(2026, 7, 1, 12, 0, 0) }

    before do
      updated = modified_at
      define_route("routes/reports/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.last_modified updated
          response.ok report: "data"
        end
      end
    end

    it "sets the Last-Modified header" do
      status, headers, = call("GET", "/reports")

      expect(status).to eq(200)
      expect(headers["last-modified"]).to eq(modified_at.httpdate)
    end

    it "halts with 304 when the resource has not changed since If-Modified-Since" do
      status, headers, body = call("GET", "/reports", "HTTP_IF_MODIFIED_SINCE" => modified_at.httpdate)

      expect(status).to eq(304)
      expect(headers["last-modified"]).to eq(modified_at.httpdate)
      expect(body).to eq([])
    end

    it "halts with 304 when If-Modified-Since is later than the modification time" do
      status, = call("GET", "/reports", "HTTP_IF_MODIFIED_SINCE" => (modified_at + 3600).httpdate)

      expect(status).to eq(304)
    end

    it "returns the full response when the resource changed after If-Modified-Since" do
      status, _, body = call("GET", "/reports", "HTTP_IF_MODIFIED_SINCE" => (modified_at - 3600).httpdate)

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"report" => "data"})
    end

    it "ignores an unparseable If-Modified-Since value" do
      status, = call("GET", "/reports", "HTTP_IF_MODIFIED_SINCE" => "not a date")

      expect(status).to eq(200)
    end

    it "only sets the header when the response has no request attached" do
      response = Raxon::Response.new

      response.last_modified(modified_at)

      expect(response.headers["last-modified"]).to eq(modified_at.httpdate)
      expect(response.halted?).to be(false)
    end

    it "accepts values that only respond to httpdate" do
      response = Raxon::Response.new
      time = modified_at
      value = Class.new {
        define_method(:httpdate) { time.httpdate }
      }.new

      response.last_modified(value)

      expect(response.headers["last-modified"]).to eq(modified_at.httpdate)
    end
  end
end
