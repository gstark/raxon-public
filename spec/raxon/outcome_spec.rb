# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::Outcome do
  it "builds a success outcome from a positional body" do
    outcome = described_class.created({id: 7})

    expect(outcome.status).to eq(201)
    expect(outcome.body).to eq({id: 7})
    expect(outcome.headers).to eq({})
  end

  it "accepts the body as keywords, like Response#ok" do
    expect(described_class.ok(id: 7, name: "Ada").body).to eq({id: 7, name: "Ada"})
  end

  it "has a constructor for every status Response knows" do
    missing = Raxon::Response::STATUS_CODES.keys.reject { |status| described_class.respond_to?(status) }

    expect(missing).to be_empty
  end

  it "names error statuses too" do
    outcome = described_class.unprocessable_entity(error: "Name can't be blank")

    expect(outcome.status).to eq(422)
    expect(outcome.body).to eq({error: "Name can't be blank"})
  end

  it "defaults the body to nil for a status that carries none" do
    expect(described_class.no_content.body).to be_nil
  end

  it "carries headers alongside a positional body" do
    outcome = described_class.ok({rows: []}, headers: {"cache-control" => "no-store"})

    expect(outcome.body).to eq({rows: []})
    expect(outcome.headers).to eq({"cache-control" => "no-store"})
  end

  it "treats headers: as its own argument, not part of a keyword body" do
    outcome = described_class.ok(id: 7, headers: {"x-trace" => "abc"})

    expect(outcome.body).to eq({id: 7})
    expect(outcome.headers).to eq({"x-trace" => "abc"})
  end

  it "still builds directly with a status code" do
    expect(described_class.new(418, {tipped: true}, {}).status).to eq(418)
  end

  # A handler with a computed status has no constructor to name.
  describe "building directly with a computed status" do
    it "defaults headers, so a trailing empty hash is not required" do
      outcome = described_class.new(:unprocessable_entity, {error: "nope"})

      expect(outcome.status).to eq(:unprocessable_entity)
      expect(outcome.body).to eq({error: "nope"})
      expect(outcome.headers).to eq({})
    end

    it "defaults the body as well" do
      expect(described_class.new(:no_content).body).to be_nil
    end

    it "still accepts keywords" do
      outcome = described_class.new(status: 418, body: {tipped: true})

      expect(outcome.status).to eq(418)
      expect(outcome.body).to eq({tipped: true})
    end
  end
end
