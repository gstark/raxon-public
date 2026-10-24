# frozen_string_literal: true

require "spec_helper"
require "raxon/test"
require "tmpdir"

RSpec.describe "Error pages" do
  include Raxon::Test::Methods

  let(:html) { {"HTTP_ACCEPT" => "text/html,application/xhtml+xml,*/*;q=0.8"} }

  around do |example|
    Dir.mktmpdir("raxon-error-pages") do |dir|
      File.write(File.join(dir, "404.html"), "<h1>Missing</h1>")
      File.write(File.join(dir, "500.html"), "<h1>Broken</h1>")
      @pages = dir
      example.run
    end
  end

  before do
    Raxon.configure { |config| config.error_pages_path = @pages }

    define_route("routes/boom/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| raise "boom" }
    end

    define_route("routes/gone/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| response.error_page(:gone) }
    end

    define_route("routes/missing/get.rb") do |endpoint|
      endpoint.handler { |request, response, metadata| response.error_page(:not_found) }
    end
  end

  describe "an unmatched route" do
    it "serves 404.html to an HTML request" do
      get "/nope", headers: html

      expect(last_response.status).to eq(404)
      expect(last_response["content-type"]).to eq("text/html; charset=utf-8")
      expect(last_response.body).to eq("<h1>Missing</h1>")
    end

    it "keeps the JSON error for other requests" do
      get "/nope"

      expect(last_response.status).to eq(404)
      expect(last_response.json).to eq("error" => "Not Found")
    end

    it "keeps the JSON error when the request refuses HTML with q=0" do
      get "/nope", headers: {"HTTP_ACCEPT" => "text/html;q=0, application/json"}

      expect(last_response.json).to eq("error" => "Not Found")
    end

    it "keeps the JSON error when text/html is only part of another type" do
      get "/nope", headers: {"HTTP_ACCEPT" => "text/html-fragment"}

      expect(last_response.json).to eq("error" => "Not Found")
    end

    it "keeps the JSON error when error_pages_path is not set" do
      Raxon.configuration.error_pages_path = nil

      get "/nope", headers: html

      expect(last_response.json).to eq("error" => "Not Found")
    end
  end

  describe "an unhandled exception" do
    it "serves 500.html to an HTML request" do
      get "/boom", headers: html

      expect(last_response.status).to eq(500)
      expect(last_response.body).to eq("<h1>Broken</h1>")
    end

    it "keeps the JSON error for other requests" do
      get "/boom"

      expect(last_response.json).to eq("error" => "Internal Server Error")
    end
  end

  describe "Response#error_page" do
    it "serves the page for the status" do
      get "/missing", headers: html

      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq("<h1>Missing</h1>")
    end

    it "uses the reason phrase when there is no page" do
      get "/gone", headers: html

      expect(last_response.status).to eq(410)
      expect(last_response.json).to eq("error" => "Gone")
    end

    it "works from rescue_from" do
      Raxon.configure do |config|
        config.rescue_from(KeyError) { |error, request, response| response.error_page(:not_found) }
      end
      define_route("routes/lookup/get.rb") do |endpoint|
        endpoint.handler { |request, response, metadata| {}.fetch(:id) }
      end

      get "/lookup", headers: html

      expect(last_response.status).to eq(404)
      expect(last_response.body).to eq("<h1>Missing</h1>")
    end
  end
end
