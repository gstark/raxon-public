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

RSpec.describe Raxon::RequestContext, "hash-like API" do
  let(:context) { described_class.new(user: "alice", role: "admin") }

  describe "#fetch" do
    it "returns stored values and normalizes string keys" do
      expect(context.fetch(:user)).to eq("alice")
      expect(context.fetch("user")).to eq("alice")
    end

    it "supports defaults and fallback blocks like Hash#fetch" do
      expect(context.fetch(:missing, "default")).to eq("default")
      expect(context.fetch(:missing) { |key| "no #{key}" }).to eq("no missing")
    end

    it "raises KeyError when the key is missing and no fallback is given" do
      expect { context.fetch(:missing) }.to raise_error(KeyError)
    end
  end

  describe "#delete" do
    it "removes the value and returns it" do
      expect(context.delete("user")).to eq("alice")
      expect(context.key?(:user)).to be(false)
    end

    it "returns nil for absent keys" do
      expect(context.delete(:missing)).to be_nil
    end
  end

  describe "#each" do
    it "yields key/value pairs and returns the context" do
      seen = {}

      result = context.each { |key, value| seen[key] = value }

      expect(seen).to eq(user: "alice", role: "admin")
      expect(result).to be(context)
    end

    it "returns an enumerator when no block is given" do
      expect(context.each).to be_a(Enumerator)
      expect(context.each.to_a).to eq([[:user, "alice"], [:role, "admin"]])
    end

    it "supports Enumerable methods" do
      expect(context.map { |key, _value| key }).to eq([:user, :role])
    end
  end

  describe "#empty?, #keys, #values" do
    it "reflects the stored data" do
      expect(context.empty?).to be(false)
      expect(context.keys).to eq([:user, :role])
      expect(context.values).to eq(["alice", "admin"])
      expect(described_class.new.empty?).to be(true)
    end
  end

  describe "#dup" do
    it "copies the data so writes do not leak back to the original" do
      copy = context.dup
      copy[:user] = "bob"

      expect(copy[:user]).to eq("bob")
      expect(context[:user]).to eq("alice")
    end
  end

  describe "method-style access edge cases" do
    it "raises NoMethodError for missing keys to catch typos" do
      expect { context.curent_user }.to raise_error(NoMethodError)
      expect(context.respond_to?(:curent_user)).to be(false)
    end

    it "raises NoMethodError for reader calls with arguments" do
      expect { context.user("extra") }.to raise_error(NoMethodError)
    end
  end
end
