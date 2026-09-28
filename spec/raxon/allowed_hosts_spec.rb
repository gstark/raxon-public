# frozen_string_literal: true

require "spec_helper"

RSpec.describe "config.allowed_hosts", load_routes: true do
  def status_for(url, **headers)
    Raxon::Router.new.call(Rack::MockRequest.env_for(url, headers)).first
  end

  it "answers any host when unset" do
    expect(status_for("http://anything.test/api/v1/nothing")).to eq(404)
  end

  it "answers 403 for a host outside the list" do
    Raxon.configuration.allowed_hosts = ["api.example.com"]

    status, headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("http://evil.test/x"))

    expect(status).to eq(403)
    expect(headers["content-type"]).to eq("application/json")
    expect(body.join).to eq(%({"error":"Blocked host"}))
  end

  it "matches a String exactly, ignoring case" do
    Raxon.configuration.allowed_hosts = ["API.example.com"]

    expect(status_for("http://api.example.com/x")).to eq(404)
    expect(status_for("http://www.api.example.com/x")).to eq(403)
  end

  it "matches a domain and its subdomains with a leading dot" do
    Raxon.configuration.allowed_hosts = [".example.com"]

    expect(status_for("http://example.com/x")).to eq(404)
    expect(status_for("http://a.b.example.com/x")).to eq(404)
    expect(status_for("http://badexample.com/x")).to eq(403)
  end

  it "requires a Regexp to match the whole host" do
    Raxon.configuration.allowed_hosts = [/[a-z]+\.example\.com/]

    expect(status_for("http://api.example.com/x")).to eq(404)
    expect(status_for("http://api.example.com.evil.test/x")).to eq(403)
  end

  it "ignores X-Forwarded-Host from a peer that is not a trusted proxy" do
    Raxon.configuration.allowed_hosts = ["api.example.com"]

    expect(status_for("http://evil.test/x", "HTTP_X_FORWARDED_HOST" => "api.example.com")).to eq(403)
  end

  it "reads X-Forwarded-Host from a trusted proxy" do
    Raxon.configuration.allowed_hosts = ["api.example.com"]
    Raxon.configuration.trusted_proxies = ["10.0.0.0/8"]

    status = status_for("http://internal/x", "REMOTE_ADDR" => "10.0.0.2", "HTTP_X_FORWARDED_HOST" => "api.example.com")

    expect(status).to eq(404)
  end
end
