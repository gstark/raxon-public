# frozen_string_literal: true

require "spec_helper"

RSpec.describe Raxon::SafeString do
  describe "#+" do
    it "keeps the safe marker when it joins a safe value" do
      joined = described_class.new("<b>") + described_class.new("</b>")

      expect(joined).to be_html_safe
      expect(joined).to eq("<b></b>")
    end

    it "escapes a value that is not safe" do
      joined = described_class.new("<b>") + "<i>"

      expect(joined).to be_html_safe
      expect(joined).to eq("<b>&lt;i&gt;")
    end
  end
end
