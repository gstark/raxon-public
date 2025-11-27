# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Invalid JSON handling" do
  it "returns 400 Bad Request when invalid JSON is sent with application/json content type" do
    Raxon::RouteLoader.register("routes/test/post.rb") do |endpoint|
      endpoint.parameters do |params|
        params.define :name, type: :string, required: true
      end
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {success: true}
      end
    end

    env = Rack::MockRequest.env_for(
      "/test",
      :method => "POST",
      :input => "this is not valid json {",
      "CONTENT_TYPE" => "application/json"
    )

    status, headers, body = Raxon::Router.new.call(env)

    expect(status).to eq(400)
    expect(headers["content-type"]).to eq("application/json")

    parsed_body = JSON.parse(body.first)
    expect(parsed_body["error"]).to eq("Invalid JSON in request body")
    expect(parsed_body.keys).to eq(["error"])
  end

  it "does not return 400 for valid JSON" do
    Raxon::RouteLoader.register("routes/test/post.rb") do |endpoint|
      endpoint.parameters do |params|
        params.define :name, type: :string, required: true
      end
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {success: true}
      end
    end

    env = Rack::MockRequest.env_for(
      "/test",
      :method => "POST",
      :input => JSON.generate({name: "test"}),
      "CONTENT_TYPE" => "application/json"
    )

    status, _headers, _body = Raxon::Router.new.call(env)

    expect(status).to eq(200)
  end

  it "does not return 400 for empty JSON body" do
    Raxon::RouteLoader.register("routes/test/post.rb") do |endpoint|
      endpoint.parameters do |params|
        params.define :name, type: :string, required: false
      end
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {success: true}
      end
    end

    env = Rack::MockRequest.env_for(
      "/test",
      :method => "POST",
      :input => "",
      "CONTENT_TYPE" => "application/json"
    )
    status, _headers, _body = Raxon::Router.new.call(env)

    expect(status).to eq(200)
  end

  it "does not return 400 when content type is not application/json" do
    Raxon::RouteLoader.register("routes/test/post.rb") do |endpoint|
      endpoint.handler do |request, response|
        response.code = :ok
        response.body = {success: true}
      end
    end

    env = Rack::MockRequest.env_for(
      "/test",
      :method => "POST",
      :input => "this is not json",
      "CONTENT_TYPE" => "text/plain"
    )

    status, _headers, _body = Raxon::Router.new.call(env)

    expect(status).to eq(200)
  end
end
