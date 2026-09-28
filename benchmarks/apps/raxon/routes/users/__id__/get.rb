# frozen_string_literal: true

Raxon.route do
  description "Path parameter benchmark endpoint"

  parameters do
    define :id, type: :string, in: :path, description: "User ID"
  end

  response 200, type: :object do
    property :id, type: :string
  end

  handler do |request, response|
    response.ok id: request.params[:id]
  end
end
