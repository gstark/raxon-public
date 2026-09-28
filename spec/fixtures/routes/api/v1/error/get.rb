# frozen_string_literal: true

Raxon.route do |endpoint|
  endpoint.description "Test route that raises an error"

  endpoint.handler do |request, response, metadata|
    raise StandardError, "intentional error for testing"
  end
end
