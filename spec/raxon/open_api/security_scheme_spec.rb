# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::OpenApi::SecurityScheme do
  it "normalizes snake_case types to their OpenAPI spelling" do
    expect(described_class.new(:key, type: :api_key).type).to eq("apiKey")
    expect(described_class.new(:key, type: :apiKey).type).to eq("apiKey")
    expect(described_class.new(:oidc, type: :open_id_connect).type).to eq("openIdConnect")
    expect(described_class.new(:basic, type: "http").type).to eq("http")
  end

  it "raises for an unknown type" do
    expect { described_class.new(:key, type: :magic) }
      .to raise_error(ArgumentError, /Unknown security scheme type/)
  end

  it "raises for unknown options" do
    expect { described_class.new(:key, type: :apiKey, header: "X-API-Key") }
      .to raise_error(ArgumentError, /Unknown security scheme options: header/)
  end

  it "captures an authenticator block" do
    scheme = described_class.new(:key, type: :apiKey) { |request| true }

    expect(scheme.authenticator).to be_a(Proc)
  end

  describe "#to_openapi" do
    it "emits an apiKey scheme" do
      scheme = described_class.new(:api_key, type: :apiKey, name: "X-API-Key", in: :header, description: "API key")

      expect(scheme.to_openapi).to eq(
        type: "apiKey",
        description: "API key",
        name: "X-API-Key",
        in: "header"
      )
    end

    it "emits an http bearer scheme with bearerFormat" do
      scheme = described_class.new(:bearer, type: :http, scheme: :bearer, bearer_format: "JWT")

      expect(scheme.to_openapi).to eq(type: "http", scheme: "bearer", bearerFormat: "JWT")
    end

    it "emits oauth2 flows verbatim" do
      flows = {authorizationCode: {authorizationUrl: "https://example.com/auth", tokenUrl: "https://example.com/token", scopes: {"read" => "Read"}}}
      scheme = described_class.new(:oauth, type: :oauth2, flows: flows)

      expect(scheme.to_openapi).to eq(type: "oauth2", flows: flows)
    end

    it "emits an openIdConnect scheme" do
      scheme = described_class.new(:oidc, type: :openIdConnect, open_id_connect_url: "https://example.com/.well-known/openid-configuration")

      expect(scheme.to_openapi).to eq(type: "openIdConnect", openIdConnectUrl: "https://example.com/.well-known/openid-configuration")
    end
  end
end

RSpec.describe Raxon::OpenApi::DSL, "security scheme registration and emission" do
  it "registers schemes on the default specification" do
    described_class.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header)

    expect(described_class.security_schemes.keys).to eq([:api_key])
  end

  it "clears schemes on reset!" do
    described_class.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header)
    described_class.reset!

    expect(described_class.security_schemes).to be_empty
  end

  it "emits schemes under components.securitySchemes" do
    described_class.security_scheme(:api_key, type: :apiKey, name: "X-API-Key", in: :header)
    described_class.endpoint do |endpoint|
      endpoint.path("/secure")
      endpoint.operation(:get)
      endpoint.security(:api_key)
      endpoint.response(200, type: :object)
    end

    spec = described_class.to_open_api

    expect(spec["components"]["securitySchemes"]).to eq(
      "api_key" => {"type" => "apiKey", "name" => "X-API-Key", "in" => "header"}
    )
    expect(spec["paths"]["/secure"]["get"]["security"]).to eq([{"api_key" => []}])
  end

  it "omits securitySchemes when no scheme is defined" do
    described_class.endpoint do |endpoint|
      endpoint.path("/open")
      endpoint.operation(:get)
      endpoint.response(200, type: :object)
    end

    expect(described_class.to_open_api["components"]).not_to have_key("securitySchemes")
  end

  it "supports isolated Specification objects" do
    spec = Raxon::OpenApi::Specification.new
    spec.security_scheme(:bearer, type: :http, scheme: :bearer)

    expect(spec.to_open_api["components"]["securitySchemes"]).to eq(
      "bearer" => {"type" => "http", "scheme" => "bearer"}
    )
  end
end
