# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Security scheme enforcement" do
  let(:router) { Raxon::Router.new }

  def call(path, headers = {})
    env = Rack::MockRequest.env_for(path, headers)
    router.call(env)
  end

  def define_secure_route(security = :api_key)
    define_route("routes/secure/get.rb") do |endpoint|
      endpoint.security(security)
      endpoint.handler do |request, response, metadata|
        response.ok user: metadata[:current_user]
      end
    end
  end

  context "with an authenticator block" do
    before do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) do |request, metadata|
        next false unless request.header("HTTP_X_API_KEY") == "valid-key"

        metadata[:current_user] = "alice"
      end
    end

    it "grants access when the authenticator returns truthy" do
      define_secure_route

      status, _, body = call("/secure", "HTTP_X_API_KEY" => "valid-key")

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"user" => "alice"})
    end

    it "enforces a requirement that names the scheme with a String" do
      define_secure_route([{"api_key" => []}])

      expect(call("/secure").first).to eq(401)
      expect(call("/secure", "HTTP_X_API_KEY" => "valid-key").first).to eq(200)
    end

    it "returns 401 when the authenticator returns falsy" do
      define_secure_route

      status, headers, body = call("/secure", "HTTP_X_API_KEY" => "wrong-key")

      expect(status).to eq(401)
      expect(headers["content-type"]).to eq("application/json")
      expect(JSON.parse(body.first)).to eq({"error" => "Unauthorized"})
    end

    it "skips before blocks and the handler on failure" do
      executed = []
      define_route("routes/secure/get.rb") do |endpoint|
        endpoint.security(:api_key)
        endpoint.before { |request, response, metadata| executed << :before }
        endpoint.handler do |request, response, metadata|
          executed << :handler
          response.ok
        end
      end

      call("/secure")

      expect(executed).to eq([])
    end

    it "runs after metadata blocks so parents can prepare context" do
      order = []
      Raxon::OpenApi::DSL.reset!
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) do |request, metadata|
        order << :authenticator
        false
      end
      define_route("routes/secure/get.rb") do |endpoint|
        endpoint.security(:api_key)
        endpoint.metadata { |request, response, metadata| order << :metadata }
        endpoint.handler { |request, response, metadata| response.ok }
      end

      call("/secure")

      expect(order).to eq([:metadata, :authenticator])
    end

    it "passes the declared scopes to the authenticator" do
      received_scopes = nil
      Raxon::OpenApi::DSL.reset!
      Raxon::OpenApi::DSL.security_scheme(:oauth, type: :oauth2, flows: {}) do |request, metadata, scopes|
        received_scopes = scopes
        true
      end
      define_route("routes/secure/get.rb") do |endpoint|
        endpoint.security(:oauth, scopes: ["read:users"])
        endpoint.handler { |request, response, metadata| response.ok }
      end

      status, = call("/secure")

      expect(status).to eq(200)
      expect(received_scopes).to eq(["read:users"])
    end
  end

  context "OR semantics across requirements" do
    it "grants access when any enforceable requirement passes" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| false }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer) do |request, metadata|
        request.header("HTTP_AUTHORIZATION") == "Bearer good-token"
      end
      define_secure_route([{api_key: []}, {bearer: []}])

      status, = call("/secure", "HTTP_AUTHORIZATION" => "Bearer good-token")

      expect(status).to eq(200)
    end

    it "returns 401 when no requirement passes" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| false }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer) { |request, metadata| false }
      define_secure_route([{api_key: []}, {bearer: []}])

      status, = call("/secure")

      expect(status).to eq(401)
    end
  end

  context "AND semantics within a requirement" do
    it "requires every scheme in the requirement to pass" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| true }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer) { |request, metadata| false }
      define_secure_route([{api_key: [], bearer: []}])

      status, = call("/secure")

      expect(status).to eq(401)
    end
  end

  context "schemes without an authenticator" do
    it "fails closed when the required scheme has no authenticator" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header)
      define_secure_route

      status, = call("/secure")

      expect(status).to eq(401)
    end

    it "fails an AND requirement whose other scheme has no authenticator" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| true }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer)
      define_secure_route([{api_key: [], bearer: []}])

      status, = call("/secure", "HTTP_X_API_KEY" => "valid-key")

      expect(status).to eq(401)
    end

    it "keeps a parent's enforced requirement when a child names a blockless scheme" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) do |request, metadata|
        request.header("HTTP_X_API_KEY") == "valid-key"
      end
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer)
      define_route("routes/secure/all.rb") { |endpoint| endpoint.security(:api_key) }
      define_route("routes/secure/child/get.rb") do |endpoint|
        endpoint.security(:bearer)
        endpoint.handler { |request, response, metadata| response.ok }
      end

      status, = call("/secure/child")

      expect(status).to eq(401)
    end

    it "grants access through another alternative that passes" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| true }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer)
      define_secure_route([{bearer: []}, {api_key: []}])

      status, = call("/secure")

      expect(status).to eq(200)
    end

    it "fails closed when a requirement references an undeclared scheme" do
      # An undeclared scheme name is almost always a typo or a load-order
      # mistake; the endpoint was meant to be protected, so deny rather than
      # silently admit the request.
      define_secure_route(:undeclared)

      status, = call("/secure")

      expect(status).to eq(401)
    end

    # An explicitly empty requirements array declares "no security", which is
    # distinct from declaring none at all: the endpoint takes the code path that
    # inspects requirements and has to find nothing to enforce.
    it "grants access when the endpoint declares an empty requirements array" do
      define_secure_route([])

      status, = call("/secure")

      expect(status).to eq(200)
    end
  end

  context "enforce: false schemes" do
    it "leaves authentication to the application when every scheme is enforce: false" do
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer, enforce: false)
      define_secure_route(:bearer)

      status, = call("/secure")

      expect(status).to eq(200)
    end

    it "raises when a requirement mixes enforce: false with an enforced scheme" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| true }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer, enforce: false)
      define_secure_route([{api_key: [], bearer: []}])

      expect { call("/secure") }.to raise_error(Raxon::Error, /mix enforce: false schemes with enforced ones/)
    end

    it "raises when alternatives mix enforce: false with an enforced scheme" do
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { |request, metadata| false }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer, enforce: false)
      define_secure_route([{bearer: []}, {api_key: []}])

      expect { call("/secure") }.to raise_error(Raxon::Error, /mix enforce: false schemes with enforced ones/)
    end
  end

  describe "WWW-Authenticate on a 401" do
    it "sends one challenge for each scheme the requirements name" do
      Raxon.configuration.openapi_title = 'Widgets "API"'
      Raxon::OpenApi::DSL.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header) { false }
      Raxon::OpenApi::DSL.security_scheme(:basic, type: :http, scheme: :basic) { false }
      Raxon::OpenApi::DSL.security_scheme(:bearer, type: :http, scheme: :bearer) { false }
      Raxon::OpenApi::DSL.security_scheme(:oauth, type: :oauth2, flows: {}) { false }
      define_secure_route([{api_key: []}, {basic: [], bearer: []}, {oauth: ["read"]}])

      status, headers, = call("/secure")

      expect(status).to eq(401)
      expect(headers["www-authenticate"]).to eq(
        'ApiKey header="X-API-Key", Basic realm="Widgets \\"API\\"", Bearer'
      )
    end
  end

  describe "insufficient scope" do
    it "answers 403 when the authenticator halts with :forbidden" do
      Raxon::OpenApi::DSL.security_scheme(:oauth, type: :oauth2, flows: {}) do |request, _metadata, scopes|
        granted = request.header("HTTP_X_SCOPES").to_s.split
        next true if (scopes - granted).empty?

        Raxon.halt(code: :forbidden, body: {error: "Forbidden"},
          headers: {"www-authenticate" => %(Bearer error="insufficient_scope", scope="#{scopes.join(" ")}")})
      end
      define_secure_route([{oauth: ["write"]}])

      status, headers, body = call("/secure", "HTTP_X_SCOPES" => "read")

      expect(status).to eq(403)
      expect(headers["www-authenticate"]).to eq('Bearer error="insufficient_scope", scope="write"')
      expect(JSON.parse(body.first)).to eq("error" => "Forbidden")
      expect(call("/secure", "HTTP_X_SCOPES" => "read write").first).to eq(200)
    end
  end
end
