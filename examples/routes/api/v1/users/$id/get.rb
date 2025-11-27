Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Retrieves a specific user by ID"

  endpoint.parameters do |params|
    params.define :id, type: :string, in: :path, description: "The user ID", required: true
  end

  endpoint.response 200, type: :object do |response|
    response.property :id, type: :string, description: "User ID"
    response.property :username, type: :string, description: "Username"
    response.property :email, type: :string, description: "Email address"
  end

  endpoint.response 404, type: :object do |response|
    response.property :error, type: :string, description: "Error message"
  end

  endpoint.handler do |request, response|
    user_id = request.params[:id]

    # Simulate user lookup
    if user_id == "1"
      response.code = :ok
      response.body = {
        id: user_id,
        username: "john_doe",
        email: "john@example.com"
      }
    else
      response.code = :not_found
      response.body = {error: "User not found"}
    end
  end
end
