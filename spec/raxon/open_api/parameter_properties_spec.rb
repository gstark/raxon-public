# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::RequestBody do
  describe "#property" do
    it "allows defining properties on a request body" do
      request_body = described_class.new(type: :object)
      request_body.property :name, type: :string, description: "Statistic name"

      expect(request_body.properties).to have_key(:name)
      expect(request_body.properties[:name]).to be_a(Raxon::OpenApi::Property)
      expect(request_body.properties[:name].type).to eq("string")
      expect(request_body.properties[:name].description).to eq("Statistic name")
    end

    it "allows nested properties" do
      request_body = described_class.new(type: :object)
      request_body.property :user, type: :object do |user|
        user.property :name, type: :string
        user.property :email, type: :string
      end

      expect(request_body.properties).to have_key(:user)
      user_property = request_body.properties[:user]
      expect(user_property.properties).to have_key(:name)
      expect(user_property.properties).to have_key(:email)
    end

    it "supports all property options" do
      request_body = described_class.new(type: :object)
      request_body.property :enabled, type: :boolean, required: true, description: "Whether enabled"
      request_body.property :count, type: :number, required: false, description: "Item count"

      expect(request_body.properties[:enabled].required).to be true
      expect(request_body.properties[:count].required).to be false
    end
  end

  describe "Endpoint#request_body with block" do
    it "allows defining nested properties via block" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object do |body|
        body.property :name, type: :string
        body.property :value, type: :number
      end

      request_body = endpoint.request_body
      expect(request_body.properties).to have_key(:name)
      expect(request_body.properties).to have_key(:value)
    end
  end
end

RSpec.describe Raxon::OpenApi::Parameters do
  describe "#define" do
    it "works without a block for simple parameters" do
      parameters = described_class.new
      parameters.define :id, type: :number, in: :path

      parameter = parameters.parameters.first
      expect(parameter.name).to eq(:id)
      expect(parameter.type).to eq("number")
      expect(parameter.properties).to be_empty
    end
  end
end
