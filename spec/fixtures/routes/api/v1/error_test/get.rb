Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Test endpoint that raises an error"

  endpoint.response 200, type: :object do |response|
    response.property :success, type: :boolean, description: "Success status"
  end

  endpoint.handler do |request, response|
    raise StandardError, "Intentional test error"
  end
end
