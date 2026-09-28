# frozen_string_literal: true

require "spec_helper"

RSpec.describe "validation_profile" do
  before do
    Raxon.configuration.validation_error_profile(:problem, status: 422) do |message, details|
      {title: message, errors: details}
    end
  end

  def define_profiled_route(profile)
    define_route("routes/items/get.rb") do |endpoint|
      endpoint.validation_profile profile
      endpoint.query_param :count, type: :integer, required: true
      endpoint.handler { |_request, response, _metadata| response.ok({}) }
    end
  end

  it "answers with the registered profile" do
    define_profiled_route(:problem)

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/items"))

    expect(status).to eq(422)
    expect(JSON.parse(body.first)).to eq("title" => "Validation failed", "errors" => {"count" => ["is missing"]})
  end

  it "raises when the routes load for a name that is not registered" do
    expect {
      define_profiled_route(:problme)
      Raxon::Router.new.call(Rack::MockRequest.env_for("/items?count=1"))
    }.to raise_error(Raxon::Error, /Unknown validation_profile :problme .*registered: :problem/)
  end
end
