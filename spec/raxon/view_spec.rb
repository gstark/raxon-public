# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Views, partials, and layouts" do
  around do |example|
    Dir.mktmpdir("raxon-views") do |dir|
      @views = dir
      example.run
    end
  end

  def write_view(name, source)
    path = File.join(@views, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end

  def view(**options)
    Raxon::View.new(@views, **options)
  end

  describe Raxon::Template do
    after do
      Raxon::ViewHelpers.remove_method(:shout) if Raxon::ViewHelpers.method_defined?(:shout)
      Raxon::ViewHelpers.remove_method(:wrap) if Raxon::ViewHelpers.method_defined?(:wrap)
    end

    it "calls methods from Raxon::ViewHelpers" do
      Raxon::ViewHelpers.define_method(:shout) { |text| text.upcase }
      template = Raxon::Template.new("<p><%= shout(name) %></p>")

      expect(template.render(name: "<a>")).to eq("<p>&lt;A&gt;</p>")
    end

    it "does not escape a safe value" do
      template = Raxon::Template.new("<p><%= fragment %></p>")

      result = template.render(fragment: Raxon::SafeString.new("<b>x</b>"))

      expect(result).to eq("<p><b>x</b></p>")
    end

    it "does not escape a value whose html_safe? is true" do
      safe = Class.new(String) { def html_safe? = true }.new("<b>x</b>")
      template = Raxon::Template.new("<p><%= fragment %></p>")

      expect(template.render(fragment: safe)).to eq("<p><b>x</b></p>")
    end

    it "returns a safe string" do
      expect(Raxon::Template.new("<p></p>").render).to be_html_safe
    end

    it "lets a helper capture the block of a <%= %> call" do
      Raxon::ViewHelpers.define_method(:wrap) { |&block| raw("<div>#{capture(&block)}</div>") }
      template = Raxon::Template.new("<%= wrap do %><b><%= name %></b><% end %>!")

      expect(template.render(name: "<x>")).to eq("<div><b>&lt;x&gt;</b></div>!")
    end

    it "lets a helper concat parts inside a captured block" do
      Raxon::ViewHelpers.define_method(:wrap) { |&block| raw("<div>#{capture(&block)}</div>") }
      template = Raxon::Template.new("<%= wrap do %><% concat(name) %><% concat(raw('<br>')) %><% end %>")

      expect(template.render(name: "<x>")).to eq("<div>&lt;x&gt;<br></div>")
    end

    it "raises from concat outside a template" do
      expect { Raxon::ViewContext.new.concat("x") }.to raise_error(Raxon::Error, /outside a template/)
    end

    it "reports the template path in a backtrace" do
      template = Raxon::Template.new("<p>\n<% raise 'boom' %></p>", path: "/views/x.html.erb")

      expect { template.render }.to raise_error(RuntimeError) { |error|
        expect(error.backtrace.first).to start_with("/views/x.html.erb:2")
      }
    end
  end

  describe Raxon::View do
    it "renders a template by name with locals" do
      write_view("books/show.html.erb", "<h1><%= title %></h1>")

      expect(view.render("books/show", locals: {title: "<T>"})).to eq("<h1>&lt;T&gt;</h1>")
    end

    it "renders a partial with an underscore file name and its own locals" do
      write_view("books/index.html.erb", "<ul><% books.each do |b| %><%= render \"books/book\", book: b %><% end %></ul>")
      write_view("books/_book.html.erb", "<li><%= book %></li>")

      result = view.render("books/index", locals: {books: ["a", "<b>"]})

      expect(result).to eq("<ul><li>a</li><li>&lt;b&gt;</li></ul>")
    end

    it "keeps the output before and after a partial" do
      write_view("page.html.erb", "before <%= render \"part\" %> after")
      write_view("_part.html.erb", "[part]")

      expect(view.render("page")).to eq("before [part] after")
    end

    it "renders partials inside partials" do
      write_view("page.html.erb", "<%= render \"a/outer\", n: 1 %>")
      write_view("a/_outer.html.erb", "(<%= render \"a/inner\", n: n + 1 %>)")
      write_view("a/_inner.html.erb", "<%= n %>")

      expect(view.render("page")).to eq("(2)")
    end

    it "gives a partial's yield the captured block" do
      write_view("page.html.erb", "<%= render \"box\" do %><i>in</i><% end %>")
      write_view("_box.html.erb", "<div><%= yield if block_given? %></div>")

      expect(view.render("page")).to eq("<div><i>in</i></div>")
    end

    it "wraps the template in a layout" do
      write_view("page.html.erb", "<p><%= name %></p>")
      write_view("layouts/app.html.erb", "<body><%= yield %></body>")

      result = view.render("page", locals: {name: "x"}, layout: "layouts/app")

      expect(result).to eq("<body><p>x</p></body>")
    end

    it "gives the layout the content stored with content_for" do
      write_view("page.html.erb", <<~ERB.chomp)
        <% content_for(:title) { "A & B" } %><% content_for :head do %><meta name="x"><% end %>body
      ERB
      write_view("layouts/app.html.erb", <<~ERB.chomp)
        <title><%= yield :title %></title><%= yield :head %><%= yield :missing %>|<%= yield %>|<%= content_for?(:head) %>
      ERB

      result = view.render("page", layout: "layouts/app")

      expect(result).to eq(%(<title>A &amp; B</title><meta name="x">|body|true))
    end

    it "appends when content_for is called twice for one name" do
      write_view("page.html.erb", %(<% content_for :head, "<a>" %><% content_for :head do %><b></b><% end %>))
      write_view("layouts/app.html.erb", "<%= yield :head %>")

      expect(view.render("page", layout: "layouts/app")).to eq("&lt;a&gt;<b></b>")
    end

    it "gives a partial's content_for to the layout" do
      write_view("page.html.erb", "<%= render \"header\" %>")
      write_view("_header.html.erb", "<% content_for :header do %>H<% end %>")
      write_view("layouts/app.html.erb", "<%= yield :header %>/<%= yield %>")

      expect(view.render("page", layout: "layouts/app")).to eq("H/")
    end

    it "raises for a missing template" do
      expect { view.render("nope") }.to raise_error(Raxon::Error, /Template not found: nope/)
    end

    it "raises for a name that leaves the views directory" do
      outside = File.join(File.dirname(@views), "#{File.basename(@views)}-outside.html.erb")
      File.write(outside, "secret")

      expect { view.render("../#{File.basename(outside, ".html.erb")}") }
        .to raise_error(Raxon::Error, /Template not found/)
    ensure
      FileUtils.rm_f(outside)
    end

    it "refuses a template that symlinks outside the views directory" do
      Dir.mktmpdir do |other|
        target = File.join(other, "secret.html.erb")
        File.write(target, "secret")
        File.symlink(target, File.join(@views, "linked.html.erb"))

        expect { view.render("linked") }.to raise_error(Raxon::Error, /outside views_path/)
      end
    end

    it "compiles a changed template again when reload is on" do
      write_view("page.html.erb", "one")
      reloading = view(reload: true)
      expect(reloading.render("page")).to eq("one")

      write_view("page.html.erb", "two")
      File.utime(Time.now + 5, Time.now + 5, File.join(@views, "page.html.erb"))

      expect(reloading.render("page")).to eq("two")
    end

    it "keeps the compiled template when reload is off" do
      write_view("page.html.erb", "one")
      cached = view
      expect(cached.render("page")).to eq("one")

      write_view("page.html.erb", "two")
      File.utime(Time.now + 5, Time.now + 5, File.join(@views, "page.html.erb"))

      expect(cached.render("page")).to eq("one")
    end
  end

  describe Raxon::ViewContext do
    it "raises when a template renders a partial without a views path" do
      template = Raxon::Template.new(%(<%= render "x" %>))

      expect { template.render }.to raise_error(Raxon::Error, /views_path is not set/)
    end

    it "captures a block outside a template from its return value" do
      expect(Raxon::ViewContext.new.capture { "<a>" }).to eq("&lt;a&gt;")
    end

    it "joins values and escapes the unsafe ones" do
      context = Raxon::ViewContext.new

      result = context.safe_join([context.raw("<b>"), "<i>"], "<br>")

      expect(result).to eq("<b>&lt;br&gt;&lt;i&gt;")
      expect(result).to be_html_safe
    end
  end

  describe "Response#render" do
    before do
      Raxon.configure do |config|
        config.views_path = @views
        config.layout = "layouts/application"
      end
      write_view("layouts/application.html.erb", "<html><title><%= yield :title %></title><%= yield %></html>")
      write_view("layouts/bare.html.erb", "[<%= yield %>]")
    end

    def call(path)
      Raxon::Router.new.call(Rack::MockRequest.env_for(path))
    end

    it "renders a named template inside the configured layout" do
      write_view("books/show.html.erb", "<% content_for(:title) { title } %><h1><%= title %></h1>")
      define_route("routes/books/get.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "books/show", title: "<Book>" }
      end

      status, headers, body = call("/books")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/html")
      expect(body.first).to eq("<html><title>&lt;Book&gt;</title><h1>&lt;Book&gt;</h1></html>")
    end

    it "uses another layout, or none" do
      write_view("page.html.erb", "p")
      define_route("routes/bare/get.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "page", layout: "layouts/bare" }
      end
      define_route("routes/none/get.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "page", layout: false }
      end

      expect(call("/bare").last.first).to eq("[p]")
      expect(call("/none").last.first).to eq("p")
    end

    it "renders a template in another format without the layout" do
      stub_const("Rack::Mime::MIME_TYPES", Rack::Mime::MIME_TYPES.merge(".md" => "text/markdown"))
      write_view("books/show.md.erb", "# <%= title %>\n\n<%= raw body %>")
      define_route("routes/md/get.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "books/show", format: :md, title: "A & B", body: "<b>x</b>" }
      end

      status, headers, body = call("/md")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/markdown")
      expect(body.first).to eq("# A &amp; B\n\n<b>x</b>")
    end

    it "sets the status" do
      write_view("page.html.erb", "invalid")
      define_route("routes/form/post.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "page", status: :unprocessable_entity, layout: false }
      end

      status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/form", method: "POST"))

      expect(status).to eq(422)
      expect(body.first).to eq("invalid")
    end

    it "gives templates the request" do
      write_view("page.html.erb", "<%= request.path %>")
      define_route("routes/where/get.rb") do |endpoint|
        endpoint.handler { |request, response| response.render "page", layout: false }
      end

      expect(call("/where").last.first).to eq("/where")
    end

    it "renders the route's own template in the layout when no name is given" do
      Dir.mktmpdir("raxon-routes") do |routes|
        FileUtils.mkdir_p(File.join(routes, "own"))
        File.write(File.join(routes, "own", "get.rb"), <<~RUBY)
          Raxon.route do
            handler { |request, response| response.render(name: "<x>") }
          end
        RUBY
        File.write(File.join(routes, "own", "get.html.erb"), "<p><%= name %></p>")
        Raxon.configure { |config| config.routes_directory = routes }
        Raxon::RouteLoader.load!

        expect(call("/own").last.first).to eq("<html><title></title><p>&lt;x&gt;</p></html>")
      end
    end
  end
end
