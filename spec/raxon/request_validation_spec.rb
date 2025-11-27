# frozen_string_literal: true

require "spec_helper"
require "rack/request"
require "rack/mock"

RSpec.describe Raxon::Request, "parameter validation" do
  describe "#params" do
    context "without endpoint schema" do
      it "returns raw rack params" do
        env = Rack::MockRequest.env_for("/test", params: {name: "test"})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request)

        expect(request.params).to eq({name: "test"})
      end
    end

    context "with endpoint schema" do
      it "validates and coerces parameters" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, required: true
          params.define :name, type: :string, required: true
        end

        env = Rack::MockRequest.env_for("/test", params: {id: "42", name: "test"})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result[:id]).to eq(42)
        expect(result[:name]).to eq("test")
        expect(request.validation_errors).to be_nil
      end

      it "sets validation errors on failure" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, required: true
        end

        env = Rack::MockRequest.env_for("/test", params: {})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        request.params
        expect(request.validation_errors).to have_key(:id)
      end

      it "returns raw params on validation failure" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, required: true
        end

        env = Rack::MockRequest.env_for("/test", params: {name: "test"})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result).to eq({name: "test"})
      end
    end

    context "with JSON body" do
      it "parses and validates JSON body parameters" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, in: :path, required: true
        end

        endpoint.request_body type: :object, required: true do |body|
          body.property :statistic, type: :object, required: true do |stat|
            stat.property :name, type: :string, required: true
            stat.property :auto_scale, type: :boolean, required: true
            stat.property :custom_max, type: :number, required: true
          end
        end

        json_body = JSON.generate({
          statistic: {
            name: "My Stat",
            auto_scale: true,
            custom_max: 100
          }
        })

        env = Rack::MockRequest.env_for(
          "/test?id=42",  # Pass id as query parameter in URL
          :method => "PUT",
          :input => json_body,
          "CONTENT_TYPE" => "application/json"
        )

        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result[:id]).to eq(42)
        expect(result[:statistic]).to eq({
          name: "My Stat",
          auto_scale: true,
          custom_max: 100
        })
        expect(request.validation_errors).to be_nil
      end

      it "handles missing nested properties" do
        endpoint = Raxon::OpenApi::Endpoint.new

        endpoint.request_body type: :object, required: true do |body|
          body.property :data, type: :object, required: true do |data|
            data.property :name, type: :string, required: true
          end
        end

        json_body = JSON.generate({data: {}})

        env = Rack::MockRequest.env_for(
          "/test",
          :method => "POST",
          :input => json_body,
          "CONTENT_TYPE" => "application/json"
        )

        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        request.params
        expect(request.validation_errors).to have_key(:data)
      end

      it "handles invalid JSON gracefully" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :name, type: :string, required: false
        end

        env = Rack::MockRequest.env_for(
          "/test",
          :method => "POST",
          :input => "invalid json",
          "CONTENT_TYPE" => "application/json"
        )

        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result).to eq({})
        expect(request.json_parse_error).to be true
      end
    end

    context "with router params" do
      it "merges router params from env" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, in: :path, required: true
        end

        env = Rack::MockRequest.env_for("/test/42")
        env["router.params"] = {id: "42"}
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result[:id]).to eq(42)
      end

      it "merges router params with JSON body" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, in: :path, required: true
        end

        endpoint.request_body type: :object, required: true do |body|
          body.property :name, type: :string, required: true
        end

        json_body = JSON.generate({name: "Test"})

        env = Rack::MockRequest.env_for(
          "/test/42",
          :method => "PUT",
          :input => json_body,
          "CONTENT_TYPE" => "application/json"
        )
        env["router.params"] = {id: "42"}

        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result[:id]).to eq(42)
        expect(result[:name]).to eq("Test")
      end
    end

    context "with optional parameters" do
      it "allows missing optional parameters" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :name, type: :string, required: true
          params.define :description, type: :string, required: false
        end

        env = Rack::MockRequest.env_for("/test", params: {name: "test"})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result = request.params
        expect(result).to eq({name: "test"})
        expect(request.validation_errors).to be_nil
      end
    end

    context "params memoization" do
      it "caches validated params" do
        endpoint = Raxon::OpenApi::Endpoint.new
        endpoint.parameters do |params|
          params.define :id, type: :number, required: true
        end

        env = Rack::MockRequest.env_for("/test", params: {id: "42"})
        rack_request = Rack::Request.new(env)
        request = Raxon::Request.new(rack_request, endpoint)

        result1 = request.params
        result2 = request.params

        expect(result1.object_id).to eq(result2.object_id)
      end
    end
  end
end
