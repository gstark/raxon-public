# frozen_string_literal: true

require "spec_helper"
require "active_support/notifications"

RSpec.describe "Router instrumentation", load_routes: true do
  describe "when rails_compatible_instrumentation is disabled" do
    before do
      Raxon.configure do |config|
        config.rails_compatible_instrumentation = false
      end
    end

    it "does not emit action_controller events" do
      router = Raxon::Router.new
      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      router.call(env)

      expect(events).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end
  end

  describe "when rails_compatible_instrumentation is enabled" do
    before do
      Raxon.configure do |config|
        config.rails_compatible_instrumentation = true
      end
    end

    it "emits start_processing.action_controller" do
      router = Raxon::Router.new
      events = []
      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      router.call(env)

      expect(events.size).to eq(1)
      expect(events.first.payload[:controller]).to eq("api/v1/test")
      expect(events.first.payload[:action]).to eq("GET")
    ensure
      ActiveSupport::Notifications.unsubscribe("start_processing.action_controller")
    end

    it "emits process_action.action_controller" do
      router = Raxon::Router.new
      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      env = Rack::MockRequest.env_for("/api/v1/test", method: "GET")
      router.call(env)

      expect(events.size).to eq(1)
      expect(events.first.payload[:status]).to eq(200)
      expect(events.first.payload[:db_runtime]).to be_a(Numeric)
      expect(events.first.payload[:view_runtime]).to eq(0)
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end

    it "includes meaningful duration in process_action event" do
      router = Raxon::Router.new
      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      env = Rack::MockRequest.env_for("/api/v1/slow", method: "GET")
      router.call(env)

      # Duration should include the 10ms sleep in the slow endpoint
      expect(events.first.duration).to be_a(Numeric)
      expect(events.first.duration).to be >= 10
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end

    it "includes exception info when handler raises" do
      router = Raxon::Router.new
      events = []
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      env = Rack::MockRequest.env_for("/api/v1/error", method: "GET")

      expect { router.call(env) }.to raise_error(StandardError, "intentional error for testing")

      expect(events.size).to eq(1)
      expect(events.first.payload[:exception]).to eq(["StandardError", "intentional error for testing"])
    ensure
      ActiveSupport::Notifications.unsubscribe("process_action.action_controller")
    end
  end
end
