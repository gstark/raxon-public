# frozen_string_literal: true

require "spec_helper"
require "raxon/test"

RSpec.describe "Nested form params" do
  include Raxon::Test::Methods

  before do
    define_route("routes/books/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :book, type: :object do |book|
          book.property :title, type: :string
          book.property :pages, type: :integer, required: false
          book.property :tags, type: :array, of: :string, required: false
          book.property :author, type: :object, required: false do |author|
            author.property :name, type: :string
          end
        end
      end
      endpoint.handler do |request, response, metadata|
        response.ok request.params
      end
    end
  end

  it "reads book[title] as a nested hash" do
    post "/books", params: {"book[title]" => "Manual"}

    expect(last_response.status).to eq(200)
    expect(last_response.json["book"]).to eq("title" => "Manual")
  end

  it "symbolizes the nested keys" do
    define_route("routes/keys/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :book, type: :object do |book|
          book.property :title, type: :string
        end
      end
      endpoint.handler do |request, response, metadata|
        response.ok keys: request.params[:book].keys.map(&:inspect)
      end
    end

    post "/keys", params: {"book[title]" => "Manual"}

    expect(last_response.json["keys"]).to eq([":title"])
  end

  it "coerces nested values to the declared types" do
    post "/books", params: {"book[title]" => "Manual", "book[pages]" => "12"}

    expect(last_response.json["book"]).to eq("title" => "Manual", "pages" => 12)
  end

  it "reads arrays and deeper objects" do
    post "/books",
      body: "book[title]=Manual&book[tags][]=a&book[tags][]=b&book[author][name]=Ada",
      headers: {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

    expect(last_response.json["book"]).to eq("title" => "Manual", "tags" => %w[a b], "author" => {"name" => "Ada"})
  end

  it "strips nested keys that are not declared" do
    post "/books", params: {"book[title]" => "Manual", "book[admin]" => "1"}

    expect(last_response.json["book"]).to eq("title" => "Manual")
  end

  it "rejects a missing required nested key" do
    post "/books", params: {"book[pages]" => "12"}

    expect(last_response.status).to eq(400)
  end
end
