# frozen_string_literal: true

require "json"
require "sinatra/base"

class BenchmarkSinatraApp < Sinatra::Base
  set :environment, :production
  set :logging, false
  set :protection, false
  set :show_exceptions, false
  set :raise_errors, true

  get "/plaintext" do
    content_type "text/plain"
    "Hello, World!"
  end

  get "/json" do
    content_type "application/json"
    JSON.generate(message: "Hello, World!")
  end

  get "/users/:id" do
    content_type "application/json"
    JSON.generate(id: params[:id])
  end
end

run BenchmarkSinatraApp
