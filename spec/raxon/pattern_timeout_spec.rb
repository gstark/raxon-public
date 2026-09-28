# frozen_string_literal: true

require "spec_helper"

RSpec.describe "A pattern match that times out" do
  # Ruby memoizes most backtracking, but not a pattern with a back-reference.
  before { Raxon.configuration.regexp_timeout = 0.01 }

  it "answers 400, not 500" do
    define_route("routes/search/get.rb") do |endpoint|
      endpoint.query_param :q, type: :string, pattern: "\\A(a+)+\\1\\z"
      endpoint.handler { |_request, response, _metadata| response.ok({}) }
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/search?q=#{"a" * 40}!"))

    expect(status).to eq(400)
    expect(body.join).to eq(%({"error":"Bad Request"}))
  end

  it "redacts a value whose key times out a filter_parameters regexp" do
    filter = Raxon::ParameterFilter.new([/\A(a+)+\1\z/])

    expect(filter.filter({"#{"a" * 40}!" => "secret"}).values).to eq(["[FILTERED]"])
  end
end
