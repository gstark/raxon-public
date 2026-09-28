# frozen_string_literal: true

require "json"
require "roda"

class BenchmarkRodaApp < Roda
  route do |r|
    r.get "plaintext" do
      response["content-type"] = "text/plain"
      "Hello, World!"
    end

    r.get "json" do
      response["content-type"] = "application/json"
      JSON.generate(message: "Hello, World!")
    end

    r.on "users", String do |id|
      r.get do
        response["content-type"] = "application/json"
        JSON.generate(id: id)
      end
    end
  end
end

run BenchmarkRodaApp.freeze.app
