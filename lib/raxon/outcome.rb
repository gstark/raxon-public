# frozen_string_literal: true

module Raxon
  # Explicit return value for a #handle block that needs a status other than the
  # endpoint's sole declared 2xx, or that needs to set headers.
  #
  # Every status symbol {Response::STATUS_CODES} knows has a constructor, so a
  # handler names the status rather than spelling out the tuple:
  #
  #   Raxon::Outcome.created(id: user.id)
  #   Raxon::Outcome.unprocessable_entity(error: "Name can't be blank")
  #   Raxon::Outcome.no_content
  #   Raxon::Outcome.ok({report: rows}, headers: {"cache-control" => "no-store"})
  #
  # The body may be passed positionally or as keywords, matching Response#ok and
  # its siblings. +headers:+ is reserved, so a body that needs its own "headers"
  # key must be passed positionally.
  Outcome = Data.define(:status, :body, :headers)

  Response::STATUS_CODES.each do |status, code|
    Outcome.define_singleton_method(status) do |body = nil, headers: {}, **rest|
      new(code, rest.empty? ? body : rest, headers)
    end
  end
end
