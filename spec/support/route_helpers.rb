# Test helper for registering routes at explicit paths.
#
# Production route files use the `Raxon.route` DSL, which infers the route path
# from the call site. Specs need to register routes at arbitrary, explicit paths
# to exercise routing behavior, so they use this helper instead.
module RouteHelpers
  # Register a route at an explicit file path.
  #
  # @param file_path [String] Route file path (e.g. "routes/api/v1/users/get.rb")
  # @param block [Proc] Configuration block receiving the endpoint
  # @return [void]
  def define_route(file_path, &block)
    Raxon::RouteLoader.define(file_path, &block)
  end
end

RSpec.configure do |config|
  config.include RouteHelpers
end
