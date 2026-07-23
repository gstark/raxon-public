# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Router, "malformed request handling" do
  def call(path, method: "GET")
    Raxon::Router.new.call(Rack::MockRequest.env_for(path, method: method))
  end

  # "a=1&a[]=2" is a conflicting parameter type (scalar then array for the same
  # key); Rack raises a Rack::BadRequest while parsing it.
  def malformed_query(path = "/api/v1/test")
    "#{path}?a=1&a[]=2"
  end

  it "returns 400 for a request Rack cannot parse", load_routes: true do
    status, headers, body = call(malformed_query)

    expect(status).to eq(400)
    expect(headers["content-type"]).to eq("application/json")
    expect(JSON.parse(body.first)).to eq("error" => "Bad Request")
  end

  it "does not route the parse error through a registered exception handler", load_routes: true do
    handled = false
    Raxon.configure do |c|
      c.rescue_from(StandardError) do |_e, _req, response, _m|
        handled = true
        response.error "handled"
      end
    end

    status, = call(malformed_query)

    expect(status).to eq(400)
    expect(handled).to be(false)
  end

  it "returns 400 on the catchall path too" do
    Raxon::RouteLoader.register_catchall do |endpoint|
      endpoint.handler do |request, response|
        request.params # forces query parsing
        response.ok ok: true
      end
    end

    status, = call(malformed_query("/no/such/route"))

    expect(status).to eq(400)
  end

  describe "413 vs 400 mapping" do
    let(:router) { Raxon::Router.new }

    it "maps a multipart part-limit breach to 413" do
      error = Rack::Multipart::MultipartPartLimitError.new("too many parts")

      status, = router.send(:malformed_request_response, error)

      expect(status).to eq(413)
    end

    it "maps a generic parse error to 400" do
      error = Rack::QueryParser::ParameterTypeError.new("bad params")

      status, = router.send(:malformed_request_response, error)

      expect(status).to eq(400)
    end
  end
end
