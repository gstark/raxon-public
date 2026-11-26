# frozen_string_literal: true

require "spec_helper"

# Raxon::Routes, built from small endpoints instead of route files. An all.rb with no handler
# is middleware: its hooks join the routes at and below its path, but it does not answer a
# request by itself. An all.rb with a handler answers each method that has no route file.
RSpec.describe Raxon::Routes do
  subject(:routes) { described_class.new }

  def endpoint(method, path, handler: true)
    Raxon::OpenApi::Endpoint.new.tap do |endpoint|
      endpoint.path(path)
      endpoint.method = method.downcase
      endpoint.route_file_path = "#{path}/#{method.downcase}.rb"
      endpoint.infer_path_parameters(path.scan(/\{(\w+)\}/).flatten)
      endpoint.before { |_request, _response| }
      endpoint.handler { |_request, _response| } if handler
    end
  end

  def register(method, path, handler: true)
    endpoint(method, path, handler: handler).tap { |endpoint| routes.register(method, path, endpoint) }
  end

  # More dynamic routes than Routes::LINEAR_SCAN_LIMIT, so that the lookup goes through the
  # segment index and not through the linear scan.
  def register_filler_routes
    (Raxon::Routes::LINEAR_SCAN_LIMIT + 1).times { |index| register("GET", "/filler#{index}/{id}") }
  end

  [false, true].each do |indexed|
    context(indexed ? "with the dynamic route index" : "with the linear scan") do
      before { register_filler_routes if indexed }

      describe "a hook-only all at a static path" do
        let!(:hooks) { register("ALL", "/api", handler: false) }
        let!(:below) { register("GET", "/api/items") }

        it "matches no method at its own path" do
          Raxon::Routes::SUPPORTED_METHODS.each do |method|
            expect(routes.find(method, "/api")).to be_nil, method
          end
          expect(routes.allowed_methods("/api")).to eq([])
        end

        it "still runs its hooks for a route below it" do
          found = routes.find("GET", "/api/items")

          expect(found[:endpoint]).to equal(below)
          expect(found[:endpoints]).to eq([hooks, below])
        end
      end

      describe "a hook-only all at a dynamic path" do
        let!(:hooks) { register("ALL", "/items/{id}", handler: false) }
        let!(:below) { register("POST", "/items/{id}/archive") }

        it "matches no method at its own path" do
          Raxon::Routes::SUPPORTED_METHODS.each do |method|
            expect(routes.find(method, "/items/1")).to be_nil, method
          end
          expect(routes.allowed_methods("/items/1")).to eq([])
        end

        it "still runs its hooks for a route below it" do
          found = routes.find("POST", "/items/1/archive")

          expect(found[:endpoint]).to equal(below)
          expect(found[:endpoints]).to eq([hooks, below])
          expect(found[:params]).to eq({id: "1"})
        end
      end

      describe "a method route and a hook-only all at the same static path" do
        let!(:hooks) { register("ALL", "/visits", handler: false) }
        let!(:get_route) { register("GET", "/visits") }

        it "runs the hooks before the method route" do
          found = routes.find("GET", "/visits")

          expect(found[:endpoint]).to equal(get_route)
          expect(found[:endpoints]).to eq([hooks, get_route])
        end

        it "answers HEAD from the GET route, with the hooks" do
          found = routes.find("HEAD", "/visits")

          expect(found[:endpoint]).to equal(get_route)
          expect(found[:endpoints]).to eq([hooks, get_route])
          expect(found[:head_from_get]).to be(true)
        end

        it "matches no other method and allows only the method route" do
          %w[POST PUT PATCH DELETE OPTIONS].each do |method|
            expect(routes.find(method, "/visits")).to be_nil, method
          end
          expect(routes.allowed_methods("/visits")).to eq(%w[GET HEAD OPTIONS])
        end
      end

      describe "a method route and a hook-only all at the same dynamic path" do
        let!(:hooks) { register("ALL", "/visits/{id}", handler: false) }
        let!(:get_route) { register("GET", "/visits/{id}") }

        it "answers HEAD from the GET route, with the hooks and the params" do
          found = routes.find("HEAD", "/visits/7")

          expect(found[:endpoint]).to equal(get_route)
          expect(found[:endpoints]).to eq([hooks, get_route])
          expect(found[:head_from_get]).to be(true)
          expect(found[:params]).to eq({id: "7"})
        end

        it "matches no other method and allows only the method route" do
          %w[POST PUT PATCH DELETE OPTIONS].each do |method|
            expect(routes.find(method, "/visits/7")).to be_nil, method
          end
          expect(routes.allowed_methods("/visits/7")).to eq(%w[GET HEAD OPTIONS])
        end
      end

      describe "a hook-only all at a static path beside a dynamic route" do
        let!(:hooks) { register("ALL", "/admin/people", handler: false) }
        let!(:generic) { register("POST", "/admin/{resource}") }

        it "does not shadow the dynamic route" do
          found = routes.find("POST", "/admin/people")

          expect(found[:endpoint]).to equal(generic)
          expect(found[:params]).to eq({resource: "people"})
          expect(routes.allowed_methods("/admin/people")).to eq(%w[POST OPTIONS])
        end
      end

      describe "an all with a handler" do
        let!(:static_all) { register("ALL", "/things") }
        let!(:static_get) { register("GET", "/things") }
        let!(:dynamic_all) { register("ALL", "/things/{id}") }
        let!(:dynamic_get) { register("GET", "/things/{id}") }

        it "answers each method with no route file at a static path, HEAD included" do
          expect(routes.find("GET", "/things")[:endpoint]).to equal(static_get)
          %w[HEAD POST PUT PATCH DELETE OPTIONS].each do |method|
            found = routes.find(method, "/things")

            expect(found[:endpoint]).to equal(static_all), method
            expect(found[:head_from_get]).to be_nil, method
          end
          expect(routes.allowed_methods("/things")).to eq(Raxon::Routes::SUPPORTED_METHODS)
        end

        it "answers each method with no route file at a dynamic path, HEAD included" do
          expect(routes.find("GET", "/things/3")[:endpoint]).to equal(dynamic_get)
          %w[HEAD POST PUT PATCH DELETE OPTIONS].each do |method|
            found = routes.find(method, "/things/3")

            expect(found[:endpoint]).to equal(dynamic_all), method
            expect(found[:head_from_get]).to be_nil, method
            expect(found[:params]).to eq({id: "3"}), method
          end
          expect(routes.allowed_methods("/things/3")).to eq(Raxon::Routes::SUPPORTED_METHODS)
        end
      end

      describe "two dynamic routes that match one path" do
        # The template of the route that answers the method and path, from its route file name.
        def found_path(method, path)
          routes.find(method, path)&.dig(:endpoint)&.route_file_path&.delete_suffix("/#{method.downcase}.rb")
        end

        [
          ["/admin/{resource}/{id}", "/admin/users/{id}"],
          ["/admin/users/{id}", "/admin/{resource}/{id}"]
        ].each do |first, second|
          it "picks the route with the static segment when #{first} registers first" do
            register("GET", first)
            register("GET", second)

            expect(found_path("GET", "/admin/users/7")).to eq("/admin/users/{id}")
            expect(routes.find("GET", "/admin/users/7")[:params]).to eq({id: "7"})
            expect(found_path("GET", "/admin/schools/7")).to eq("/admin/{resource}/{id}")
            expect(routes.find("GET", "/admin/schools/7")[:params]).to eq({resource: "schools", id: "7"})
          end
        end

        [%w[/a/{x}/c /a/b/{y}], %w[/a/b/{y} /a/{x}/c]].each do |first, second|
          it "lets the first segment that differs decide when #{first} registers first" do
            register("GET", first)
            register("GET", second)

            expect(found_path("GET", "/a/b/c")).to eq("/a/b/{y}")
            expect(found_path("GET", "/a/z/c")).to eq("/a/{x}/c")
          end
        end

        [%w[/files/{id} /files/{name}.json], %w[/files/{name}.json /files/{id}]].each do |first, second|
          it "picks a mixed segment over a parameter segment when #{first} registers first" do
            register("GET", first)
            register("GET", second)

            expect(found_path("GET", "/files/report.json")).to eq("/files/{name}.json")
            expect(routes.find("GET", "/files/report.json")[:params]).to eq({name: "report"})
            expect(found_path("GET", "/files/report")).to eq("/files/{id}")
          end
        end

        it "orders three candidates from the most specific to the least" do
          register("GET", "/shop/{a}/{b}")
          register("GET", "/shop/{a}/{b}.csv")
          register("GET", "/shop/items/{b}")

          expect(found_path("GET", "/shop/items/list.csv")).to eq("/shop/items/{b}")
          expect(found_path("GET", "/shop/other/list.csv")).to eq("/shop/{a}/{b}.csv")
          expect(found_path("GET", "/shop/other/list")).to eq("/shop/{a}/{b}")
        end

        [%w[/left/{a}/{b}.csv /left/{c}.{d}/{e}], %w[/left/{c}.{d}/{e} /left/{a}/{b}.csv]].each do |first, second|
          it "lets the leftmost mixed segment win when #{first} registers first" do
            register("GET", first)
            register("GET", second)

            expect(found_path("GET", "/left/x.y/z.csv")).to eq("/left/{c}.{d}/{e}")
          end
        end

        [%w[/same/{a}/x /same/{b}/x], %w[/same/{b}/x /same/{a}/x]].each do |first, second|
          it "keeps the registration order for two templates of the same rank when #{first} registers first" do
            register("GET", first)
            register("GET", second)

            expect(found_path("GET", "/same/1/x")).to eq(first)
          end
        end

        it "still tries every method route before an all route with a handler" do
          register("ALL", "/admin/users/{id}")
          generic = register("PUT", "/admin/{resource}/{id}")

          expect(routes.find("PUT", "/admin/users/7")[:endpoint]).to equal(generic)
        end

        it "picks the most specific all route with a handler" do
          register("ALL", "/admin/{resource}/{id}")
          specific = register("ALL", "/admin/users/{id}")

          expect(routes.find("POST", "/admin/users/7")[:endpoint]).to equal(specific)
        end

        it "answers HEAD from the most specific GET route" do
          register("GET", "/admin/{resource}/{id}")
          specific = register("GET", "/admin/users/{id}")

          found = routes.find("HEAD", "/admin/users/7")
          expect(found[:endpoint]).to equal(specific)
          expect(found[:head_from_get]).to be(true)
        end

        it "allows the methods of both routes" do
          register("GET", "/admin/{resource}/{id}")
          register("PATCH", "/admin/{resource}/{id}")
          register("DELETE", "/admin/users/{id}")

          expect(routes.allowed_methods("/admin/users/7")).to eq(%w[GET HEAD PATCH DELETE OPTIONS])
          expect(routes.allowed_methods("/admin/schools/7")).to eq(%w[GET HEAD PATCH OPTIONS])
        end
      end

      describe "a GET route with no all" do
        let!(:get_route) { register("GET", "/plain/{id}") }

        it "answers HEAD from the GET route" do
          found = routes.find("HEAD", "/plain/1")

          expect(found[:endpoint]).to equal(get_route)
          expect(found[:head_from_get]).to be(true)
        end
      end
    end
  end

  it "keeps a hook-only all in the route list" do
    register("ALL", "/api", handler: false)

    expect(routes.all.keys).to eq([{method: "ALL", path: "/api"}])
  end
end
