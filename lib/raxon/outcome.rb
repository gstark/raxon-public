# frozen_string_literal: true

module Raxon
  # Explicit return value for a #handle block with a non-default successful
  # status or headers.
  Outcome = Data.define(:status, :body, :headers) do
    def self.ok(body = nil, headers: {}) = new(200, body, headers)
    def self.created(body = nil, headers: {}) = new(201, body, headers)
    def self.accepted(body = nil, headers: {}) = new(202, body, headers)
  end
end
