# frozen_string_literal: true

# A query string with real validation work in it: a type that needs coercion, an
# enum, a length bound. /users/123 declares one unconstrained string, so on its
# own it measures routing and response building more than validation — and
# validation is the expensive part of a validating framework.
Raxon.route do
  description "Typed and constrained query parameter benchmark endpoint"

  parameters do
    define :limit, type: :integer, in: :query, required: true
    define :status, type: :string, in: :query, required: true, enum: %w[active inactive]
    define :cursor, type: :string, in: :query, required: false, max_length: 64
  end

  response 200, type: :object do
    property :limit, type: :integer
    property :status, type: :string
  end

  handler do |request, response|
    response.ok limit: request.params[:limit], status: request.params[:status]
  end
end
