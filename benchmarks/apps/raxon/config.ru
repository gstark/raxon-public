# frozen_string_literal: true

require "raxon"

Raxon.configure do |config|
  config.routes_directory = File.expand_path("routes", __dir__)
end

Raxon::RouteLoader.reset!
Raxon::RouteLoader.load!

run Raxon::Server.new
