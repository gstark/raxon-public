# frozen_string_literal: true

require "spec_helper"

# These specs drive endpoint invocation through its seam: a handler endpoint, a
# hierarchy, a request double, and a real Response. The request-validation,
# dispatch, response-validation, and lifecycle-ordering rules live here and are
# tested here — no Rack env, no Router, no full app boot.
RSpec.describe Raxon::EndpointInvocation do
  # A request double standing in for Raxon::Request. endpoint_context returns nil
  # so blocks run via plain #call (no route-file context needed).
  def fake_request(params: {}, json_parse_error: false, validation_errors: nil)
    double(
      "request",
      params: params,
      json_parse_error: json_parse_error,
      validation_errors: validation_errors
    ).tap { |r| allow(r).to receive(:endpoint_context).and_return(nil) }
  end

  def run(handler_endpoint, endpoints: nil, request: fake_request, response: Raxon::Response.new, metadata: {})
    described_class.new(handler_endpoint, endpoints || [handler_endpoint]).run(request, response, metadata)
    response
  end

  describe "request validation" do
    it "returns 400 without running the handler when the JSON body is unparseable" do
      ran = false
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.handler { |_req, _res, _meta| ran = true }

      response = run(endpoint, request: fake_request(json_parse_error: true))

      expect(response.status_code).to eq(400)
      expect(response.body).to eq(error: "Invalid JSON in request body")
      expect(ran).to be(false)
    end

    it "returns 400 with details without running the handler when validation fails" do
      ran = false
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.handler { |_req, _res, _meta| ran = true }

      response = run(endpoint, request: fake_request(validation_errors: {id: ["is missing"]}))

      expect(response.status_code).to eq(400)
      expect(response.body).to eq(error: "Validation failed", details: {id: ["is missing"]})
      expect(ran).to be(false)
    end
  end

  describe "handler dispatch" do
    it "runs the handler on a valid request" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.handler { |req, res, _meta| res.body = {echo: req.params[:name]} }

      response = run(endpoint, request: fake_request(params: {name: "Ada"}))

      expect(response.body).to eq(echo: "Ada")
    end

    it "does nothing for an endpoint with no handler" do
      endpoint = Raxon::OpenApi::Endpoint.new
      response = run(endpoint)

      expect(response.body).to be_nil
    end
  end

  describe "response validation" do
    it "rewrites a schema-violating response to 500 (error_response mode)" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object do |resp|
        resp.property :id, type: :integer, required: true
      end
      endpoint.handler do |_req, res, _meta|
        res.code = :ok
        res.body = {wrong: "field"} # missing required :id
      end

      response = run(endpoint)

      expect(response.status_code).to eq(500)
      expect(response.body[:error]).to eq("Response validation failed")
      expect(response.body[:status_code]).to eq(200)
    end

    it "leaves a schema-conforming response untouched" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.response 200, type: :object do |resp|
        resp.property :id, type: :integer, required: true
      end
      endpoint.handler do |_req, res, _meta|
        res.code = :ok
        res.body = {id: 7}
      end

      response = run(endpoint)

      expect(response.status_code).to eq(200)
      expect(response.body).to eq(id: 7)
    end
  end

  describe "lifecycle ordering across a hierarchy" do
    it "runs metadata and before parent→child, the handler, then after child→parent" do
      order = []
      parent = Raxon::OpenApi::Endpoint.new
      parent.metadata { |_req, _res, _meta| order << :parent_metadata }
      parent.before { |_req, _res, _meta| order << :parent_before }
      parent.after { |_req, _res, _meta| order << :parent_after }

      child = Raxon::OpenApi::Endpoint.new
      child.metadata { |_req, _res, _meta| order << :child_metadata }
      child.before { |_req, _res, _meta| order << :child_before }
      child.after { |_req, _res, _meta| order << :child_after }
      child.handler { |_req, _res, _meta| order << :handler }

      run(child, endpoints: [parent, child])

      expect(order).to eq([
        :parent_metadata, :child_metadata,
        :parent_before, :child_before,
        :handler,
        :child_after, :parent_after
      ])
    end

    it "lets a before block halt, skipping the handler and after blocks" do
      ran_handler = false
      ran_after = false
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.before { |_req, res, _meta| res.halt(code: :forbidden) }
      endpoint.handler { |_req, _res, _meta| ran_handler = true }
      endpoint.after { |_req, _res, _meta| ran_after = true }

      response = Raxon::Response.new
      expect {
        described_class.new(endpoint, [endpoint]).run(fake_request, response, {})
      }.to raise_error(Raxon::HaltException)

      expect(ran_handler).to be(false)
      expect(ran_after).to be(false)
    end
  end
end
