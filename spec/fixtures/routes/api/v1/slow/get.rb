# frozen_string_literal: true

Raxon::RouteLoader.register(__FILE__) do |endpoint|
  endpoint.description "Slow endpoint for testing duration"

  endpoint.response 200, type: :object do |response|
    response.property :slow, type: :boolean
  end

  endpoint.handler do |request, response|
    sleep(0.01) # 10ms delay
    response.code = :ok
    response.body = {slow: true}
  end
end
