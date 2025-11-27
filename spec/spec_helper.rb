require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_filter "/lib/openapi-dsl/"
  enable_coverage :branch
end

require "raxon"

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
    Raxon.instance_variable_set(:@configuration, Raxon::Configuration.new)
    Raxon.configure do |config|
      config.routes_directory = "routes"
    end
    Raxon::RouteLoader.reset!
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
