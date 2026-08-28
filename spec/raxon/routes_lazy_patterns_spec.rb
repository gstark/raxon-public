# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Two costs that boot used to pay for work no request ever asked for:
#
# 1. Every registered path compiled a Mustermann pattern, including the static
#    ones that are answered by an exact hash lookup and never consult it. One
#    application spent 0.45s of boot building 520 patterns, 252 of them static.
# 2. A second RouteLoader.load! re-read and re-evaluated every route file before
#    #define refused the duplicate registration. Applications that load routes
#    at boot and then build a Router did exactly that.
#
# These are regression guards. They fail if either cost comes back.
RSpec.describe "lazy route pattern compilation" do
  subject(:routes) { Raxon::Routes.new }

  def register(path, method: "GET")
    routes.register(method, path, Raxon::OpenApi::Endpoint.new)
  end

  # Counts Mustermann pattern constructions for the duration of the block.
  def count_patterns
    built = []
    original = Mustermann.method(:new)

    Mustermann.define_singleton_method(:new) do |path, *args, **kwargs|
      built << path
      original.call(path, *args, **kwargs)
    end

    yield
    built
  ensure
    Mustermann.define_singleton_method(:new, original)
  end

  describe "registration" do
    it "compiles no pattern for a static path" do
      built = count_patterns { register("/api/v1/users") }

      expect(built).to be_empty
    end

    it "compiles no pattern for a dynamic path either" do
      built = count_patterns { register("/api/v1/users/{id}") }

      expect(built).to be_empty
    end

    it "records path parameters without compiling a pattern" do
      built = count_patterns { register("/api/v1/users/{user_id}/posts/{post_id}") }

      expect(built).to be_empty
      expect(routes.find("GET", "/api/v1/users/7/posts/9")[:params])
        .to eq({user_id: "7", post_id: "9"})
    end
  end

  describe "parameter names taken from the path" do
    # The scan replaces Mustermann#names, so it has to agree with it on every
    # shape a route file can produce — including a segment that only contains a
    # parameter, which the trie cannot index.
    [
      "/api/ping",
      "/api/v1/users/{id}",
      "/api/v1/users/{user_id}/posts/{post_id}",
      "/api/v1/reports/{name}.json",
      "/api/v1/files/{id}/download"
    ].each do |path|
      it "matches Mustermann#names for #{path}" do
        register(path)
        entry = routes.all.values.first[:entry]

        expect(entry[:param_symbols]).to eq(Mustermann.new(path).names.map(&:to_sym))
      end
    end
  end

  describe "matching" do
    it "still resolves a static path" do
      register("/api/v1/users")

      expect(routes.find("GET", "/api/v1/users")).not_to be_nil
    end

    it "still resolves a dynamic path and extracts its parameters" do
      register("/api/v1/users/{id}")

      expect(routes.find("GET", "/api/v1/users/42")[:params]).to eq({id: "42"})
    end

    it "compiles a dynamic pattern once, on the first request that needs it" do
      register("/api/v1/users/{id}")
      routes.prepare!

      built = count_patterns do
        routes.find("GET", "/api/v1/users/1")
        routes.find("GET", "/api/v1/users/2")
      end

      expect(built).to eq(["/api/v1/users/{id}"])
    end

    it "does not compile a pattern to answer a static path" do
      register("/api/v1/users")
      routes.prepare!

      built = count_patterns { routes.find("GET", "/api/v1/users") }

      expect(built).to be_empty
    end

    it "exposes the pattern through the legacy keyed shape" do
      register("/api/v1/users/{id}")

      pattern = routes.all.values.first[:mustermann]

      expect(pattern).to be_a(Mustermann::Pattern)
      expect(pattern.names).to eq(["id"])
    end
  end
end

RSpec.describe Raxon::RouteLoader, "repeated load!" do
  # Setup lives in `before`, not `around`: spec_helper has a global
  # before(:each) that points routes_directory back at "routes", and it would
  # run inside an around hook and undo this.
  before do
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "api"))
    File.write(File.join(@dir, "api/get.rb"), <<~RUBY)
      Raxon.route do |endpoint|
        endpoint.handler { |request, response| response.body = {ok: true} }
      end
    RUBY

    Raxon.configure { |config| config.routes_directory = @dir }
    Raxon::RouteLoader.reset!
  end

  after { FileUtils.remove_entry(@dir) if @dir }

  # File.read is the observable half of "did we evaluate this file again"; the
  # class_eval that follows is what actually cost the time.
  def count_route_file_reads
    reads = 0
    original = Raxon::RouteLoader.method(:load_route_in_isolation)

    Raxon::RouteLoader.define_singleton_method(:load_route_in_isolation) do |file|
      reads += 1
      original.call(file)
    end

    yield
    reads
  ensure
    Raxon::RouteLoader.define_singleton_method(:load_route_in_isolation, original)
  end

  it "does not re-evaluate a file it has already registered" do
    Raxon::RouteLoader.load!

    reads = count_route_file_reads { Raxon::RouteLoader.load! }

    expect(reads).to eq(0)
  end

  it "keeps the routes it loaded the first time" do
    Raxon::RouteLoader.load!
    Raxon::RouteLoader.load!

    expect(Raxon::RouteLoader.routes.find("GET", "/api")).not_to be_nil
    expect(Raxon::RouteLoader.routes.all.size).to eq(1)
  end

  it "picks up a file added between loads" do
    Raxon::RouteLoader.load!

    File.write(File.join(@dir, "api/post.rb"), <<~RUBY)
      Raxon.route do |endpoint|
        endpoint.handler { |request, response| response.body = {created: true} }
      end
    RUBY

    Raxon::RouteLoader.load!

    expect(Raxon::RouteLoader.routes.find("POST", "/api")).not_to be_nil
  end

  it "still rebuilds every file on reload!, which stages an empty registry" do
    Raxon::RouteLoader.load!

    reads = count_route_file_reads { Raxon::RouteLoader.reload! }

    expect(reads).to eq(1)
    expect(Raxon::RouteLoader.routes.find("GET", "/api")).not_to be_nil
  end
end
