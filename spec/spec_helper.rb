require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_filter "/lib/openapi-dsl/"
  enable_coverage :branch
end

require "raxon"

# unicode_utils 1.4.0 (tty-table → strings) has an unused variable in this
# file, and the gem is unmaintained. `config.warnings = true` below sets
# $VERBOSE, so loading it mid-suite prints a parse warning we cannot fix.
# Parsing it here, while $VERBOSE is still off, keeps the run clean without
# suppressing any warning from this repo's own code.
require "unicode_utils/each_grapheme"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true

  if config.files_to_run.one?
    config.default_formatter = "doc"
  end

  config.order = :random
  Kernel.srand config.seed

  # Reset routes and configuration before each test
  config.before(:each) do
    Raxon.reset!
    Raxon.configure do |config|
      config.routes_directory = "routes"
      # The suite runs in the development environment, where hot reloading
      # defaults on; keep it off so routers don't watch the filesystem.
      # Reloader specs enable it explicitly.
      config.reload_routes = false
    end
  end

  # Load fixture routes when load_routes: true is set on a spec
  config.before(:each, load_routes: true) do
    routes_dir = File.join(__dir__, "fixtures", "routes")
    Raxon.configure do |config|
      config.routes_directory = routes_dir
    end
    Raxon::RouteLoader.load!
  end
end
