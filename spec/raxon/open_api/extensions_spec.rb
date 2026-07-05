# frozen_string_literal: true

require "spec_helper"

RSpec.describe "OpenAPI specification extensions" do
  let(:dsl) { Raxon::OpenApi::DSL }

  describe "extensions: option" do
    it "emits extensions on a component property schema" do
      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime, extensions: {"x-ts-type" => "Dayjs"}
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).to include("type" => "string", "format" => "date-time", "x-ts-type" => "Dayjs")
    end

    it "emits extensions on a component schema itself" do
      dsl.component("Post", type: :object, extensions: {"x-internal" => true}) do |post|
        post.property :title, type: :string
      end

      expect(dsl.to_open_api["components"]["schemas"]["Post"]).to include("x-internal" => true)
    end

    it "emits extensions on a parameter schema" do
      dsl.endpoint do |endpoint|
        endpoint.path("/posts")
        endpoint.operation(:get)
        endpoint.parameters do |parameters|
          parameters.define(:since, type: :datetime, in: :query, required: false, extensions: {"x-ts-type" => "Dayjs"})
        end
        endpoint.response(200, type: :object)
      end

      parameter = dsl.to_open_api["paths"]["/posts"]["get"]["parameters"].first

      expect(parameter["schema"]).to include("x-ts-type" => "Dayjs")
    end

    it "emits extensions on a response schema" do
      dsl.endpoint do |endpoint|
        endpoint.path("/posts")
        endpoint.operation(:get)
        endpoint.response(200, type: :object, extensions: {"x-shape" => "post"}) do |response|
          response.property :title, type: :string
        end
      end

      schema = dsl.to_open_api["paths"]["/posts"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]

      expect(schema).to include("x-shape" => "post")
    end

    it "emits extensions on a request body schema" do
      dsl.endpoint do |endpoint|
        endpoint.path("/posts")
        endpoint.operation(:post)
        endpoint.request_body(type: :object, extensions: {"x-shape" => "post"}) do |body|
          body.property :title, type: :string
        end
        endpoint.response(201, type: :object)
      end

      schema = dsl.to_open_api["paths"]["/posts"]["post"]["requestBody"]["content"]["application/json"]["schema"]

      expect(schema).to include("x-shape" => "post")
    end

    it "emits extensions on array and union property schemas" do
      dsl.component("Post", type: :object) do |post|
        post.property :tags, type: :array, of: :string, extensions: {"x-set" => true}
        post.property :ref, type: [:string, :number], extensions: {"x-loose" => true}
      end

      properties = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]

      expect(properties["tags"]).to include("type" => "array", "x-set" => true)
      expect(properties["ref"]).to include("x-loose" => true)
    end

    it "normalizes symbol extension keys to strings" do
      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime, extensions: {"x-ts-type": "Dayjs"}
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).to include("x-ts-type" => "Dayjs")
    end

    it "does not emit extensions next to a $ref" do
      dsl.component("Author", type: :object) do |author|
        author.property :name, type: :string
      end
      dsl.component("Post", type: :object) do |post|
        post.property :author, type: :object, as: :Author, extensions: {"x-ts-type" => "Author"}
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["author"]

      expect(schema).to eq("$ref" => "#/components/schemas/Author")
    end

    it "rejects extension keys that do not start with x-" do
      expect {
        Raxon::OpenApi::Property.new(type: :string, extensions: {"ts-type" => "Dayjs"})
      }.to raise_error(ArgumentError, /must start with "x-"/)
    end

    it "rejects non-Hash extensions" do
      expect {
        Raxon::OpenApi::Property.new(type: :string, extensions: ["x-ts-type"])
      }.to raise_error(ArgumentError, /extensions must be a Hash/)
    end

    it "rejects invalid extension keys on every DSL class" do
      bad = {extensions: {"bad-key" => 1}}

      expect { Raxon::OpenApi::Parameter.new(:id, type: :string, **bad) }.to raise_error(ArgumentError)
      expect { Raxon::OpenApi::Response.new(type: :object, **bad) }.to raise_error(ArgumentError)
      expect { Raxon::OpenApi::Component.new(:Thing, type: :object, **bad) }.to raise_error(ArgumentError)
      expect { Raxon::OpenApi::RequestBody.new(type: :object, **bad) }.to raise_error(ArgumentError)
    end
  end

  describe "config.openapi_type_extensions" do
    before do
      Raxon.configure do |config|
        config.openapi_type_extensions = {
          datetime: {"x-ts-type" => "Dayjs"},
          date: {"x-ts-type" => "Dayjs"}
        }
      end
    end

    it "applies configured extensions to every schema of that type" do
      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime
        post.property :publish_on, type: :date
        post.property :title, type: :string
      end

      properties = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]

      expect(properties["published_at"]).to include("x-ts-type" => "Dayjs")
      expect(properties["publish_on"]).to include("x-ts-type" => "Dayjs")
      expect(properties["title"]).not_to have_key("x-ts-type")
    end

    it "applies configured extensions to array items of that type" do
      dsl.component("Post", type: :object) do |post|
        post.property :revised_at, type: :array, of: :datetime
      end

      items = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["revised_at"]["items"]

      expect(items).to include("type" => "string", "format" => "date-time", "x-ts-type" => "Dayjs")
    end

    it "applies configured extensions to union type members" do
      dsl.component("Post", type: :object) do |post|
        post.property :at, type: [:string, :datetime]
      end

      any_of = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["at"]["anyOf"]

      expect(any_of).to include(a_hash_including("x-ts-type" => "Dayjs"))
      expect(any_of).to include("type" => "string")
    end

    it "lets explicit extensions win over configured type extensions" do
      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime, extensions: {"x-ts-type" => "Moment"}
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).to include("x-ts-type" => "Moment")
    end

    it "matches string-keyed type names in the configuration" do
      Raxon.configure do |config|
        config.openapi_type_extensions = {"datetime" => {"x-ts-type" => "Dayjs"}}
      end

      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).to include("x-ts-type" => "Dayjs")
    end

    it "survives the 3.1 nullable conversion" do
      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime, nullable: true
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).to include("type" => ["string", "null"], "x-ts-type" => "Dayjs")
    end

    it "treats a nil configuration as no type extensions" do
      Raxon.configure { |config| config.openapi_type_extensions = nil }

      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime
      end

      schema = dsl.to_open_api["components"]["schemas"]["Post"]["properties"]["published_at"]

      expect(schema).not_to have_key("x-ts-type")
    end

    it "rejects configured extension keys that do not start with x-" do
      Raxon.configure do |config|
        config.openapi_type_extensions = {datetime: {"ts-type" => "Dayjs"}}
      end

      dsl.component("Post", type: :object) do |post|
        post.property :published_at, type: :datetime
      end

      expect { dsl.to_open_api }.to raise_error(ArgumentError, /must start with "x-"/)
    end
  end
end
