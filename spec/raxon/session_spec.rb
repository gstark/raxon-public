# frozen_string_literal: true

require "spec_helper"
require "raxon/test"

RSpec.describe "Sessions and CSRF protection" do
  include Raxon::Test::Methods

  let(:secret) { "s" * 64 }

  before do
    Raxon.configure { |config| config.session_secret = secret }

    define_route("routes/session/get.rb") do |endpoint|
      endpoint.handler do |request, response, metadata|
        context = Raxon::ViewContext.new(request: request)
        response.ok name: request.session["name"], token: context.csrf_token
      end
    end

    define_route("routes/session/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :name, type: :string
      end
      endpoint.handler do |request, response, metadata|
        request.session["name"] = request.params[:name]
        response.redirect "/session"
      end
    end

    define_route("routes/session/delete.rb") do |endpoint|
      endpoint.handler do |request, response, metadata|
        request.reset_session
        response.redirect "/session"
      end
    end
  end

  def token
    get "/session"
    last_response.json["token"]
  end

  describe "the session" do
    it "keeps a value between requests" do
      post "/session", params: {name: "ada", authenticity_token: token}
      follow_redirect!

      expect(last_response.json["name"]).to eq("ada")
    end

    it "encrypts the cookie" do
      post "/session", params: {name: "ada", authenticity_token: token}

      expect(last_response["set-cookie"]).to start_with("raxon.session=")
      expect(last_response["set-cookie"]).not_to include("ada")
      expect(last_response["set-cookie"]).to include("httponly", "samesite=lax")
    end

    it "applies session_options over the defaults" do
      Raxon.configuration.session_options = {key: "app"}

      get "/session"

      expect(last_response["set-cookie"]).to start_with("app=")
      expect(last_response["set-cookie"]).to include("httponly")
    end

    it "clears the values on reset_session" do
      post "/session", params: {name: "ada", authenticity_token: token}
      delete "/session", params: {authenticity_token: token}
      follow_redirect!

      expect(last_response.json["name"]).to be_nil
    end

    it "raises from request.session when no secret is set" do
      Raxon.configuration.session_secret = nil

      get "/session"

      expect(last_response.status).to eq(500)
    end
  end

  describe "CSRF protection" do
    it "rejects a POST without a token" do
      post "/session", params: {name: "ada"}

      expect(last_response.status).to eq(403)
    end

    it "accepts the token in the X-CSRF-Token header" do
      csrf = token
      post "/session", params: {name: "ada"}, headers: {"X-CSRF-Token" => csrf}

      expect(last_response.status).to eq(302)
    end

    it "rejects a token from another session" do
      csrf = token
      cookie_jar.clear
      post "/session", params: {name: "ada", authenticity_token: csrf}

      expect(last_response.status).to eq(403)
    end

    it "allows a GET without a token" do
      get "/session"

      expect(last_response.status).to eq(200)
    end

    it "can be turned off" do
      Raxon.configuration.csrf_protection = false

      post "/session", params: {name: "ada"}

      expect(last_response.status).to eq(302)
    end

    it "checks a request that reaches the catchall" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler { |_request, response, _metadata| response.ok caught: true }
      end

      post "/unknown", params: {name: "ada"}

      expect(last_response.status).to eq(403)
    end
  end

  describe "CSRF protection with a fallback app" do
    def app
      @app ||= Raxon::Server.new(fallback: ->(_env) { [200, {}, ["fallback"]] })
    end

    it "checks a request before it delegates to the fallback" do
      post "/unknown", params: {name: "ada"}

      expect(last_response.status).to eq(403)
    end
  end

  describe "CSRF protection and the request body guards" do
    def multipart_body(fields)
      parts = fields.map do |name, (filename, data)|
        disposition = %(Content-Disposition: form-data; name="#{name}")
        disposition += %(; filename="#{filename}"\r\nContent-Type: application/octet-stream) if filename
        "--Boundary\r\n#{disposition}\r\n\r\n#{data}\r\n"
      end
      "#{parts.join}--Boundary--\r\n"
    end

    before { Raxon.configuration.max_request_body_size = 1_000 }

    it "answers 413 for a form body over the limit before it reads the token" do
      post "/session", params: {name: "a" * 5_000}

      expect(last_response.status).to eq(413)
    end

    it "answers 413 for a body over the limit that has no Content-Length" do
      body = multipart_body("name" => [nil, "a" * 5_000])
      env = Rack::MockRequest.env_for("/session", :method => "POST", :input => body,
        "CONTENT_TYPE" => "multipart/form-data; boundary=Boundary")
      env.delete("CONTENT_LENGTH")

      status, _headers, _body = app.call(env)

      expect(status).to eq(413)
    end

    it "refuses a file part for an endpoint with no file fields before it reads the token" do
      body = multipart_body("name" => [nil, "ada"], "upload" => ["notes.bin", "data"])

      post "/session", body: body, headers: {"Content-Type" => "multipart/form-data; boundary=Boundary"}

      expect(last_response.status).to eq(400)
      expect(last_response.json["error"]).to eq("File uploads are not accepted")
    end
  end

  describe Raxon::ViewContext do
    it "writes the csrf meta tags" do
      request = Raxon::Request.new(Rack::Request.new(Rack::MockRequest.env_for("/", Rack::RACK_SESSION => {})))
      tags = Raxon::ViewContext.new(request: request).csrf_meta_tags

      expect(tags).to be_html_safe
      expect(tags).to match(%r{<meta name="csrf-param" content="authenticity_token">\n<meta name="csrf-token" content="[\w=-]+">})
    end
  end
end
