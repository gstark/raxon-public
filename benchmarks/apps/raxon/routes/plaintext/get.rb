# frozen_string_literal: true

Raxon.route do
  description "Plain text benchmark endpoint"

  response 200, type: :string, description: "Plain text response"

  handler do |_request, response|
    response.header "content-type", "text/plain"
    response.body = "Hello, World!"
  end
end
