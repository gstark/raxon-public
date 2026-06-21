# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::RequestContext do
  it "supports hash-style access with symbolized keys" do
    context = described_class.new

    context[:current_user] = "alice"
    context["request_id"] = "req-1"

    expect(context[:current_user]).to eq("alice")
    expect(context["current_user"]).to eq("alice")
    expect(context.request_id).to eq("req-1")
    expect(context.to_h).to eq(current_user: "alice", request_id: "req-1")
  end

  it "supports method-style readers and writers" do
    context = described_class.new

    context.current_user = "alice"

    expect(context.current_user).to eq("alice")
    expect(context[:current_user]).to eq("alice")
    expect(context).to respond_to(:current_user)
    expect(context).to respond_to(:current_user=)
  end
end

RSpec.describe "request context lifecycle integration" do
  def call_route(path, method: "GET")
    env = Rack::MockRequest.env_for(path, method: method)
    Raxon::Router.new.call(env)
  end

  it "shares request.context across metadata, before, handler, and after blocks" do
    events = []

    define_route("routes/api/all.rb") do |endpoint|
      endpoint.metadata do |request, _response, metadata|
        request.context[:request_id] = "req-1"
        metadata[:metadata_value] = "from metadata"
        events << [:metadata, request.context.request_id]
      end

      endpoint.before do |request, _response, metadata|
        request.context.current_user = "alice"
        events << [:before, metadata[:request_id], request.context.metadata_value]
      end

      endpoint.after do |request, _response, metadata|
        events << [:after, request.context[:handler_seen_user], metadata[:after_value]]
      end
    end

    define_route("routes/api/users/get.rb") do |endpoint|
      endpoint.handler do |request, response, metadata|
        request.context[:handler_seen_user] = request.context.current_user
        metadata[:after_value] = "available to after"
        events << [:handler, metadata[:current_user], request.context.metadata_value]
        response.body = {ok: true}
      end
    end

    status, = call_route("/api/users")

    expect(status).to eq(200)
    expect(events).to eq([
      [:metadata, "req-1"],
      [:before, "req-1", "from metadata"],
      [:handler, "alice", "from metadata"],
      [:after, "alice", "available to after"]
    ])
  end

  it "keeps the metadata argument compatible as the same backing hash" do
    observed = []

    define_route("routes/test/get.rb") do |endpoint|
      endpoint.metadata do |request, _response, metadata|
        metadata[:via_metadata] = true
        request.context[:via_context] = true
        observed << metadata.class
        observed << metadata.dup
      end

      endpoint.handler do |request, response, metadata|
        observed << metadata.object_id
        observed << request.context.to_h.object_id
        observed << metadata.dup
        response.body = {ok: true}
      end
    end

    status, = call_route("/test")

    expect(status).to eq(200)
    expect(observed[0]).to eq(Hash)
    expect(observed[1]).to eq(via_metadata: true, via_context: true)
    expect(observed[2]).to eq(observed[3])
    expect(observed[4]).to eq(via_metadata: true, via_context: true)
  end
end
