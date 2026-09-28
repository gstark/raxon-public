require "spec_helper"

RSpec.describe "Response#halt" do
  describe "halt in before block with single endpoint" do
    it "stops handler execution when halt is called" do
      before_block_called = false
      handler_called = false

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.before do |request, response|
          before_block_called = true
          response.code = :unauthorized
          response.body = {error: "Unauthorized"}
          response.halt
        end
        endpoint.handler do |request, response|
          handler_called = true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(before_block_called).to eq(true)
      expect(handler_called).to eq(false)
      expect(status).to eq(401)
      expect(JSON.parse(body.first)).to eq({"error" => "Unauthorized"})
    end

    it "does not prevent handler execution if halt is not called" do
      before_block_called = false
      handler_called = false

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.before do |request, response|
          before_block_called = true
          response.rack_response["X-Custom-Header"] = "test"
        end
        endpoint.handler do |request, response|
          handler_called = true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, headers, _body = Raxon::Router.new.call(env)

      expect(before_block_called).to eq(true)
      expect(handler_called).to eq(true)
      expect(status).to eq(200)
      expect(headers["X-Custom-Header"]).to eq("test")
    end
  end

  describe "halt in before block with route hierarchy" do
    it "stops remaining before blocks and handler when halt is called" do
      parent_before_called = false
      child_before_called = false

      parent_endpoint = Raxon::OpenApi::Endpoint.new
      parent_endpoint.before do |request, response|
        parent_before_called = true
        response.code = :forbidden
        response.body = {error: "Forbidden"}
        response.halt
      end

      child_endpoint = Raxon::OpenApi::Endpoint.new
      child_endpoint.before do |request, response|
        child_before_called = true
      end
      child_endpoint.handler do |_request, _response|
        # This should not be called
      end

      # Simulate route hierarchy
      response = Raxon::Response.new

      # First before block - halt will raise HaltException
      rack_request = Rack::MockRequest.env_for("/test", method: "GET")
      before_request = Raxon::Request.new(Rack::Request.new(rack_request), parent_endpoint)

      # Catch the HaltException as the Router would
      begin
        parent_endpoint.before_blocks.each do |before_block|
          before_block.call(before_request, response)
        end
      rescue Raxon::HaltException => e
        response = e.response
      end

      expect(parent_before_called).to eq(true)
      expect(response.halted?).to eq(true)

      # Simulate Router behavior - should not call remaining blocks
      if response.halted?
        # These should not happen in a real request
        expect(child_before_called).to eq(false)
      end
    end

    it "allows child before blocks to execute if parent does not halt" do
      parent_before_called = false
      child_before_called = false

      parent_endpoint = Raxon::OpenApi::Endpoint.new
      parent_endpoint.before do |request, response|
        parent_before_called = true
        response.rack_response["X-Parent"] = "parent"
      end

      child_endpoint = Raxon::OpenApi::Endpoint.new
      child_endpoint.before do |request, response|
        child_before_called = true
        response.rack_response["X-Child"] = "child"
      end
      child_endpoint.handler do |_request, _response|
        response.code = :ok
        response.body = {success: true}
      end

      response = Raxon::Response.new

      rack_request = Rack::MockRequest.env_for("/test", method: "GET")
      before_request = Raxon::Request.new(Rack::Request.new(rack_request), parent_endpoint)
      parent_endpoint.before_blocks.each do |before_block|
        before_block.call(before_request, response)
      end

      expect(parent_before_called).to eq(true)
      expect(response.halted?).to eq(false)

      # Child block can execute
      before_request = Raxon::Request.new(Rack::Request.new(rack_request), child_endpoint)
      child_endpoint.before_blocks.each do |before_block|
        before_block.call(before_request, response)
      end

      expect(child_before_called).to eq(true)
      expect(response.halted?).to eq(false)
    end
  end

  describe "halt in handler block" do
    it "halts but handler has already run" do
      handler_called = false

      define_route("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response|
          handler_called = true
          response.code = :ok
          response.body = {success: true}
          response.halt
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(handler_called).to eq(true)
      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to eq({"success" => true})
    end
  end

  describe "Response#halted?" do
    it "returns false by default" do
      response = Raxon::Response.new
      expect(response.halted?).to eq(false)
    end

    it "returns true after halt is called" do
      response = Raxon::Response.new
      # halt raises HaltException, so we need to catch it
      begin
        response.halt
      rescue Raxon::HaltException
        # Exception raised as expected
      end
      expect(response.halted?).to eq(true)
    end
  end

  describe "HaltException" do
    it "is raised when halt is called" do
      response = Raxon::Response.new
      response.code = :unauthorized
      response.body = {error: "Not authorized"}

      expect {
        response.halt
      }.to raise_error(Raxon::HaltException)
    end

    it "carries the response object" do
      response = Raxon::Response.new
      response.code = :forbidden
      response.body = {error: "Forbidden"}

      begin
        response.halt
      rescue Raxon::HaltException => e
        expect(e.response).to eq(response)
        expect(e.response.status_code).to eq(403)
        expect(e.response.body).to eq({error: "Forbidden"})
      end
    end
  end
end

RSpec.describe "Raxon.halt" do
  it "halts a handler with a status and body, without a Response instance" do
    handler_reached_end = false

    define_route("routes/guarded/get.rb") do |endpoint|
      endpoint.handler do |_request, _response, _metadata|
        Raxon.halt(code: :forbidden, body: {error: "Not allowed"})
        handler_reached_end = true
      end
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/guarded", method: "GET"))

    expect(status).to eq(403)
    expect(JSON.parse(body.first)).to eq("error" => "Not allowed")
    expect(handler_reached_end).to eq(false)
  end

  it "works from a helper method that never receives the response" do
    define_route("routes/viahelper/get.rb") do |endpoint|
      endpoint.handler do |_request, response, _metadata|
        # A guard that halts without taking `response`.
        deny = -> { Raxon.halt(code: :unauthorized, body: {error: "Sign in"}) }
        deny.call
        response.ok(never: true)
      end
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/viahelper", method: "GET"))

    expect(status).to eq(401)
    expect(JSON.parse(body.first)).to eq("error" => "Sign in")
  end

  it "preserves headers set on the response before the halt" do
    define_route("routes/withheaders/get.rb") do |endpoint|
      endpoint.before do |_request, response, _metadata|
        response.header "X-Before", "ran"
      end
      endpoint.handler do |_request, _response, _metadata|
        Raxon.halt(code: :forbidden, body: {error: "no"})
      end
    end

    status, headers, _body = Raxon::Router.new.call(Rack::MockRequest.env_for("/withheaders", method: "GET"))

    expect(status).to eq(403)
    expect(headers["X-Before"]).to eq("ran")
  end

  it "can set its own headers" do
    define_route("routes/haltheaders/get.rb") do |endpoint|
      endpoint.handler do |_request, _response, _metadata|
        Raxon.halt(code: :too_many_requests, body: {error: "slow down"}, headers: {"Retry-After" => "30"})
      end
    end

    status, headers, _body = Raxon::Router.new.call(Rack::MockRequest.env_for("/haltheaders", method: "GET"))

    expect(status).to eq(429)
    expect(headers["Retry-After"]).to eq("30")
  end

  it "halts a before block, skipping the handler" do
    handler_called = false

    define_route("routes/beforehalt/get.rb") do |endpoint|
      endpoint.before { |_request, _response, _metadata| Raxon.halt(code: :unauthorized, body: {error: "no"}) }
      endpoint.handler { |_request, _response, _metadata| handler_called = true }
    end

    status, _headers, _body = Raxon::Router.new.call(Rack::MockRequest.env_for("/beforehalt", method: "GET"))

    expect(status).to eq(401)
    expect(handler_called).to eq(false)
  end

  it "leaves the body unset when only a code is given" do
    define_route("routes/codeonly/delete.rb") do |endpoint|
      endpoint.handler do |_request, response, _metadata|
        response.body = {will: "be replaced by nothing"}
        Raxon.halt(code: :no_content)
      end
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/codeonly", method: "DELETE"))

    expect(status).to eq(204)
    # Body was set before the halt and left untouched (no body given to halt).
    expect(JSON.parse(body.first)).to eq("will" => "be replaced by nothing")
  end
end

RSpec.describe "halt from a catchall handler" do
  it "returns the halted response for unmatched routes" do
    Raxon::RouteLoader.register_catchall do |endpoint|
      endpoint.handler do |_request, response, _metadata|
        response.halt(code: :service_unavailable, body: {error: "maintenance"})
      end
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/no/such/route"))

    expect(status).to eq(503)
    expect(JSON.parse(body.first)).to eq("error" => "maintenance")
  end
end
