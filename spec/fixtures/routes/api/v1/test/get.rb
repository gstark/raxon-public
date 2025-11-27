Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Test endpoint for specs"

  endpoint.response 200, type: :object do |response|
    response.property :test, type: :boolean, description: "true if test was successful"
  end

  endpoint.handler do |request, response|
    response.code = :ok
    response.body = {test: true}
  end
end
