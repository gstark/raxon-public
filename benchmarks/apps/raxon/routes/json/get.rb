# frozen_string_literal: true

Raxon.route do
  description "JSON benchmark endpoint"

  response 200, type: :object do
    property :message, type: :string
  end

  handler do |_request, response|
    response.ok message: "Hello, World!"
  end
end
