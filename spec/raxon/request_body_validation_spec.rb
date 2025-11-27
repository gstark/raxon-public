require "spec_helper"
require "rack/request"
require "rack/mock"

RSpec.describe Raxon::Request, "request_body validation" do
  describe "#params with request_body" do
    it "validates request_body properties" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
        body.property :age, type: :number, required: true
      end

      json_body = JSON.generate({
        name: "John",
        age: 30
      })

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:name]).to eq("John")
      expect(result[:age]).to eq(30)
      expect(request.validation_errors).to be_nil
    end

    it "validates and coerces types in request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :count, type: :number, required: true
      end

      json_body = JSON.generate({count: "42"})

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:count]).to eq(42)
      expect(request.validation_errors).to be_nil
    end

    it "sets validation errors when request_body properties are missing" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
        body.property :email, type: :string, required: true
      end

      json_body = JSON.generate({name: "John"})

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      request.params
      expect(request.validation_errors).to have_key(:email)
    end

    it "validates nested objects in request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :user, type: :object, required: true do |user|
          user.property :name, type: :string, required: true
          user.property :age, type: :number, required: true
        end
      end

      json_body = JSON.generate({
        user: {
          name: "Jane",
          age: 25
        }
      })

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:user][:name]).to eq("Jane")
      expect(result[:user][:age]).to eq(25)
      expect(request.validation_errors).to be_nil
    end

    it "merges path parameters with request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.parameters do |params|
        params.define :id, type: :number, in: :path, required: true
      end

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
      end

      json_body = JSON.generate({name: "Updated Name"})

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
      expect(result[:name]).to eq("Updated Name")
      expect(request.validation_errors).to be_nil
    end
  end
end
