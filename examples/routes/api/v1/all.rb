# Example all.rb file that handles all HTTP methods for /api/v1/*
#
# An all.rb registers an endpoint for every HTTP method at its path. For a
# request to a deeper path, only its metadata, before, and after blocks run.
#
# Its handler runs only when no more specific route file matches, so put
# shared checks in before blocks. Parent before blocks run first, from
# shallowest to deepest nesting. This makes them ideal for:
# - Authentication/authorization
# - Logging and monitoring
# - Setting common response headers
# - Rate limiting
# - Request validation

Raxon.route do
  description "Global handler for all /api/v1/* requests"

  # This before block executes for ALL HTTP methods on any /api/v1/* route
  # before the specific method handler runs.
  before do |request, response|
    # Example: Add a custom header to all responses.
    response.header "X-API-Version", "v1"

    # Example: Log all requests (in a real app, you'd use a proper logger).
    # puts "[#{Time.now}] #{request.method} #{request.path}"

    # You can also perform authentication, authorization, etc. here
    # and call halt() if needed to stop processing.
  end
end
