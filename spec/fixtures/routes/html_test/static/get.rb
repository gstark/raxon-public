# Fixture route for testing template with no variables
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html
  end
end
