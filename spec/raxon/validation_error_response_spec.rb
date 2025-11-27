# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Automatic validation error responses" do
  describe "400 Bad Request on validation failure" do
    context "with missing required parameters", load_routes: true do
      it "returns 400 with error details", load_routes: true do
        router = Raxon::Router.new

        # Missing required 'statistic' parameter
        env = Rack::MockRequest.env_for("/api/v1/test", method: "PUT")
        env["router.params"] = {id: "42"}

        status, headers, body = router.call(env)

        expect(status).to eq(400)
        expect(headers["content-type"]).to eq("application/json")

        response_body = JSON.parse(body.first)
        expect(response_body["error"]).to eq("Validation failed")
        expect(response_body["details"]).to have_key("statistic")
      end

      it "returns 400 when required path parameter is missing" do
        router = Raxon::Router.new

        # Missing required 'id' parameter
        env = Rack::MockRequest.env_for("/api/v1/test", method: "PUT")

        status, headers, body = router.call(env)

        expect(status).to eq(400)
        expect(headers["content-type"]).to eq("application/json")

        response_body = JSON.parse(body.first)
        expect(response_body["error"]).to eq("Validation failed")
        expect(response_body["details"]).to have_key("id")
      end
    end

    context "with missing nested required properties", load_routes: true do
      it "returns 400 with nested property errors" do
        router = Raxon::Router.new

        # Statistic object missing required properties
        json_body = JSON.generate({
          statistic: {
            name: "Incomplete Stat"
            # Missing auto_scale, custom_max, etc.
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

        expect(status).to eq(400)
        expect(headers["content-type"]).to eq("application/json")

        response_body = JSON.parse(body.first)
        expect(response_body["error"]).to eq("Validation failed")
        expect(response_body["details"]).to have_key("statistic")
      end
    end

    context "with valid parameters", load_routes: true do
      it "does not return 400 and executes handler normally" do
        router = Raxon::Router.new

        json_body = JSON.generate({
          statistic: {
            name: "Valid Stat",
            auto_scale: true,
            custom_max: 100,
            custom_min: 0,
            stat_type: "gauge",
            data_type: "number",
            decimal_places: 2,
            description: "A valid statistic",
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
        expect(response_body).to eq({"status" => "ok for 42"})
      end
    end

    context "with endpoint without validation" do
      it "executes handler normally without validation" do
        # Create a simple endpoint without parameter validation
        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.handler do |request, response|
            response.code = :ok
            response.body = {message: "No validation"}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        status, headers, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(headers["content-type"]).to eq("application/json")

        response_body = JSON.parse(body.first)
        expect(response_body).to eq({"message" => "No validation"})
      end
    end
  end

  describe "validation error details format", load_routes: true do
    it "provides detailed error messages for each invalid field" do
      router = Raxon::Router.new

      # Completely empty request
      env = Rack::MockRequest.env_for("/api/v1/test", method: "PUT")

      status, _headers, body = router.call(env)

      expect(status).to eq(400)

      response_body = JSON.parse(body.first)
      expect(response_body["error"]).to eq("Validation failed")
      expect(response_body["details"]).to be_a(Hash)

      # Should have errors for both id and statistic
      expect(response_body["details"].keys).to include("id", "statistic")
    end

    it "includes nested path in error details", load_routes: true do
      router = Raxon::Router.new

      # Empty statistic object
      json_body = JSON.generate({
        statistic: {}
      })

      env = Rack::MockRequest.env_for(
        "/api/v1/test",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      env["router.params"] = {id: "42"}

      status, _headers, body = router.call(env)

      expect(status).to eq(400)

      response_body = JSON.parse(body.first)
      # The error details should indicate the statistic object has validation errors
      expect(response_body["details"]).to have_key("statistic")
    end
  end
end
