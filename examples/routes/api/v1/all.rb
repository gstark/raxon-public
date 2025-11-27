# Example all.rb file that handles all HTTP methods for /api/v1/*
#
# This file demonstrates the all.rb functionality, which allows you to define
# handlers that run for all HTTP methods (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS).
#
# all.rb files are processed before method-specific handlers in the hierarchy,
# from shallowest to deepest nesting. This makes them ideal for:
# - Authentication/authorization
# - Logging and monitoring
# - Setting common response headers
# - Rate limiting
# - Request validation

Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Global handler for all /api/v1/* requests"

  # This handler will execute for ALL HTTP methods on any /api/v1/* route
  # before the specific method handler runs
  endpoint.handler do |request, response|
    # Example: Add a custom header to all responses
    response.rack_response.headers["X-API-Version"] = "v1"

    # Example: Log all requests (in a real app, you'd use a proper logger)
    # puts "[#{Time.now}] #{request.rack_request.request_method} #{request.rack_request.path}"

    # You can also perform authentication, authorization, etc. here
    # and call halt() if needed to stop processing
  end
end
