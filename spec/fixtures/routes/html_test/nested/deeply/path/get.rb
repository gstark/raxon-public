# Fixture route for testing nested route structure
Raxon.route do |endpoint|
  endpoint.handler do |request, response|
    response.code = :ok
    response.html_body = response.html(message: "Nested route works")
  end
end
