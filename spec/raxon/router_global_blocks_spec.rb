# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon::Router global blocks" do
  before do
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
  end

  describe "global before blocks" do
    it "executes global before blocks before route handlers" do
      execution_order = []

      Raxon.configure do |config|
        config.before { |request, response, metadata| execution_order << :global_before }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:global_before, :handler])
    end

    it "executes multiple global before blocks in order" do
      execution_order = []

      Raxon.configure do |config|
        config.before { |request, response, metadata| execution_order << :global_before_1 }
        config.before { |request, response, metadata| execution_order << :global_before_2 }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:global_before_1, :global_before_2, :handler])
    end

    it "executes global before blocks before route-specific before blocks" do
      execution_order = []

      Raxon.configure do |config|
        config.before { |request, response, metadata| execution_order << :global_before }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.before { |request, response, metadata| execution_order << :route_before }
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:global_before, :route_before, :handler])
    end

    it "can set metadata in global before blocks" do
      received_metadata = nil

      Raxon.configure do |config|
        config.before { |request, response, metadata| metadata[:global_key] = "global_value" }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata.dup
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata[:global_key]).to eq("global_value")
    end

    it "can halt in global before blocks" do
      handler_called = false

      Raxon.configure do |config|
        config.before do |request, response, metadata|
          response.code = :forbidden
          response.body = {error: "Forbidden"}
          response.halt
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          handler_called = true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(handler_called).to be false
      expect(status).to eq(403)
      expect(JSON.parse(body.first)["error"]).to eq("Forbidden")
    end
  end

  describe "global after blocks" do
    it "executes global after blocks after route handlers" do
      execution_order = []

      Raxon.configure do |config|
        config.after { |request, response, metadata| execution_order << :global_after }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:handler, :global_after])
    end

    it "executes multiple global after blocks in order" do
      execution_order = []

      Raxon.configure do |config|
        config.after { |request, response, metadata| execution_order << :global_after_1 }
        config.after { |request, response, metadata| execution_order << :global_after_2 }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:handler, :global_after_1, :global_after_2])
    end

    it "executes global after blocks after route-specific after blocks" do
      execution_order = []

      Raxon.configure do |config|
        config.after { |request, response, metadata| execution_order << :global_after }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.after { |request, response, metadata| execution_order << :route_after }
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:handler, :route_after, :global_after])
    end

    it "can read metadata in global after blocks" do
      received_metadata = nil

      Raxon.configure do |config|
        config.before { |request, response, metadata| metadata[:start_time] = "12:00" }
        config.after { |request, response, metadata| received_metadata = metadata.dup }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          metadata[:handler_ran] = true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata[:start_time]).to eq("12:00")
      expect(received_metadata[:handler_ran]).to be true
    end

    it "can modify response in global after blocks" do
      Raxon.configure do |config|
        config.after do |request, response, metadata|
          response.header "X-Custom-Header", "custom_value"
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      _, headers, _ = Raxon::Router.new.call(env)

      expect(headers["X-Custom-Header"]).to eq("custom_value")
    end
  end

  describe "global around blocks" do
    it "wraps request execution" do
      execution_order = []

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          execution_order << :around_before
          inner.call
          execution_order << :around_after
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:around_before, :handler, :around_after])
    end

    it "executes multiple around blocks with first registered as outermost" do
      execution_order = []

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          execution_order << :outer_before
          inner.call
          execution_order << :outer_after
        end
        config.around do |request, response, metadata, &inner|
          execution_order << :inner_before
          inner.call
          execution_order << :inner_after
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([
        :outer_before, :inner_before, :handler, :inner_after, :outer_after
      ])
    end

    it "around blocks wrap global before/after blocks" do
      execution_order = []

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          execution_order << :around_before
          inner.call
          execution_order << :around_after
        end
        config.before { |request, response, metadata| execution_order << :global_before }
        config.after { |request, response, metadata| execution_order << :global_after }
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([
        :around_before, :global_before, :handler, :global_after, :around_after
      ])
    end

    it "can set metadata in around blocks" do
      received_metadata = nil

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          metadata[:around_key] = "around_value"
          inner.call
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          received_metadata = metadata.dup
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      Raxon::Router.new.call(env)

      expect(received_metadata[:around_key]).to eq("around_value")
    end

    it "can choose not to call inner block" do
      handler_called = false

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          response.code = :service_unavailable
          response.body = {error: "Maintenance mode"}
          # Not calling inner.call
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          handler_called = true
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(handler_called).to be false
      expect(status).to eq(503)
      expect(JSON.parse(body.first)["error"]).to eq("Maintenance mode")
    end

    it "can wrap execution in a begin/rescue" do
      error_caught = nil

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          inner.call
        rescue => e
          error_caught = e.message
          response.code = :internal_server_error
          response.body = {error: "Something went wrong"}
        end
      end

      Raxon::RouteLoader.register("routes/test/get.rb") do |endpoint|
        endpoint.handler do |request, response, metadata|
          raise "Test error"
        end
      end

      env = Rack::MockRequest.env_for("/test", method: "GET")
      status, _, body = Raxon::Router.new.call(env)

      expect(error_caught).to eq("Test error")
      expect(status).to eq(500)
      expect(JSON.parse(body.first)["error"]).to eq("Something went wrong")
    end
  end

  describe "full execution order" do
    it "executes all blocks in correct order" do
      execution_order = []

      Raxon.configure do |config|
        config.around do |request, response, metadata, &inner|
          execution_order << :around_before
          inner.call
          execution_order << :around_after
        end
        config.before { |request, response, metadata| execution_order << :global_before }
        config.after { |request, response, metadata| execution_order << :global_after }
      end

      Raxon::RouteLoader.register("routes/api/get.rb") do |endpoint|
        endpoint.metadata { |request, response, metadata| execution_order << :parent_metadata }
        endpoint.before { |request, response, metadata| execution_order << :parent_before }
        endpoint.after { |request, response, metadata| execution_order << :parent_after }
      end

      Raxon::RouteLoader.register("routes/api/users/get.rb") do |endpoint|
        endpoint.metadata { |request, response, metadata| execution_order << :child_metadata }
        endpoint.before { |request, response, metadata| execution_order << :child_before }
        endpoint.after { |request, response, metadata| execution_order << :child_after }
        endpoint.handler do |request, response, metadata|
          execution_order << :handler
          response.code = :ok
          response.body = {success: true}
        end
      end

      env = Rack::MockRequest.env_for("/api/users", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([
        :around_before,
        :global_before,
        :parent_metadata,
        :child_metadata,
        :parent_before,
        :child_before,
        :handler,
        :child_after,
        :parent_after,
        :global_after,
        :around_after
      ])
    end
  end

  describe "catchall endpoint" do
    it "executes global blocks for catchall endpoint" do
      execution_order = []

      Raxon.configure do |config|
        config.before { |request, response, metadata| execution_order << :global_before }
        config.after { |request, response, metadata| execution_order << :global_after }
      end

      Raxon::RouteLoader.register_catchall do |endpoint|
        endpoint.handler do |request, response, metadata|
          execution_order << :catchall_handler
          response.code = :not_found
          response.body = {error: "Not found"}
        end
      end

      env = Rack::MockRequest.env_for("/nonexistent", method: "GET")
      Raxon::Router.new.call(env)

      expect(execution_order).to eq([:global_before, :catchall_handler, :global_after])
    end
  end
end
