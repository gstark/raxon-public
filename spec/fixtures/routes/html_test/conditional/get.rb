# Fixture route for testing ERB conditionals
Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html(show_message: true, message: "Hello!")
  end
end
