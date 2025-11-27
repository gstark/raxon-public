require_relative "../lib/raxon"

# Configure Raxon to know where to find routes
Raxon.configure do |config|
  config.routes_directory = File.join(__dir__, "routes")
end

# Create the server (uses configured routes_directory)
app = Raxon::Server.new

run app
