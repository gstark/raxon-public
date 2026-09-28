# frozen_string_literal: true

require "spec_helper"
require "rack/mock"

RSpec.describe Raxon::Request, "top-level array request body" do
  def request_for(endpoint, json)
    env = Rack::MockRequest.env_for("/items", :method => "POST", :input => json, "CONTENT_TYPE" => "application/json")
    Raxon::Request.new(Rack::Request.new(env), endpoint).tap(&:params)
  end

  it "validates each scalar item and exposes the array as params[:body]" do
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :array, of: :integer

    good = request_for(endpoint, "[1, 2]")
    bad = request_for(endpoint, '[1, "x"]')

    expect(good.validation_errors).to be_nil
    expect(good.params).to eq(body: [1, 2])
    expect(bad.validation_errors).to eq(body: {1 => ["must be an integer"]})
  end

  it "validates items declared with properties and drops undeclared item keys" do
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :array, of: :object do |body|
      body.property :name, type: :string
    end

    good = request_for(endpoint, '[{"name": "Ada", "admin": true}]')
    bad = request_for(endpoint, "[{}]")

    expect(good.params).to eq(body: [{name: "Ada"}])
    expect(bad.validation_errors).to eq(body: {0 => {name: ["is missing"]}})
  end

  it "validates items against a component named by of:" do
    Raxon::OpenApi::DSL.component(:Widget, type: :object) do |component|
      component.property :id, type: :integer, read_only: true
      component.property :label, type: :string
    end
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :array, of: :Widget

    good = request_for(endpoint, '[{"id": 9, "label": "a"}]')
    bad = request_for(endpoint, '[{"label": 5}]')

    expect(good.params).to eq(body: [{label: "a"}])
    expect(bad.validation_errors).to eq(body: {0 => {label: ["must be a string"]}})
  end

  it "rejects an object where an array is declared" do
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :array, of: :string

    expect(request_for(endpoint, '{"a": 1}').validation_errors).to have_key(:body)
  end
end
