Raxon.route do
  description "API authentication filter - applies to all /api/v1/* routes"

  before do |_request, response|
    # This before block runs for all child routes under /api/v1.
    # In a real app, you'd validate API keys, check auth, etc.
    response.header "X-API-Version", "1.0"
  end
end
