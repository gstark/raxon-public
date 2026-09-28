# frozen_string_literal: true

require "spec_helper"
require "active_support"
require "active_support/notifications"

RSpec.describe "Instrumentation and the request body" do
  before do
    Raxon.configuration.rails_compatible_instrumentation = true
    Raxon::OpenApi::DSL.security_scheme(:key, type: :apiKey, name: "X-Key", in: :header) do |request, _metadata|
      request.header("HTTP_X_KEY") == "good"
    end
    define_route("routes/widgets/post.rb") do |endpoint|
      endpoint.security :key
      endpoint.body type: :object do |body|
        body.property :name, type: :string
      end
      endpoint.handler { |request, response, _metadata| response.ok(request.params) }
    end
  end

  def post(headers = {})
    env = Rack::MockRequest.env_for("/widgets?page=2", {:method => "POST",
                                                        :input => {name: "Ada"}.to_json, "CONTENT_TYPE" => "application/json"}.merge(headers))
    Raxon::Router.new.call(env)
  end

  def events_for(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| events << ActiveSupport::Notifications::Event.new(*args) }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "does not parse the body of an unauthenticated request" do
    expect(JSON).not_to receive(:parse)

    events = events_for("process_action.action_controller") { expect(post.first).to eq(401) }

    expect(events.first.payload[:params]).to eq(page: "2")
  end

  it "reports the resolved params once the handler ran" do
    started = nil
    finished = events_for("process_action.action_controller") do
      started = events_for("start_processing.action_controller") { post("HTTP_X_KEY" => "good") }
    end

    expect(started.first.payload[:params]).to eq(page: "2")
    expect(finished.first.payload[:params]).to eq(name: "Ada")
  end
end
