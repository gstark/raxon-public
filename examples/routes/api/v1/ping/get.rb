Raxon::OpenApi::DSL.component "Ping", type: :object do |component|
  component.property :id, type: :string, description: "Ping ID"
  component.property :message, type: :string, description: "Ping message"
end

Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Returns an affirmative ping to validate the API is up and your API key is valid"

  endpoint.response 200, type: :object, as: "Ping"

  endpoint.before do |request, response|
    response.header "X-API-Key", "secret"
  end

  endpoint.handler do |request, response|
    response.code = :ok
    response.body = {id: "ping", message: "pong"}
  end
end
