# frozen_string_literal: true

require "spec_helper"
require "alba"

RSpec.describe "represents with an Alba resource" do
  let(:tag_class) { Struct.new(:id, :name, :secret) }

  let(:tag_resource) do
    Class.new do
      include Alba::Resource

      attributes :id, :name
      attribute :label do |tag|
        params[:upcase] ? tag.name.upcase : tag.name
      end
    end
  end

  before do
    Raxon::OpenApi::DSL.component(:Tag, type: :object) do |c|
      c.property :id, type: :integer
      c.property :name, type: :string
      c.property :label, type: :string
    end
    Raxon.register_representation(:Tag, tag_resource)
  end

  def get(path)
    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for(path))
    [status, JSON.parse(body.first)]
  end

  let(:tag) { tag_class.new(id: 1, name: "ruby", secret: "x") }

  it "serializes a returned object through the resource" do
    resource, value = tag_resource, tag
    define_route("routes/tags/get.rb") do |endpoint|
      endpoint.represents resource
      endpoint.handle { value }
    end

    expect(get("/tags")).to eq([200, {"id" => 1, "name" => "ruby", "label" => "ruby"}])
  end

  it "serializes each item of a collection" do
    resource, values = tag_resource, [tag, tag_class.new(id: 2, name: "rack")]
    define_route("routes/tags/get.rb") do |endpoint|
      endpoint.represents resource, collection: true
      endpoint.handle { values }
    end

    status, body = get("/tags")

    expect(status).to eq(200)
    expect(body.map { |item| item["name"] }).to eq(%w[ruby rack])
  end

  it "passes params to the resource" do
    resource, value = tag_resource, tag
    define_route("routes/tags/get.rb") do |endpoint|
      endpoint.represents resource, params: {upcase: true}
      endpoint.handle { value }
    end

    expect(get("/tags").last["label"]).to eq("RUBY")
  end

  it "serializes an Outcome with the represented status" do
    resource, value = tag_resource, tag
    define_route("routes/tags/get.rb") do |endpoint|
      endpoint.represents resource, status: :created
      endpoint.handle { Raxon::Outcome.created(value) }
    end

    expect(get("/tags")).to eq([201, {"id" => 1, "name" => "ruby", "label" => "ruby"}])
  end

  it "sends an error Outcome as the handler wrote it" do
    resource = tag_resource
    define_route("routes/tags/get.rb") do |endpoint|
      endpoint.represents resource
      endpoint.response 404, type: :object do |response|
        response.property :error, type: :string
      end
      endpoint.handle { Raxon::Outcome.not_found(error: "No such tag") }
    end

    expect(get("/tags")).to eq([404, {"error" => "No such tag"}])
  end

  it "raises when the resource was never registered" do
    expect { Raxon::OpenApi::Endpoint.new.represents(Class.new) }
      .to raise_error(Raxon::Error, /No representation registered/)
  end
end
