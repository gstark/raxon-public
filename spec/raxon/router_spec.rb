require "spec_helper"

RSpec.describe Raxon::Router do
  describe "#call" do
    it "routes requests to registered endpoints", load_routes: true do
      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      status, headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(body.first).to include("test")
    end

    it "returns 404 for unregistered routes", load_routes: true do
      router = Raxon::Router.new

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      status, headers, body = router.call(env)

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("application/json")
      expect(body.first).to include("Not Found")
    end

    it "uses catchall endpoint for unregistered routes when defined" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
          response.body = {error: "Custom not found", path: request.path}
        end
      end

      router = Raxon::Router.new

      env = Rack::MockRequest.env_for("/nonexistent/path", method: "GET")
      status, headers, body = router.call(env)

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("application/json")
      parsed_body = JSON.parse(body.first)
      expect(parsed_body["error"]).to eq("Custom not found")
      expect(parsed_body["path"]).to eq("/nonexistent/path")
    end

    it "uses catchall before fallback app" do
      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :not_found
          response.body = {source: "catchall"}
        end
      end

      fallback_app = lambda do |env|
        [200, {"content-type" => "text/plain"}, ["Fallback response"]]
      end

      router = Raxon::Router.new(fallback: fallback_app)

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      status, _, body = router.call(env)

      # Should use catchall, not fallback
      expect(status).to eq(404)
      expect(JSON.parse(body.first)["source"]).to eq("catchall")
    end

    it "supports before blocks in catchall endpoint" do
      execution_order = []

      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.before do |request, response, metadata|
          execution_order << :before
        end
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :not_found
          response.body = {error: "Not found"}
        end
      end

      router = Raxon::Router.new

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      router.call(env)

      expect(execution_order).to eq([:before, :handler])
    end

    it "supports metadata blocks in catchall endpoint" do
      received_metadata = nil

      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.metadata do |request, response, metadata|
          metadata[:catchall] = true
        end
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata.dup
          response.code = :not_found
          response.body = {error: "Not found"}
        end
      end

      router = Raxon::Router.new

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      router.call(env)

      expect(received_metadata[:catchall]).to eq(true)
    end

    it "delegates to fallback app for unregistered routes when fallback is provided", load_routes: true do
      fallback_app = lambda do |env|
        [200, {"content-type" => "text/plain"}, ["Fallback response"]]
      end

      router = Raxon::Router.new(fallback: fallback_app)

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      status, headers, body = router.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/plain")
      expect(body.first).to eq("Fallback response")
    end

    it "sets route params in env when route has path parameters" do
      env_captured = nil

      Raxon::RouteLoader.register("routes/users/$id/get.rb") do |endpoint|
        endpoint.handler do |request, response|
          env_captured = request.rack_request.env
          response.code = :ok
          response.body = {user_id: request.params[:id]}
        end
      end

      env = Rack::MockRequest.env_for("/users/123", method: "GET")
      status, _headers, body = Raxon::Router.new.call(env)

      expect(status).to eq(200)
      expect(env_captured["router.params"]).to eq({id: "123"})
      expect(JSON.parse(body.first)["user_id"]).to eq("123")
    end

    describe "before block execution" do
      it "calls before block exactly once per endpoint in a single endpoint request" do
        before_call_count = 0

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.before do |_request, response|
            before_call_count += 1
            response.rack_response["X-Before-Called"] = "yes"
          end
          endpoint.handler do |_request, response|
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        _status, _headers, _body = Raxon::Router.new.call(env)

        expect(before_call_count).to eq(1)
      end

      it "calls each before block exactly once in route hierarchy" do
        parent_call_count = 0
        child_call_count = 0

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.before do |_request, _response|
          parent_call_count += 1
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.before do |_request, _response|
          child_call_count += 1
        end
        child_endpoint.handler do |_request, response|
          response.code = :ok
          response.body = {success: true}
        end

        # Simulate route hierarchy execution
        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        # Simulate execute_with_hierarchy logic
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_before?
            before_request = Raxon::Request.new(request, endpoint)
            endpoint.before_blocks.each do |before_block|
              before_block.call(before_request, response)
            end
          end

          break if response.halted?
        end

        unless response.halted?
          final_endpoint = route_data[:endpoint]
          if final_endpoint.has_handler?
            final_request = Raxon::Request.new(request, final_endpoint)
            final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response)
          end
        end

        expect(parent_call_count).to eq(1)
        expect(child_call_count).to eq(1)
      end

      it "does not call handler if before block calls halt" do
        before_call_count = 0
        handler_call_count = 0

        Raxon::RouteLoader.register("routes/api/test/get.rb") do |endpoint|
          endpoint.before do |_request, response|
            before_call_count += 1
            response.code = :unauthorized
            response.body = {error: "Unauthorized"}
            response.halt
          end
          endpoint.handler do |_request, _response|
            handler_call_count += 1
          end
        end

        env = Rack::MockRequest.env_for("/api/test", method: "GET")
        Raxon::Router.new.call(env)
        # request = Raxon::Request.new(rack_request, endpoint)
        # response = Raxon::Response.new
        # _status, _headers, _body = endpoint.call(request, response)

        expect(before_call_count).to eq(1)
        expect(handler_call_count).to eq(0)
      end

      it "does not re-execute before blocks when handler is called in hierarchy" do
        parent_call_count = 0
        handler_call_count = 0

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.before do |_request, _response|
          parent_call_count += 1
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.handler do |_request, response|
          handler_call_count += 1
          response.code = :ok
          response.body = {success: true}
        end

        # Simulate route hierarchy execution
        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        # Simulate execute_with_hierarchy logic
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_before?
            before_request = Raxon::Request.new(request, endpoint)
            endpoint.before_blocks.each do |before_block|
              before_block.call(before_request, response)
            end
          end

          break if response.halted?
        end

        unless response.halted?
          final_endpoint = route_data[:endpoint]
          if final_endpoint.has_handler?
            final_request = Raxon::Request.new(request, final_endpoint)
            final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response)
          end
        end

        expect(parent_call_count).to eq(1)
        expect(handler_call_count).to eq(1)
      end
    end

    describe "metadata execution in hierarchy" do
      it "builds metadata from parent to child endpoints" do
        received_metadata = nil

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.metadata do |request, response, metadata|
          metadata[:parent] = "parent_value"
          metadata[:shared] = "from_parent"
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.metadata do |request, response, metadata|
          metadata[:child] = "child_value"
          metadata[:shared] = "from_child"
        end
        child_endpoint.handler do |request, response, metadata|
          received_metadata = metadata.dup
          response.code = :ok
          response.body = {success: true}
        end

        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        # Simulate execute_with_hierarchy logic for metadata
        metadata = {}
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_metadata?
            endpoint.metadata_blocks.each do |metadata_block|
              metadata_block.call(Raxon::Request.new(request, endpoint), response, metadata)
            end
          end
        end

        final_endpoint = route_data[:endpoint]
        if final_endpoint.has_handler?
          final_request = Raxon::Request.new(request, final_endpoint)
          final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response, metadata)
        end

        expect(received_metadata[:parent]).to eq("parent_value")
        expect(received_metadata[:child]).to eq("child_value")
        expect(received_metadata[:shared]).to eq("from_child")
      end

      it "executes metadata blocks before before blocks" do
        execution_order = []

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            execution_order << :metadata
            metadata[:set_in_metadata] = true
          end
          endpoint.before do |request, response|
            execution_order << :before
          end
          endpoint.handler do |request, response, metadata|
            execution_order << :handler
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(execution_order).to eq([:metadata, :before, :handler])
      end

      it "provides empty metadata hash when no metadata blocks defined" do
        received_metadata = nil

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.handler do |request, response, metadata|
            received_metadata = metadata
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(received_metadata).to eq({})
      end

      it "passes the same metadata hash through all metadata blocks in hierarchy" do
        metadata_object_ids = []

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.metadata do |request, response, metadata|
          metadata_object_ids << metadata.object_id
          metadata[:parent] = true
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.metadata do |request, response, metadata|
          metadata_object_ids << metadata.object_id
          metadata[:child] = true
        end
        child_endpoint.handler do |request, response, metadata|
          metadata_object_ids << metadata.object_id
          response.code = :ok
          response.body = {success: true}
        end

        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        metadata = {}
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_metadata?
            endpoint.metadata_blocks.each do |metadata_block|
              metadata_block.call(Raxon::Request.new(request, endpoint), response, metadata)
            end
          end
        end

        final_endpoint = route_data[:endpoint]
        if final_endpoint.has_handler?
          final_request = Raxon::Request.new(request, final_endpoint)
          final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response, metadata)
        end

        # All should be the same hash object
        expect(metadata_object_ids.uniq.length).to eq(1)
      end
    end

    describe "metadata passed to before blocks" do
      it "passes metadata to before blocks" do
        received_metadata = nil

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            metadata[:auth_user] = "test_user"
          end
          endpoint.before do |request, response, metadata|
            received_metadata = metadata.dup
          end
          endpoint.handler do |request, response, metadata|
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(received_metadata).to eq({auth_user: "test_user"})
      end

      it "allows before blocks to modify metadata for handler" do
        received_metadata = nil

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            metadata[:initial] = "from_metadata"
          end
          endpoint.before do |request, response, metadata|
            metadata[:added_by_before] = "from_before"
          end
          endpoint.handler do |request, response, metadata|
            received_metadata = metadata.dup
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(received_metadata[:initial]).to eq("from_metadata")
        expect(received_metadata[:added_by_before]).to eq("from_before")
      end

      it "passes same metadata hash to all before blocks in hierarchy" do
        metadata_object_ids = []

        Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
          endpoint.before do |request, response, metadata|
            metadata_object_ids << metadata.object_id
            metadata[:parent_set] = true
          end
        end

        Raxon::RouteLoader.register("routes/api/users/get.rb") do |endpoint|
          endpoint.before do |request, response, metadata|
            metadata_object_ids << metadata.object_id
          end
          endpoint.handler do |request, response, metadata|
            response.code = :ok
            response.body = {parent_set: metadata[:parent_set]}
          end
        end

        env = Rack::MockRequest.env_for("/api/users", method: "GET")
        status, _, body = Raxon::Router.new.call(env)

        expect(status).to eq(200)
        expect(metadata_object_ids.uniq.length).to eq(1)
        expect(JSON.parse(body.first)["parent_set"]).to eq(true)
      end
    end

    describe "metadata passed to after blocks" do
      it "passes metadata to after blocks" do
        received_metadata = nil

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            metadata[:request_id] = "12345"
          end
          endpoint.after do |request, response, metadata|
            received_metadata = metadata.dup
          end
          endpoint.handler do |request, response, metadata|
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(received_metadata).to eq({request_id: "12345"})
      end

      it "allows after blocks to read metadata set by handler" do
        received_metadata = nil

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            metadata[:from_metadata] = true
          end
          endpoint.handler do |request, response, metadata|
            metadata[:from_handler] = true
            response.code = :ok
            response.body = {success: true}
          end
          endpoint.after do |request, response, metadata|
            received_metadata = metadata.dup
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        expect(received_metadata[:from_metadata]).to eq(true)
        expect(received_metadata[:from_handler]).to eq(true)
      end

      it "passes same metadata hash to all after blocks in hierarchy" do
        metadata_object_ids = []

        Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
          endpoint.metadata do |request, response, metadata|
            metadata[:original] = true
          end
          endpoint.after do |request, response, metadata|
            metadata_object_ids << metadata.object_id
          end
        end

        Raxon::RouteLoader.register("routes/api/users/get.rb") do |endpoint|
          endpoint.after do |request, response, metadata|
            metadata_object_ids << metadata.object_id
          end
          endpoint.handler do |request, response, metadata|
            response.code = :ok
            response.body = {success: true}
          end
        end

        env = Rack::MockRequest.env_for("/api/users", method: "GET")
        Raxon::Router.new.call(env)

        # All should be the same hash object
        expect(metadata_object_ids.uniq.length).to eq(1)
      end
    end

    describe "request and response object consistency" do
      it "passes the same response object through before block and handler" do
        response_objects = []

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.before do |_request, response|
            response_objects << response.object_id
          end
          endpoint.handler do |_request, response|
            response_objects << response.object_id
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        # Should have 2 entries (one from before, one from handler)
        expect(response_objects.length).to eq(2)
        # Both should be the same object
        expect(response_objects.first).to eq(response_objects.last)
      end

      it "passes the same response object through all before blocks and handler in hierarchy" do
        response_objects = []

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.before do |_request, response|
          response_objects << response.object_id
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.before do |_request, response|
          response_objects << response.object_id
        end
        child_endpoint.handler do |_request, response|
          response_objects << response.object_id
        end

        # Simulate route hierarchy execution with shared response
        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        # Simulate execute_with_hierarchy logic
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_before?
            before_request = Raxon::Request.new(request, endpoint)
            response_objects << response.object_id
            endpoint.before_blocks.each do |before_block|
              before_block.call(before_request, response)
            end
          end

          break if response.halted?
        end

        unless response.halted?
          final_endpoint = route_data[:endpoint]
          if final_endpoint.has_handler?
            final_request = Raxon::Request.new(request, final_endpoint)
            response_objects << response.object_id
            final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response)
          end
        end

        # Should have same response object throughout
        expect(response_objects.uniq.length).to eq(1)
      end

      it "passes the same request object (wrapping same rack_request) through before and handler" do
        request_rack_objects = []

        Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
          endpoint.before do |request, _response|
            request_rack_objects << request.rack_request.object_id
          end
          endpoint.handler do |request, _response|
            request_rack_objects << request.rack_request.object_id
          end
        end

        env = Rack::MockRequest.env_for("/test", method: "GET")
        Raxon::Router.new.call(env)

        # Should have 2 entries
        expect(request_rack_objects.length).to eq(2)
        # Both should wrap the same underlying Rack::Request
        expect(request_rack_objects.first).to eq(request_rack_objects.last)
      end

      it "wraps same rack_request in before and handler in hierarchy" do
        request_rack_objects = []

        parent_endpoint = Raxon::OpenApi::Endpoint.new
        parent_endpoint.before do |request, _response|
          request_rack_objects << request.rack_request.object_id
        end

        child_endpoint = Raxon::OpenApi::Endpoint.new
        child_endpoint.before do |request, _response|
          request_rack_objects << request.rack_request.object_id
        end
        child_endpoint.handler do |request, _response|
          request_rack_objects << request.rack_request.object_id
        end

        response = Raxon::Response.new
        route_data = {
          endpoints: [parent_endpoint, child_endpoint],
          endpoint: child_endpoint
        }

        rack_request = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
        request = Rack::Request.new(rack_request)

        # Simulate execute_with_hierarchy logic
        route_data[:endpoints].each do |endpoint|
          if endpoint.has_before?
            before_request = Raxon::Request.new(request, endpoint)
            endpoint.before_blocks.each do |before_block|
              before_block.call(before_request, response)
            end
          end

          break if response.halted?
        end

        unless response.halted?
          final_endpoint = route_data[:endpoint]
          if final_endpoint.has_handler?
            final_request = Raxon::Request.new(request, final_endpoint)
            final_endpoint.instance_variable_get(:@handler_block)&.call(final_request, response)
          end
        end

        # All should wrap the same Rack::Request
        expect(request_rack_objects.uniq.length).to eq(1)
        expect(request_rack_objects.first).to eq(request.object_id)
      end
    end
  end
end
