require "spec_helper"

RSpec.describe "PUT /api/v1/test endpoint", load_routes: true do
  it "returns status ok for the given ID with valid parameters" do
    router = Raxon::Router.new

    json_body = JSON.generate({
      statistic: {
        name: "Test Stat",
        auto_scale: false,
        custom_max: 100,
        custom_min: 0,
        stat_type: "gauge",
        data_type: "number",
        decimal_places: 2,
        description: "Test",
        equation_statistics: [],
        interval: "daily",
        is_private: false,
        tracking: "manual",
        upside_down: false,
        post_ids: [],
        combination_statistics: []
      }
    })

    env = Rack::MockRequest.env_for(
      "/api/v1/test",
      :method => "PUT",
      :input => json_body,
      "CONTENT_TYPE" => "application/json"
    )
    # Set the router params to simulate path parameter extraction
    env["router.params"] = {id: "42"}

    status, headers, body = router.call(env)

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")

    response_body = JSON.parse(body.first)
    expect(response_body).to eq({"status" => "ok for 42"})
  end

  it "validates and coerces parameters with JSON body" do
    router = Raxon::Router.new

    json_body = JSON.generate({
      statistic: {
        name: "Test Statistic",
        auto_scale: true,
        custom_max: 100,
        custom_min: 0,
        stat_type: "gauge",
        data_type: "number",
        decimal_places: 2,
        description: "A test statistic",
        equation_statistics: [],
        interval: "daily",
        is_private: false,
        tracking: "manual",
        upside_down: false,
        post_ids: [],
        combination_statistics: []
      }
    })

    env = Rack::MockRequest.env_for(
      "/api/v1/test",
      :method => "PUT",
      :input => json_body,
      "CONTENT_TYPE" => "application/json"
    )
    env["router.params"] = {id: "42"}

    status, headers, body = router.call(env)

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")

    response_body = JSON.parse(body.first)
    # ID should be coerced to integer (42) by dry-schema
    expect(response_body).to eq({"status" => "ok for 42"})
  end

  it "returns 400 for missing required fields" do
    router = Raxon::Router.new

    # Missing the required 'statistic' parameter
    env = Rack::MockRequest.env_for("/api/v1/test", method: "PUT")
    env["router.params"] = {id: "42"}

    status, headers, body = router.call(env)

    # Now returns 400 with validation error details
    expect(status).to eq(400)
    expect(headers["content-type"]).to eq("application/json")

    response_body = JSON.parse(body.first)
    expect(response_body["error"]).to eq("Validation failed")
    expect(response_body["details"]).to have_key("statistic")
  end

  it "returns 400 for invalid nested object properties" do
    router = Raxon::Router.new

    # Partial statistic object - missing required fields
    json_body = JSON.generate({
      statistic: {
        name: "Partial Stat"
        # Missing auto_scale, custom_max, custom_min, etc.
      }
    })

    env = Rack::MockRequest.env_for(
      "/api/v1/test",
      :method => "PUT",
      :input => json_body,
      "CONTENT_TYPE" => "application/json"
    )
    env["router.params"] = {id: "42"}

    status, headers, body = router.call(env)

    # Now returns 400 with validation error details
    expect(status).to eq(400)
    expect(headers["content-type"]).to eq("application/json")

    response_body = JSON.parse(body.first)
    expect(response_body["error"]).to eq("Validation failed")
    expect(response_body["details"]).to have_key("statistic")
  end

  it "validates complete response body as string for missing fields" do
    router = Raxon::Router.new

    # Missing the required 'statistic' parameter
    env = Rack::MockRequest.env_for("/api/v1/test", method: "PUT")
    env["router.params"] = {id: "42"}

    _status, _headers, body = router.call(env)

    # Validate the entire response body as a JSON string
    response_json = body.first

    expect(response_json).to eq <<~EOF.chomp
      {"error":"Validation failed","details":{"statistic":["is missing"]}}
    EOF
  end
end
