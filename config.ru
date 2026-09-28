# frozen_string_literal: true

require_relative "lib/raxon"

# Create the server with routes from examples directory
server = Raxon::Server.new(routes_directory: "examples/routes") do |app|
  # Add error handling middleware (recommended for production)
  app.use Raxon::ErrorHandler, logger: Logger.new($stdout)

  # Add optional middleware here
  # app.use Rack::Logger
  # app.use Rack::CommonLogger
end

# Run the server
run server
