# Fixture route for testing HTML rendering with local variables
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html(title: "Welcome", name: "John")
  end
end
