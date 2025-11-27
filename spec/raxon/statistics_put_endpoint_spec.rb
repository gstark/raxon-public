require "spec_helper"

RSpec.describe "PUT /api/v1/statistics/{id} endpoint", load_routes: true do
  let(:router) do
    Raxon::Router.new
  end

  let(:valid_statistic_params) do
    {
      statistic: {
        auto_scale: true,
        custom_max: 100,
        custom_min: 0,
        stat_type: "gauge",
        data_type: "number",
        decimal_places: 2,
        description: "A test statistic",
        equation_statistics: ["stat_1"],
        interval: "daily",
        is_private: false,
        name: "Test Statistic",
        tracking: "manual",
        upside_down: false,
        post_ids: [1, 2, 3],
        combination_statistics: ["combined_1"]
      }
    }
  end

  describe "successful request" do
    it "returns 200 with status ok for valid parameters" do
      json_body = JSON.generate(valid_statistic_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, headers, body = router.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")

      response_body = JSON.parse(body.first)
      expect(response_body).to eq({"status" => "ok for 42"})
    end

    it "handles different query parameter ID values" do
      json_body = JSON.generate(valid_statistic_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=99",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, body = router.call(env)

      expect(status).to eq(200)
      response_body = JSON.parse(body.first)
      expect(response_body["status"]).to include("99")
    end
  end

  describe "validation error responses" do
    it "returns 400 when statistic is missing" do
      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => "{}",
        "CONTENT_TYPE" => "application/json"
      )

      status, headers, body = router.call(env)

      expect(status).to eq(400)
      expect(headers["content-type"]).to eq("application/json")

      response_body = JSON.parse(body.first)
      expect(response_body["error"]).to eq("Validation failed")
      expect(response_body["details"]).to have_key("statistic")
    end

    it "returns 400 when required statistic properties are missing" do
      incomplete_params = {
        statistic: {
          name: "Incomplete Stat"
          # Missing all other required properties
        }
      }
      json_body = JSON.generate(incomplete_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, body = router.call(env)

      expect(status).to eq(400)
      response_body = JSON.parse(body.first)
      expect(response_body["error"]).to eq("Validation failed")
      expect(response_body["details"]).to have_key("statistic")
    end

    it "accepts requests with minimal valid statistic data" do
      minimal_params = {
        statistic: {
          auto_scale: false,
          custom_max: 50,
          custom_min: 10,
          stat_type: "counter",
          data_type: "integer",
          decimal_places: 0,
          description: "Minimal stat",
          equation_statistics: [],
          interval: "hourly",
          is_private: true,
          name: "Minimal",
          tracking: "automatic",
          upside_down: false,
          post_ids: [],
          combination_statistics: []
        }
      }
      json_body = JSON.generate(minimal_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=10",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, body = router.call(env)

      expect(status).to eq(200)
      response_body = JSON.parse(body.first)
      expect(response_body["status"]).to eq("ok for 10")
    end
  end

  describe "response format" do
    it "returns JSON content-type header" do
      json_body = JSON.generate(valid_statistic_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=1",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      _status, headers, _body = router.call(env)

      expect(headers["content-type"]).to eq("application/json")
    end

    it "returns valid JSON in response body" do
      json_body = JSON.generate(valid_statistic_params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=5",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      _status, _headers, body = router.call(env)

      expect { JSON.parse(body.first) }.not_to raise_error
    end
  end

  describe "request body variations" do
    it "handles arrays in equation_statistics" do
      params = valid_statistic_params.dup
      params[:statistic][:equation_statistics] = ["eq1", "eq2", "eq3"]

      json_body = JSON.generate(params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, _body = router.call(env)

      expect(status).to eq(200)
    end

    it "handles arrays in post_ids with numeric values" do
      params = valid_statistic_params.dup
      params[:statistic][:post_ids] = [10, 20, 30, 40]

      json_body = JSON.generate(params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, _body = router.call(env)

      expect(status).to eq(200)
    end

    it "handles boolean and numeric values correctly" do
      params = valid_statistic_params.dup
      params[:statistic][:auto_scale] = false
      params[:statistic][:is_private] = true
      params[:statistic][:custom_max] = 999
      params[:statistic][:decimal_places] = 5

      json_body = JSON.generate(params)

      env = Rack::MockRequest.env_for(
        "/api/v1/statistics?id=42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      status, _headers, _body = router.call(env)

      expect(status).to eq(200)
    end
  end
end
