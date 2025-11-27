# Fixture route for testing ERB loops
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html(items: ["Apple", "Banana", "Cherry"])
  end
end
