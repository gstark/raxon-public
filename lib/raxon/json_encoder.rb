# frozen_string_literal: true

require "bigdecimal"

module Raxon
  # Encodes response and SSE data as JSON, writing a BigDecimal as a number.
  #
  # JSON.generate writes a BigDecimal as a string ("0.15e1"), so a decimal
  # column declared `type: :number` reached the client as a string. Patching
  # BigDecimal#to_json would change encoding for the whole host application,
  # so Raxon encodes its own bodies with a JSON::Coder instead.
  #
  # A Coder does not call #to_json. Every other object that is not a JSON type
  # goes through JSON.generate by itself, so a Time, a Struct, or an object
  # with its own #to_json encodes exactly as it did before. (Calling #to_json
  # directly would not: ActiveSupport's Time#to_json writes ISO 8601 when it
  # gets no JSON::State, and JSON.generate passes one.) A key that is not a
  # String or Symbol is written with #to_s, as JSON.generate does.
  #
  # An Alba resource is written as its #as_json. Alba's #to_json takes an
  # options hash and raises when JSON.generate passes it a JSON::State.
  module JSONEncoder
    # A BigDecimal whose exponent is larger than this is written in exponent
    # form ("0.1e41") rather than with every digit.
    PLAIN_EXPONENT_LIMIT = 40

    CODER = JSON::Coder.new do |value, is_key|
      if is_key
        value.to_s
      elsif value.is_a?(BigDecimal)
        raise JSON::GeneratorError, "#{value} not allowed in JSON" unless value.finite?

        # The format is explicit: ActiveSupport makes "F" the default.
        JSON::Fragment.new(value.to_s((value.exponent.abs > PLAIN_EXPONENT_LIMIT) ? "E" : "F"))
      elsif value.is_a?(Alba::Resource)
        JSON::Fragment.new(CODER.dump(value.as_json))
      else
        JSON::Fragment.new(JSON.generate(value))
      end
    end

    module_function

    # @param data [Object] JSON-ready data
    # @return [String]
    # @raise [JSON::GeneratorError] for a NaN or infinite Float or BigDecimal
    def generate(data)
      CODER.dump(data)
    end
  end
end
