# Fixture route for testing ERB loops
Raxon.route do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html(items: ["Apple", "Banana", "Cherry"])
  end
end
