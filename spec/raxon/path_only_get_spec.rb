# frozen_string_literal: true

require "spec_helper"

RSpec.describe "A bare GET to a route with only path parameters" do
  def get(path, method: "GET")
    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for(path, method: method))
    [status, body.each.to_a.join]
  end

  def define_user_route(**options)
    define_route("routes/users/__id__/get.rb") do |endpoint|
      endpoint.parameters { |params| params.define :id, in: :path, **options } unless options.empty?
      endpoint.handler { |request, response, _metadata| response.ok(id: request.params[:id]) }
    end
  end

  before do
    allow_any_instance_of(Raxon::ParamResolver).to receive(:resolve).and_call_original
  end

  it "skips the resolver for an inferred path parameter" do
    define_user_route

    expect(get("/users/a%20b")).to eq([200, %({"id":"a b"})])
    expect_any_instance_of(Raxon::ParamResolver).not_to receive(:resolve)
    get("/users/7")
  end

  it "skips the resolver for a declared plain string, and for HEAD" do
    define_user_route(type: :string, description: "User ID")

    expect_any_instance_of(Raxon::ParamResolver).not_to receive(:resolve)
    expect(get("/users/7")).to eq([200, %({"id":"7"})])
    expect(get("/users/7", method: "HEAD").first).to eq(200)
  end

  it "still resolves when there is a query string" do
    define_user_route

    expect_any_instance_of(Raxon::ParamResolver).to receive(:resolve).and_call_original
    expect(get("/users/7?extra=1")).to eq([200, %({"id":"7"})])
  end

  it "still validates a path parameter that is not a string" do
    define_user_route(type: :integer)

    expect(get("/users/abc").first).to eq(400)
    expect(get("/users/7")).to eq([200, %({"id":7})])
  end

  it "still validates a constrained string" do
    define_user_route(type: :string, pattern: "\\A\\d+\\z")

    expect(get("/users/abc").first).to eq(400)
  end

  it "still validates a string with an enum, and does not call a deferred one at load" do
    calls = 0
    define_user_route(type: :string, enum: -> {
      calls += 1
      %w[me]
    })
    router = Raxon::Router.new
    loaded_calls = calls

    status, = router.call(Rack::MockRequest.env_for("/users/you"))

    expect(loaded_calls).to eq(0)
    expect(status).to eq(400)
  end
end

RSpec.describe Raxon::OpenApi::Parameter, "#plain_path_string?" do
  it "is true for an unconstrained path string" do
    expect(described_class.new(:id, in: :path, type: :string, description: "x", example: "1")).to be_plain_path_string
  end

  it "is false for a query string, another type, or a constraint" do
    expect(described_class.new(:id, in: :query, type: :string)).not_to be_plain_path_string
    expect(described_class.new(:id, in: :path, type: :integer)).not_to be_plain_path_string
    expect(described_class.new(:id, in: :path, type: :uuid)).not_to be_plain_path_string
    expect(described_class.new(:id, in: :path, type: :string, max_length: 3)).not_to be_plain_path_string
    expect(described_class.new(:id, in: :path, type: :string, allowable_values: %w[a])).not_to be_plain_path_string
  end
end
