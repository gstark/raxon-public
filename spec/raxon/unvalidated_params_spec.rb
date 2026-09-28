# frozen_string_literal: true

require "spec_helper"

RSpec.describe "request.params before the handler" do
  it "is empty in metadata blocks, before blocks, and authenticators when validation fails" do
    seen = {}
    Raxon::OpenApi::DSL.security_scheme(:key, type: :apiKey, name: "X-Key", in: :header) do |request, _metadata|
      seen[:authenticator] = request.params
      true
    end

    define_route("routes/widgets/get.rb") do |endpoint|
      endpoint.security :key
      endpoint.query_param :count, type: :integer, required: true
      endpoint.metadata { |request, _response, _metadata| seen[:metadata] = request.params }
      endpoint.before { |request, _response, _metadata| seen[:before] = request.params }
      endpoint.handler { |_request, response, _metadata| response.ok({}) }
    end

    status, = Raxon::Router.new.call(Rack::MockRequest.env_for("/widgets?count=abc&admin=1"))

    expect(status).to eq(400)
    expect(seen).to eq(metadata: {}, authenticator: {}, before: {})
  end

  it "is the validated params in a before block when validation passes" do
    seen = nil
    define_route("routes/widgets/get.rb") do |endpoint|
      endpoint.query_param :count, type: :integer, required: true
      endpoint.before { |request, _response, _metadata| seen = request.params }
      endpoint.handler { |_request, response, _metadata| response.ok({}) }
    end

    Raxon::Router.new.call(Rack::MockRequest.env_for("/widgets?count=3&admin=1"))

    expect(seen).to eq(count: 3)
  end
end
