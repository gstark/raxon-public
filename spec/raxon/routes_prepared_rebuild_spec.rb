# frozen_string_literal: true

require "spec_helper"

# Registering a route marks the prepared-route table dirty; the table is built
# once, by #prepare! or by the first reader.
#
# Before this, every register rebuilt the prepared table for every path already
# registered. One application registered 675 routes and built 404,329
# EffectiveEndpoint objects — 599 per route — which was 72% of its route loading
# and 16% of boot in GC alone. The counting specs below are regression guards:
# they fail loudly if that quadratic behaviour comes back.
RSpec.describe Raxon::Routes, "prepared route rebuilds" do
  subject(:routes) { described_class.new }

  def register(count)
    count.times do |i|
      routes.register("GET", "/api/v1/things/#{i}", Raxon::OpenApi::Endpoint.new)
    end
  end

  # Counts EffectiveEndpoint constructions for the duration of the block.
  def count_effective_endpoints
    built = 0
    original = Raxon::EffectiveEndpoint.instance_method(:initialize)

    Raxon::EffectiveEndpoint.class_eval do
      define_method(:initialize) do |*args, **kwargs|
        built += 1
        original.bind_call(self, *args, **kwargs)
      end
    end

    yield
    built
  ensure
    Raxon::EffectiveEndpoint.class_eval { define_method(:initialize, original) }
  end

  # Hold the rebuild open on its first entry, so a second thread is certain to
  # arrive while the table is half built.
  def stall_first_entry(routes, started, release)
    original = routes.method(:prepare_entry_routes)
    stalled = false

    routes.define_singleton_method(:prepare_entry_routes) do |entry|
      unless stalled
        stalled = true
        started.push(:building)
        release.pop
      end
      original.call(entry)
    end
  end

  # Two per route, not one: a GET route also gets the automatic HEAD fallback.
  # What matters is that this is a constant per route rather than a function of
  # how many other routes are registered.
  let(:per_get_route) { 2 }

  describe "registration" do
    it "builds no effective endpoints" do
      built = count_effective_endpoints { register(50) }

      expect(built).to eq(0)
    end

    it "stays linear as the route count grows" do
      small = described_class.new
      large = described_class.new

      count_effective_endpoints do
        25.times { |i| small.register("GET", "/api/v1/a/#{i}", Raxon::OpenApi::Endpoint.new) }
        100.times { |i| large.register("GET", "/api/v1/b/#{i}", Raxon::OpenApi::Endpoint.new) }
      end

      small_built = count_effective_endpoints { small.prepare! }
      large_built = count_effective_endpoints { large.prepare! }

      # Quadratic rebuilding made this ratio ~16 (4x the routes, 16x the work).
      # One rebuild makes it ~4, matching the route count.
      expect(large_built.to_f / small_built).to be < 6
    end
  end

  describe "#prepare!" do
    it "builds each registered route's effective endpoints once" do
      register(20)

      built = count_effective_endpoints { routes.prepare! }

      expect(built).to eq(20 * per_get_route)
    end

    it "is a no-op when nothing has changed since the last build" do
      register(20)
      routes.prepare!

      built = count_effective_endpoints { routes.prepare! }

      expect(built).to eq(0)
    end

    it "rebuilds after a later registration" do
      register(20)
      routes.prepare!

      routes.register("GET", "/api/v1/late", Raxon::OpenApi::Endpoint.new)
      built = count_effective_endpoints { routes.prepare! }

      expect(built).to eq(21 * per_get_route)
    end
  end

  describe "readers" do
    # Forgetting prepare! must cost latency on one request, never correctness.
    it "finds a route registered after the last build, without an explicit prepare!" do
      register(5)
      routes.prepare!
      routes.register("GET", "/api/v1/added-later", Raxon::OpenApi::Endpoint.new)

      expect(routes.find("GET", "/api/v1/added-later")).not_to be_nil
    end

    it "reports allowed methods for a route registered after the last build" do
      routes.prepare!
      routes.register("POST", "/api/v1/fresh", Raxon::OpenApi::Endpoint.new)

      expect(routes.allowed_methods("/api/v1/fresh")).to include("POST")
    end

    it "lists a route registered after the last build" do
      routes.prepare!
      routes.register("GET", "/api/v1/listed", Raxon::OpenApi::Endpoint.new)

      expect(routes.all.keys.join(" ")).to include("/api/v1/listed")
    end
  end

  describe "concurrent readers" do
    # Puma serves the first requests to a fresh container on many threads at
    # once. A rebuild that clears the table before repopulating it, without a
    # lock, hands every racing reader a route that does not exist yet.
    it "never lets a reader observe a partially built table" do
      register(200)

      found = 16.times.map do
        Thread.new { routes.find("GET", "/api/v1/things/199") }
      end.map(&:value)

      expect(found).to all(be_truthy)
    end

    it "builds the table once across concurrent readers" do
      register(100)

      built = count_effective_endpoints do
        8.times.map { Thread.new { routes.find("GET", "/api/v1/things/0") } }.each(&:join)
      end

      # One rebuild's worth, not eight.
      expect(built).to eq(100 * per_get_route)
    end

    # The specs above race naturally, which under the GVL is not reliable
    # enough to fail when the lock is removed — a rebuild of a hundred routes
    # finishes inside one thread's turn. This one holds the rebuild open so a
    # second reader is guaranteed to arrive mid-build, which is what the lock
    # exists for. Remove the synchronize in #ensure_prepared_routes and this
    # fails; the others do not.
    it "makes a second reader wait for the in-flight build instead of starting its own" do
      register(30)

      rebuild_started = Queue.new
      release_rebuild = Queue.new
      stall_first_entry(routes, rebuild_started, release_rebuild)

      built = count_effective_endpoints do
        first = Thread.new { routes.find("GET", "/api/v1/things/0") }
        rebuild_started.pop

        second = Thread.new { routes.find("GET", "/api/v1/things/0") }
        # Give the second reader every chance to start a competing rebuild.
        sleep 0.05
        release_rebuild.push(:go)

        [first, second].each(&:join)
      end

      expect(built).to eq(30 * per_get_route)
    end
  end
end
