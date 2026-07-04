# frozen_string_literal: true

require "spec_helper"
require "raxon/cli/generate_command"
require "tmpdir"

RSpec.describe Raxon::GenerateCommand do
  def suppress_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end

  def in_tmpdir
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  it "generates a route file with a handler stub" do
    in_tmpdir do
      output = suppress_output { described_class.new("route", ["api/v1/users", "get"]).execute }

      expect(output).to include("Created routes/api/v1/users/get.rb")
      content = File.read("routes/api/v1/users/get.rb")
      expect(content).to include('endpoint.description "TODO: describe GET /api/v1/users"')
      expect(content).to include("endpoint.response 200")
      expect(content).to include("endpoint.handler do |request, response, metadata|")
    end
  end

  it "defaults to GET when no method is given" do
    in_tmpdir do
      suppress_output { described_class.new("route", ["api/v1/ping"]).execute }

      expect(File.exist?("routes/api/v1/ping/get.rb")).to be(true)
    end
  end

  it "generates one file per method" do
    in_tmpdir do
      suppress_output { described_class.new("route", ["api/v1/users", "get", "POST"]).execute }

      expect(File.exist?("routes/api/v1/users/get.rb")).to be(true)
      expect(File.exist?("routes/api/v1/users/post.rb")).to be(true)
    end
  end

  it "declares path params for dunder segments" do
    in_tmpdir do
      suppress_output { described_class.new("route", ["api/v1/users/__id__", "get"]).execute }

      content = File.read("routes/api/v1/users/__id__/get.rb")
      expect(content).to include("endpoint.path_param :id, type: :string")
      expect(content).to include("GET /api/v1/users/{id}")
    end
  end

  it "normalizes {id}, :id, and $id segments to dunder style" do
    in_tmpdir do
      suppress_output { described_class.new("route", ["a/{one}/b/:two/c/$three", "get"]).execute }

      content = File.read("routes/a/__one__/b/__two__/c/__three__/get.rb")
      expect(content).to include("endpoint.path_param :one,")
      expect(content).to include("endpoint.path_param :two,")
      expect(content).to include("endpoint.path_param :three,")
    end
  end

  it "respects the configured routes directory" do
    in_tmpdir do
      Raxon.configuration.routes_directory = "app/routes"

      suppress_output { described_class.new("route", ["ping", "get"]).execute }

      expect(File.exist?("app/routes/ping/get.rb")).to be(true)
    end
  end

  it "refuses to overwrite an existing route file" do
    in_tmpdir do
      FileUtils.mkdir_p("routes/ping")
      File.write("routes/ping/get.rb", "# existing")

      expect {
        expect { described_class.new("route", ["ping", "get"]).execute }
          .to output(/already exists/).to_stdout
      }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }

      expect(File.read("routes/ping/get.rb")).to eq("# existing")
    end
  end

  it "rejects unknown generators" do
    expect {
      expect { described_class.new("model", []).execute }
        .to output(/Unknown generator 'model'/).to_stdout
    }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end

  it "rejects invalid HTTP methods" do
    in_tmpdir do
      expect {
        expect { described_class.new("route", ["ping", "fetch"]).execute }
          .to output(/Invalid HTTP method\(s\): fetch/).to_stdout
      }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  it "requires a route path" do
    expect {
      expect { described_class.new("route", []).execute }
        .to output(/Missing route path/).to_stdout
    }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
  end

  it "generates a loadable route file" do
    in_tmpdir do |dir|
      suppress_output { described_class.new("route", ["api/v1/things/__id__", "get"]).execute }

      Raxon.configuration.routes_directory = File.join(dir, "routes")
      Raxon::RouteLoader.load!

      route = Raxon::RouteLoader.routes.find("GET", "/api/v1/things/42")
      expect(route).not_to be_nil
      expect(route[:params]).to eq({id: "42"})
    end
  end
end
