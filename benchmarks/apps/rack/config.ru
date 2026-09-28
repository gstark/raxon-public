# frozen_string_literal: true

require "json"

APP = lambda do |env|
  case env["PATH_INFO"]
  when "/plaintext"
    [200, {"content-type" => "text/plain"}, ["Hello, World!"]]
  when "/json"
    [200, {"content-type" => "application/json"}, [JSON.generate(message: "Hello, World!")]]
  when %r{\A/users/([^/]+)\z}
    id = Regexp.last_match(1)
    [200, {"content-type" => "application/json"}, [JSON.generate(id: id)]]
  else
    [404, {"content-type" => "text/plain"}, ["Not Found"]]
  end
end

run APP
