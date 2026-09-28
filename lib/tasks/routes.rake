# frozen_string_literal: true

require_relative "../raxon/routes_formatter"

namespace :raxon do
  desc "Display all registered routes"
  task routes: "raxon:routes:load" do
    Raxon::RoutesFormatter.display
  end
end
