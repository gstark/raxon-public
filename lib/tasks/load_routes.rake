# frozen_string_literal: true

namespace :raxon do
  namespace :routes do
    task :load do
      require_relative "../raxon"

      # Reset and load routes
      Raxon::RouteLoader.reset!
      Raxon::RouteLoader.load!

      puts "Loaded #{Raxon::RouteLoader.routes.size} route(s)"
    end
  end
end
