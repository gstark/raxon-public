# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Route and helper symlink containment" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def route_body
    <<~RUBY
      Raxon.route do
        response 200, type: :object do
          property :ok, type: :boolean
        end
        handler { |_req, res, _m| res.ok ok: true }
      end
    RUBY
  end

  def routes_dir
    File.join(@root, "routes").tap { |d| FileUtils.mkdir_p(d) }
  end

  describe Raxon::PathContainment do
    it "treats a file inside a root as contained" do
      file = File.join(routes_dir, "api", "get.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "")

      expect(described_class.contained?(file, [routes_dir])).to be(true)
    end

    it "treats a symlink escaping the root as not contained" do
      outside = File.join(@root, "outside.rb")
      File.write(outside, "")
      link = File.join(routes_dir, "get.rb")
      File.symlink(outside, link)

      expect(described_class.contained?(link, [routes_dir])).to be(false)
    end

    it "treats an in-tree symlink as contained" do
      target = File.join(routes_dir, "shared.rb")
      File.write(target, "")
      link = File.join(routes_dir, "get.rb")
      File.symlink(target, link)

      expect(described_class.contained?(link, [routes_dir])).to be(true)
    end

    it "treats a broken symlink as not contained" do
      link = File.join(routes_dir, "get.rb")
      File.symlink(File.join(@root, "missing.rb"), link)

      expect(described_class.contained?(link, [routes_dir])).to be(false)
    end
  end

  describe "Raxon::RouteLoader.load!" do
    before do
      Raxon.reset!
      Raxon.configure { |c| c.routes_directory = routes_dir }
    end

    it "refuses to load a route file that symlinks outside the tree" do
      outside = File.join(@root, "evil.rb")
      File.write(outside, route_body)
      File.symlink(outside, File.join(routes_dir, "get.rb"))

      expect { Raxon::RouteLoader.load! }
        .to raise_error(Raxon::Error, /Refusing to load route file outside routes_directory/)
    end

    it "loads a route reached through an in-tree symlink" do
      real = File.join(routes_dir, "impl", "get.rb")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, route_body)
      FileUtils.mkdir_p(File.join(routes_dir, "aliased"))
      File.symlink(real, File.join(routes_dir, "aliased", "get.rb"))

      expect { Raxon::RouteLoader.load! }.not_to raise_error
      expect(Raxon::RouteLoader.routes.find("GET", "/aliased")).not_to be_nil
    end
  end

  describe "ERB template companions" do
    before do
      Raxon.reset!
      Raxon.configure do |c|
        c.routes_directory = routes_dir
        c.reload_routes = false
      end
    end

    def html_route_body
      <<~RUBY
        Raxon.route do
          handler { |_req, res, _m| res.html_body = res.html(name: "world") }
        end
      RUBY
    end

    def page_dir
      File.join(routes_dir, "page").tap { |d| FileUtils.mkdir_p(d) }
    end

    def render_page
      status, _headers, body = Raxon::Server.new.call(Rack::MockRequest.env_for("/page"))
      [status, body.each.to_a.join]
    end

    it "renders a template inside the tree" do
      File.write(File.join(page_dir, "get.rb"), html_route_body)
      File.write(File.join(page_dir, "get.html.erb"), "<h1>Hello <%= name %></h1>")

      expect(render_page).to eq([200, "<h1>Hello world</h1>"])
    end

    it "renders a template reached through an in-tree symlink" do
      File.write(File.join(page_dir, "get.rb"), html_route_body)
      shared = File.join(routes_dir, "shared.html.erb")
      File.write(shared, "<p><%= name %></p>")
      File.symlink(shared, File.join(page_dir, "get.html.erb"))

      expect(render_page).to eq([200, "<p>world</p>"])
    end

    it "refuses to load a template that symlinks outside the tree" do
      File.write(File.join(page_dir, "get.rb"), html_route_body)
      outside = File.join(@root, "evil.html.erb")
      File.write(outside, "<h1>escaped</h1>")
      File.symlink(outside, File.join(page_dir, "get.html.erb"))

      expect { Raxon::RouteLoader.load! }
        .to raise_error(Raxon::Error, /Refusing to load template outside routes_directory/)
    end

    it "treats a broken template symlink as no template" do
      File.write(File.join(page_dir, "get.rb"), route_body)
      File.symlink(File.join(@root, "missing.html.erb"), File.join(page_dir, "get.html.erb"))

      expect { Raxon::RouteLoader.load! }.not_to raise_error
      expect(Raxon::RouteLoader.routes.find("GET", "/page")).not_to be_nil
    end

    it "loads a route without a template" do
      File.write(File.join(page_dir, "get.rb"), route_body)

      expect { Raxon::RouteLoader.load! }.not_to raise_error
      expect(Raxon::RouteLoader.routes.find("GET", "/page")).not_to be_nil
    end
  end

  describe "Raxon.load_helpers" do
    it "refuses to load a helper file that symlinks outside helpers_path" do
      helpers = File.join(@root, "helpers").tap { |d| FileUtils.mkdir_p(d) }
      outside = File.join(@root, "evil_helper.rb")
      File.write(outside, "module Raxon::HandlerHelpers; end")
      File.symlink(outside, File.join(helpers, "evil.rb"))

      Raxon.reset!
      Raxon.configure { |c| c.helpers_path = helpers }

      expect { Raxon.load_helpers }
        .to raise_error(Raxon::Error, /Refusing to load helper file outside helpers_path/)
    end
  end
end
