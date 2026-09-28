# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Raxon lifecycle execution" do
  def call_route(path, method: "GET")
    env = Rack::MockRequest.env_for(path, method: method)
    Raxon::Router.new.call(env)
  end

  it "executes global hooks and route hierarchy blocks in the documented order" do
    events = []

    Raxon.configure do |config|
      config.around do |_request, _response, _metadata, &inner|
        events << :global_around_1_before
        inner.call
        events << :global_around_1_after
      end

      config.around do |_request, _response, _metadata, &inner|
        events << :global_around_2_before
        inner.call
        events << :global_around_2_after
      end

      config.before { |_request, _response, _metadata| events << :global_before_1 }
      config.before { |_request, _response, _metadata| events << :global_before_2 }
      config.after { |_request, _response, _metadata| events << :global_after_1 }
      config.after { |_request, _response, _metadata| events << :global_after_2 }
    end

    define_route("routes/api/all.rb") do |endpoint|
      endpoint.metadata { |_request, _response, metadata|
        events << :parent_metadata
        metadata[:parent] = true
      }
      endpoint.before { |_request, _response, metadata| events << :parent_before if metadata[:parent] }
      endpoint.after { |_request, _response, metadata| events << :parent_after if metadata[:child] }
      endpoint.handler { |_request, _response, _metadata| events << :parent_all_handler }
    end

    define_route("routes/api/users/get.rb") do |endpoint|
      endpoint.metadata { |_request, _response, metadata|
        events << :child_metadata
        metadata[:child] = true
      }
      endpoint.before { |_request, _response, metadata| events << :child_before if metadata[:parent] }
      endpoint.after { |_request, _response, metadata| events << :child_after if metadata[:child] }
      endpoint.handler do |_request, response, metadata|
        events << :child_handler if metadata[:parent] && metadata[:child]
        response.body = {ok: true}
      end
    end

    status, = call_route("/api/users")

    expect(status).to eq(200)
    expect(events).to eq([
      :global_around_1_before,
      :global_around_2_before,
      :global_before_1,
      :global_before_2,
      :parent_metadata,
      :child_metadata,
      :parent_before,
      :child_before,
      :child_handler,
      :child_after,
      :parent_after,
      :global_after_1,
      :global_after_2,
      :global_around_2_after,
      :global_around_1_after
    ])
  end

  it "uses an all.rb handler as the final handler when no method-specific route is more specific" do
    events = []

    define_route("routes/api/all.rb") do |endpoint|
      endpoint.before { |_request, _response, _metadata| events << :all_before }
      endpoint.handler do |_request, response, _metadata|
        events << :all_handler
        response.body = {ok: true}
      end
      endpoint.after { |_request, _response, _metadata| events << :all_after }
    end

    status, = call_route("/api", method: "POST")

    expect(status).to eq(200)
    expect(events).to eq([:all_before, :all_handler, :all_after])
  end

  it "treats parent all.rb handlers as lifecycle-only when a child method handler matches" do
    events = []

    define_route("routes/api/all.rb") do |endpoint|
      endpoint.before { |_request, _response, _metadata| events << :parent_all_before }
      endpoint.handler { |_request, _response, _metadata| events << :parent_all_handler }
      endpoint.after { |_request, _response, _metadata| events << :parent_all_after }
    end

    define_route("routes/api/users/get.rb") do |endpoint|
      endpoint.handler do |_request, response, _metadata|
        events << :child_get_handler
        response.body = {ok: true}
      end
    end

    status, = call_route("/api/users")

    expect(status).to eq(200)
    expect(events).to eq([:parent_all_before, :child_get_handler, :parent_all_after])
  end

  it "stops later lifecycle steps when a before block halts" do
    events = []

    Raxon.configure do |config|
      config.before { |_request, _response, _metadata| events << :global_before }
      config.after { |_request, _response, _metadata| events << :global_after }
    end

    define_route("routes/api/all.rb") do |endpoint|
      endpoint.metadata { |_request, _response, _metadata| events << :parent_metadata }
      endpoint.before do |_request, response, _metadata|
        events << :parent_before
        response.halt(code: :unauthorized, body: {error: "nope"})
      end
      endpoint.after { |_request, _response, _metadata| events << :parent_after }
    end

    define_route("routes/api/users/get.rb") do |endpoint|
      endpoint.metadata { |_request, _response, _metadata| events << :child_metadata }
      endpoint.before { |_request, _response, _metadata| events << :child_before }
      endpoint.handler { |_request, _response, _metadata| events << :child_handler }
      endpoint.after { |_request, _response, _metadata| events << :child_after }
    end

    status, _headers, body = call_route("/api/users")

    expect(status).to eq(401)
    expect(JSON.parse(body.first)).to eq("error" => "nope")
    expect(events).to eq([
      :global_before,
      :parent_metadata,
      :child_metadata,
      :parent_before
    ])
  end

  it "runs catchall routes through the same global and route lifecycle" do
    events = []

    Raxon.configure do |config|
      config.around do |_request, _response, _metadata, &inner|
        events << :around_before
        inner.call
        events << :around_after
      end
      config.before { |_request, _response, _metadata| events << :global_before }
      config.after { |_request, _response, _metadata| events << :global_after }
    end

    Raxon::RouteLoader.register_catchall do |endpoint|
      endpoint.metadata { |_request, _response, metadata|
        events << :catchall_metadata
        metadata[:catchall] = true
      }
      endpoint.before { |_request, _response, metadata| events << :catchall_before if metadata[:catchall] }
      endpoint.handler do |_request, response, metadata|
        events << :catchall_handler if metadata[:catchall]
        response.code = :not_found
        response.body = {error: "missing"}
      end
      endpoint.after { |_request, _response, metadata| events << :catchall_after if metadata[:catchall] }
    end

    status, _headers, body = call_route("/missing")

    expect(status).to eq(404)
    expect(JSON.parse(body.first)).to eq("error" => "missing")
    expect(events).to eq([
      :around_before,
      :global_before,
      :catchall_metadata,
      :catchall_before,
      :catchall_handler,
      :catchall_after,
      :global_after,
      :around_after
    ])
  end
end
