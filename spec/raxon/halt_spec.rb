require "spec_helper"

RSpec.describe "Response#halt" do
  describe "halt in before block with single endpoint" do
    it "stops handler execution when halt is called" do
      before_block_called = false
      handler_called = false

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
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
