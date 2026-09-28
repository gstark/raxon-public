Raxon::OpenApi::DSL.component "Ping", type: :object do |component|
  component.property :id, type: :string, description: "Ping ID"
  component.property :message, type: :string, description: "Ping message"
end

Raxon.route do
  description "Returns an affirmative ping to validate the API is up and your API key is valid"

  response 200, type: :object, as: "Ping"

  handler do |_request, response|
    response.ok(id: "ping", message: "pong")
  end
end
