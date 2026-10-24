# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exclude_from_openapi" do
  # RouteLoader.load! prepares the routes. That composes each route with the
  # all.rb files above it.
  def paths
    Raxon::RouteLoader.routes.prepare!
    Raxon::OpenApi::DSL.to_open_api["paths"]
  end

  def define_page(file_path, &block)
    define_route(file_path) do |endpoint|
      block&.call(endpoint)
      endpoint.handler { |request, response, metadata| }
    end
  end

  it "leaves an excluded route out of the document" do
    define_page("routes/page/get.rb", &:exclude_from_openapi)
    define_page("routes/api/get.rb")

    expect(paths).not_to have_key("/page")
    expect(paths).to have_key("/api")
  end

  it "applies an all.rb exclusion to the routes below it" do
    define_route("routes/pages/all.rb", &:exclude_from_openapi)
    define_page("routes/pages/get.rb")
    define_page("routes/pages/about/get.rb")

    expect(paths.keys).not_to include("/pages", "/pages/about")
  end

  it "lets a child route come back in" do
    define_route("routes/pages/all.rb", &:exclude_from_openapi)
    define_page("routes/pages/get.rb")
    define_page("routes/pages/feed/get.rb") { |endpoint| endpoint.exclude_from_openapi(false) }

    expect(paths).not_to have_key("/pages")
    expect(paths).to have_key("/pages/feed")
  end

  it "still routes an excluded endpoint" do
    define_route("routes/page/get.rb") do |endpoint|
      endpoint.exclude_from_openapi
      endpoint.handler { |request, response, metadata| response.html_body = "<p>page</p>" }
    end

    status, _headers, body = Raxon::Router.new.call(Rack::MockRequest.env_for("/page"))

    expect(status).to eq(200)
    expect(body.join).to eq("<p>page</p>")
  end
end
