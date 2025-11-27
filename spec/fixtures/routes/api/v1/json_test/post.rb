Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Test endpoint for JSON validation"

  endpoint.request_body type: :object, description: "Test data", required: true do |body|
    body.property :message, type: :string, description: "Test message"
  end

  endpoint.response 200, type: :object do |response|
    response.property :success, type: :boolean, description: "Success status"
  end

  endpoint.handler do |request, response|
    response.code = :ok
    response.body = {success: true}
  end
end
