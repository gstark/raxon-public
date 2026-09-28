# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"
require "date"

RSpec.describe Raxon::JSONEncoder do
  it "writes a BigDecimal as a number" do
    expect(described_class.generate(price: BigDecimal("1.5"), qty: BigDecimal(3))).to eq(%({"price":1.5,"qty":3.0}))
  end

  it "keeps every digit of a BigDecimal" do
    expect(described_class.generate([BigDecimal("12345678901234567890.123")])).to eq("[12345678901234567890.123]")
  end

  it "writes a BigDecimal with a large exponent in exponent form" do
    expect(described_class.generate([BigDecimal("1e100")])).to eq("[0.1e101]")
  end

  it "raises for a BigDecimal that is not finite, as JSON.generate does for a Float" do
    expect { described_class.generate([BigDecimal("NaN")]) }.to raise_error(JSON::GeneratorError)
    expect { described_class.generate([BigDecimal("Infinity")]) }.to raise_error(JSON::GeneratorError)
  end

  it "encodes other values as JSON.generate does" do
    custom = Object.new
    def custom.to_json(*) = %({"custom":1})
    data = {
      :time => Time.utc(2026, 1, 1), :date => Date.new(2026, 1, 1), :custom => custom,
      :symbol => :x, :nil => nil, :float => 1.5, 1 => "integer key", :nested => [{a: [true, false]}]
    }

    expect(described_class.generate(data)).to eq(JSON.generate(data))
  end

  # ActiveSupport's Time#to_json and BigDecimal#to_s both change output when
  # they are loaded. Other specs in the suite load them too.
  it "encodes as JSON.generate does, and writes a BigDecimal as a number, with ActiveSupport's JSON loaded" do
    require "active_support"
    require "active_support/core_ext/object/json"
    require "active_support/core_ext/big_decimal/conversions"
    data = {time: Time.utc(2026, 1, 1), big: BigDecimal("1e100")}

    expect(described_class.generate(data.except(:big))).to eq(JSON.generate(data.except(:big)))
    expect(described_class.generate(data)).to end_with(%("big":0.1e101}))
  end
end
