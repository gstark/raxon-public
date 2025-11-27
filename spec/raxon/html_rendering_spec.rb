require "spec_helper"

RSpec.describe "HTML Rendering" do
  describe "response.html_body=" do
    it "sets content-type to text/html" do
      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response|
          response.code = :ok
          response.html_body = "<h1>Hello World</h1>"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/html")
      expect(body.first).to eq("<h1>Hello World</h1>")
    end

    it "stores HTML string in response body" do
      html_content = "<html><body><p>Test content</p></body></html>"

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response|
          response.code = :ok
          response.html_body = html_content
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(body.first).to eq(html_content)
    end
  end

  describe "response.html() with fixture routes", load_routes: true do
    it "renders ERB template with local variables" do
      env = Rack::MockRequest.env_for("/html_test/users", method: "GET")
      status, headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/html")
      expect(body.first).to eq("<h1>Welcome</h1><p>John</p>")
    end

    it "handles ERB syntax correctly with loops" do
      env = Rack::MockRequest.env_for("/html_test/list", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(body.first).to include("<li>Apple</li>")
      expect(body.first).to include("<li>Banana</li>")
      expect(body.first).to include("<li>Cherry</li>")
    end

    it "handles ERB conditionals" do
      env = Rack::MockRequest.env_for("/html_test/conditional", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(body.first).to include("<p>Hello!</p>")
      expect(body.first).not_to include("No message")
    end

    it "renders template with no variables" do
      env = Rack::MockRequest.env_for("/html_test/static", method: "GET")
      status, headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/html")
      expect(body.first).to eq("<h1>Static Page</h1>")
    end
  end

  describe "template file discovery", load_routes: true do
    it "discovers template in nested route structure" do
      env = Rack::MockRequest.env_for("/html_test/nested/deeply/path", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(body.first).to eq("<div>Nested route works</div>")
    end
  end

  describe "error handling" do
    it "raises error when template file doesn't exist" do
      Raxon::RouteLoader.register("routes/html_test/missing/get.rb") do |endpoint|
        endpoint.handler do |request, response|
          response.code = :ok
          response.html_body = response.html(title: "Test")
        end
      end

      env = Rack::MockRequest.env_for("/html_test/missing", method: "GET")

      expect {
        Raxon::Router.new.call(env)
      }.to raise_error(Raxon::Error, /Template not found/)
    end
  end
end
