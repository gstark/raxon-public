# frozen_string_literal: true

require "spec_helper"
require "rack/request"
require "rack/mock"

RSpec.describe Raxon::Request, "component-referenced request bodies" do
  def request_for(endpoint, body_hash)
    env = Rack::MockRequest.env_for(
      "/test",
      :method => "POST",
      :input => JSON.generate(body_hash),
      "CONTENT_TYPE" => "application/json"
    )
    Raxon::Request.new(Rack::Request.new(env), endpoint)
  end

  before do
    Raxon::OpenApi::DSL.component(:StatisticGroup, type: :object) do |c|
      c.property :title, type: :string
      c.property :position, type: :integer, required: false
      c.property :id, type: :integer, read_only: true
      c.property :deleted_at, type: :datetime, read_only: true, nullable: true
    end
  end

  let(:endpoint) do
    Raxon::OpenApi::Endpoint.new.tap do |endpoint|
      endpoint.request_body type: :object, as: "StatisticGroup"
    end
  end

  it "validates an as: body exactly like inline properties" do
    request = request_for(endpoint, {position: 2})

    request.params
    expect(request.validation_errors.to_h).to have_key(:title)
  end

  it "coerces declared property types" do
    request = request_for(endpoint, {title: "Revenue", position: "3"})

    expect(request.params[:position]).to eq(3)
    expect(request.validation_errors).to be_nil
  end

  it "strips read-only properties before the handler sees params" do
    request = request_for(endpoint, {title: "Revenue", deleted_at: "2026-01-01T00:00:00Z", id: 9})

    params = request.params
    expect(params).to eq({title: "Revenue"})
    expect(request.validation_errors).to be_nil
  end

  it "strips inline read-only properties too" do
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :object do |body|
      body.property :name, type: :string
      body.property :created_at, type: :datetime, read_only: true
    end

    params = request_for(endpoint, {name: "x", created_at: "2026-01-01T00:00:00Z"}).params
    expect(params).to eq({name: "x"})
  end

  it "rejects a wrong-typed value inside an as: body" do
    request = request_for(endpoint, {title: "Revenue", position: "not-a-number"})

    request.params
    expect(request.validation_errors.to_h).to have_key(:position)
  end

  describe "through EffectiveEndpoint" do
    it "resolves the body and answers request_schema? for an as:-only body" do
      effective = Raxon::EffectiveEndpoint.new(endpoint, [endpoint])

      expect(effective.request_schema?).to be(true)
      expect(effective.request_schema).not_to be_nil
      expect(effective.resolved_request_body.properties.keys).to contain_exactly(:title, :position)
      expect(effective.resolved_request_body.read_only_keys).to contain_exactly(:id, :deleted_at)
      expect(effective.request_body).to be(endpoint.request_body)
    end

    it "strips read-only params end to end" do
      effective = Raxon::EffectiveEndpoint.new(endpoint, [endpoint])
      request = request_for(effective, {title: "Revenue", deleted_at: "2026-01-01T00:00:00Z"})

      expect(request.params).to eq({title: "Revenue"})
      expect(request.validation_errors).to be_nil
    end
  end

  it "reports a clear error for an as: body naming an unknown component" do
    endpoint = Raxon::OpenApi::Endpoint.new
    endpoint.request_body type: :object, as: "Nope"

    request = request_for(endpoint, {anything: true})
    expect { request.params }.to raise_error(Raxon::OpenApi::Error, /unknown component "Nope"/)
  end
end
