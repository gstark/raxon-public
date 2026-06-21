Raxon.route do
  description "Retrieves a specific user by ID"

  path_param :id, type: :string, description: "The user ID"

  response 200, type: :object do
    property :id, type: :string, description: "User ID"
    property :username, type: :string, description: "Username"
    property :email, type: :string, description: "Email address"
  end

  not_found_response

  handler do |request, response|
    user_id = request.path_params[:id]

    # Simulate user lookup
    if user_id == "1"
      response.ok(
        id: user_id,
        username: "john_doe",
        email: "john@example.com"
      )
    else
      response.not_found(error: "User not found")
    end
  end
end
