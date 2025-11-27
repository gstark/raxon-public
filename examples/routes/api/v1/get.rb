Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "API authentication filter - applies to all /api/v1/* routes"

  endpoint.before do |request, response|
    # This before block runs for all child routes under /api/v1
    # In a real app, you'd validate API keys, check auth, etc.
    response.rack_response["X-API-Version"] = "1.0"
  end
end
