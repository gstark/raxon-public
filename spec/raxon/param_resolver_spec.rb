# frozen_string_literal: true

require "spec_helper"

# These specs exercise param resolution directly through its seam: plain hashes
# in, a Result out. No Rack env, no Request, no full app boot — the precedence,
# source-isolation, validation-fallback, and coercion rules live here and are
# tested here.
RSpec.describe Raxon::ParamResolver do
  def sources(query: {}, form: {}, json: {}, path: {}, headers: {}, cookies: {}, json_parse_error: false)
    described_class::Sources.new(
      query: query, form: form, json: json, path: path,
      headers: headers, cookies: cookies, json_parse_error: json_parse_error
    )
  end

  # A minimal stand-in for a Dry::Schema callable.
  def schema(success:, output: {}, errors: {})
    result = double(
      "schema_result",
      success?: success,
      to_h: output,
      errors: double("errors", to_h: errors)
    )
    double("schema", call: result)
  end

  # A schema that accepts whatever it is given and echoes it back as the coerced
  # output. Source isolation only reaches #params through a schema (the isolated
  # validation params become the schema's coerced output), so isolation specs
  # need one present.
  def echo_schema
    double("schema").tap do |s|
      allow(s).to receive(:call) { |params| double("result", success?: true, to_h: params) }
    end
  end

  describe "precedence (query < form < json < path)" do
    it "lets path override every client-supplied source" do
      resolver = described_class.new
      result = resolver.resolve(sources(
        query: {id: "query"},
        form: {id: "form"},
        json: {id: "json"},
        path: {id: "path"}
      ))

      expect(result.params[:id]).to eq("path")
    end

    it "lets json override form and query" do
      resolver = described_class.new(keep_undeclared: true)
      result = resolver.resolve(sources(query: {a: "q"}, form: {a: "f"}, json: {a: "j"}))

      expect(result.params[:a]).to eq("j")
    end

    it "merges distinct keys from all sources" do
      resolver = described_class.new(keep_undeclared: true)
      result = resolver.resolve(sources(query: {q: 1}, form: {f: 2}, json: {j: 3}, path: {p: 4}))

      expect(result.params).to eq(q: 1, f: 2, j: 3, p: 4)
    end
  end

  describe "source isolation by `in:` location" do
    it "does not let a body value satisfy a required header parameter" do
      header_param = Raxon::OpenApi::Parameter.new(:api_key, type: :string, in: :header)
      resolver = described_class.new(parameters: [header_param], schema: echo_schema)

      result = resolver.resolve(sources(
        json: {api_key: "from-body"},
        headers: {"HTTP_API_KEY" => "from-header"}
      ))

      # The body value is dropped; the header source wins.
      expect(result.params[:api_key]).to eq("from-header")
    end

    it "drops a same-named parameter entirely when its source is empty" do
      header_param = Raxon::OpenApi::Parameter.new(:api_key, type: :string, in: :header)
      resolver = described_class.new(parameters: [header_param], schema: echo_schema)

      result = resolver.resolve(sources(json: {api_key: "from-body"}))

      expect(result.params).not_to have_key(:api_key)
    end

    it "reads a cookie parameter from the cookie source" do
      cookie_param = Raxon::OpenApi::Parameter.new(:session, type: :string, in: :cookie)
      resolver = described_class.new(parameters: [cookie_param], schema: echo_schema)

      result = resolver.resolve(sources(cookies: {"session" => "abc"}))

      expect(result.params[:session]).to eq("abc")
    end

    it "matches the capitalized-dash header form too" do
      header_param = Raxon::OpenApi::Parameter.new(:x_request_id, type: :string, in: :header)
      resolver = described_class.new(parameters: [header_param], schema: echo_schema)

      result = resolver.resolve(sources(headers: {"HTTP_X_REQUEST_ID" => "r-1"}))

      expect(result.params[:x_request_id]).to eq("r-1")
    end

    it "leaves query parameters in the lenient merge" do
      query_param = Raxon::OpenApi::Parameter.new(:page, type: :string, in: :query)
      resolver = described_class.new(parameters: [query_param], schema: echo_schema)

      result = resolver.resolve(sources(query: {page: "2"}))

      expect(result.params[:page]).to eq("2")
    end

    it "does not let a JSON or form value override a query parameter" do
      query_param = Raxon::OpenApi::Parameter.new(:file, type: :string, in: :query)
      resolver = described_class.new(parameters: [query_param], schema: echo_schema)

      result = resolver.resolve(sources(query: {file: "a.txt"}, form: {file: "b.txt"}, json: {file: "../etc/passwd"}))

      expect(result.params[:file]).to eq("a.txt")
    end

    it "does not let a body value satisfy a missing query parameter" do
      query_param = Raxon::OpenApi::Parameter.new(:file, type: :string, in: :query)
      resolver = described_class.new(parameters: [query_param], schema: echo_schema)

      result = resolver.resolve(sources(json: {file: "../etc/passwd"}))

      expect(result.params).not_to have_key(:file)
    end
  end

  describe "validation" do
    it "returns the coerced schema output on success with no errors" do
      resolver = described_class.new(schema: schema(success: true, output: {id: 7}))

      result = resolver.resolve(sources(query: {id: "7"}))

      expect(result.params).to eq(id: 7)
      expect(result.errors).to be_nil
    end

    it "drops keys the schema does not declare and keeps path values" do
      resolver = described_class.new(schema: schema(success: true, output: {name: "Ada"}))

      result = resolver.resolve(sources(form: {name: "Ada", admin: "1"}, path: {id: "4"}))

      expect(result.params).to eq(id: "4", name: "Ada")
    end

    it "gives empty params and records errors on failure" do
      failing = schema(success: false, errors: {id: ["is missing"]})
      resolver = described_class.new(schema: failing)

      result = resolver.resolve(sources(query: {other: "x"}, path: {p: "y"}))

      expect(result.params).to eq({})
      expect(result.errors).to eq(id: ["is missing"])
    end
  end

  describe "coercion" do
    it "wraps a Rack file hash declared as type: :file" do
      tempfile = double("tempfile", read: "bytes", rewind: nil)
      file_hash = {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"}

      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :photo, type: :file

      resolver = described_class.new(request_body: request_body)
      result = resolver.resolve(sources(form: {photo: file_hash}))

      expect(result.params[:photo]).to be_a(Raxon::UploadedFile)
      expect(result.params[:photo].original_filename).to eq("photo.jpg")
    end
  end

  describe "JSON parse failure" do
    it "short-circuits to empty params with parse_error set" do
      resolver = described_class.new(schema: schema(success: true, output: {a: 1}))

      result = resolver.resolve(sources(json_parse_error: true))

      expect(result.params).to eq({})
      expect(result.parse_error).to be(true)
      expect(result.errors).to be_nil
    end
  end

  describe "no endpoint artifacts" do
    it "keeps only path values when there is nothing declared" do
      resolver = described_class.new

      result = resolver.resolve(sources(query: {a: "1"}, json: {b: "2"}, path: {id: "3"}))

      expect(result.params).to eq(id: "3")
    end

    it "keeps body values for a free-form request body" do
      body = Raxon::OpenApi::RequestBody.new(type: :object)
      resolver = described_class.new(request_body: body)

      result = resolver.resolve(sources(query: {a: "1"}, json: {b: "2"}))

      expect(result.params).to eq(b: "2")
    end

    it "keeps free-form body values when declared parameters produce a schema" do
      body = Raxon::OpenApi::RequestBody.new(type: :object)
      parameter = Raxon::OpenApi::Parameter.new(:page, type: :string, in: :query)
      validated = schema(success: true, output: {page: "1"})
      resolver = described_class.new(parameters: [parameter], schema: validated, request_body: body)

      result = resolver.resolve(sources(query: {page: "1"}, json: {b: "2", page: "9"}))

      expect(result.params).to eq(b: "2", page: "1")
    end

    it "returns the lenient merge unvalidated when told to keep undeclared keys" do
      resolver = described_class.new(keep_undeclared: true)

      result = resolver.resolve(sources(query: {a: "1"}, json: {b: "2"}))

      expect(result.params).to eq(a: "1", b: "2")
      expect(result.errors).to be_nil
      expect(result.parse_error).to be(false)
    end
  end

  describe "sharing one resolver across requests" do
    it "does not carry headers from one request into the next" do
      header_param = Raxon::OpenApi::Parameter.new(:x_tenant, type: :string, in: :header)
      resolver = described_class.new(parameters: [header_param], schema: echo_schema)

      first = resolver.resolve(sources(headers: {"HTTP_X_TENANT" => "a"}))
      second = resolver.resolve(sources(headers: {}))

      expect(first.params[:x_tenant]).to eq("a")
      expect(second.params).not_to have_key(:x_tenant)
    end

    it "builds no coercer for a body without a file field" do
      body = Raxon::OpenApi::RequestBody.new(type: :object)
      body.property :name, type: :string
      allow(Raxon::OpenApi::RequestBodyCoercer).to receive(:new).and_call_original

      described_class.new(request_body: body)

      expect(Raxon::OpenApi::RequestBodyCoercer).not_to have_received(:new)
    end

    it "still wraps a nested file field" do
      body = Raxon::OpenApi::RequestBody.new(type: :object)
      body.property :profile, type: :object do |profile|
        profile.property :photo, type: :file
      end
      upload = {filename: "a.png", type: "image/png", name: "profile[photo]", tempfile: Tempfile.new("a"), head: ""}
      resolver = described_class.new(request_body: body, schema: echo_schema)

      result = resolver.resolve(sources(form: {profile: {photo: upload}}))

      expect(result.params[:profile][:photo]).to be_a(Raxon::UploadedFile)
    end
  end
end

RSpec.describe Raxon::ParamResolver, "header normalization" do
  def sources(query: {}, form: {}, json: {}, path: {}, headers: {}, cookies: {}, json_parse_error: false)
    described_class::Sources.new(
      query: query, form: form, json: json, path: path,
      headers: headers, cookies: cookies, json_parse_error: json_parse_error
    )
  end

  def echo_schema
    double("schema").tap do |s|
      allow(s).to receive(:call) { |params| double("result", success?: true, to_h: params) }
    end
  end

  it "finds a header stored without the HTTP_ prefix via the capitalized-dash form" do
    parameter = Raxon::OpenApi::Parameter.new(:x_api_key, type: :string, in: :header)
    resolver = described_class.new(parameters: [parameter], schema: echo_schema)

    result = resolver.resolve(sources(headers: {"X_API_KEY" => "secret"}))

    expect(result.params[:x_api_key]).to eq("secret")
  end
end

RSpec.describe Raxon::ParamResolver, "unrecognized in: locations" do
  it "reads the query string, never the body, for locations it does not isolate" do
    # Raxon::OpenApi::Parameter rejects non-OpenAPI locations, so use a bare
    # duck-typed parameter to exercise the resolver's defensive fallback branch
    # directly.
    parameter = Struct.new(:name, :in).new(:payload, :body)
    echo_schema = double("schema")
    allow(echo_schema).to receive(:call) { |params| double("result", success?: true, to_h: params) }
    resolver = described_class.new(parameters: [parameter], schema: echo_schema)

    sources = described_class::Sources.new(
      query: {payload: "from-query"}, form: {}, json: {payload: "from-body"}, path: {},
      headers: {}, cookies: {}, json_parse_error: false
    )

    expect(resolver.resolve(sources).params[:payload]).to eq("from-query")
  end

  describe described_class::Sources do
    # Request hands itself over as +deferred+ rather than materializing headers
    # and cookies, which most endpoints never read.
    it "reads headers and cookies from the deferred source on first use" do
      deferred = double("request", headers: {"HTTP_X_TOKEN" => "abc"}, cookies: {"session" => "xyz"})
      sources = described_class.new(query: {a: 1}, deferred: deferred)

      expect(sources.headers).to eq("HTTP_X_TOKEN" => "abc")
      expect(sources.cookies).to eq("session" => "xyz")
    end

    # The double stubs nothing, so consulting it at all raises rather than
    # quietly returning the wrong source.
    it "prefers values passed directly over the deferred source" do
      sources = described_class.new(headers: {"HTTP_X" => "direct"}, cookies: {}, deferred: double("request"))

      expect(sources.headers).to eq("HTTP_X" => "direct")
      expect(sources.cookies).to eq({})
    end

    it "defaults headers and cookies to empty with neither values nor a deferred source" do
      sources = described_class.new(query: {a: 1})

      expect(sources.headers).to eq({})
      expect(sources.cookies).to eq({})
    end
  end
end
