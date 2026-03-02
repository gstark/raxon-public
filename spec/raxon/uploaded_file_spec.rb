# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Raxon::UploadedFile do
  describe "#initialize" do
    it "extracts attributes from a symbol-keyed hash" do
      tempfile = Tempfile.new("upload")
      hash = {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg", head: "Content-Disposition: form-data"}

      uploaded = Raxon::UploadedFile.new(hash)

      expect(uploaded.tempfile).to eq(tempfile)
      expect(uploaded.original_filename).to eq("photo.jpg")
      expect(uploaded.content_type).to eq("image/jpeg")
      expect(uploaded.headers).to eq("Content-Disposition: form-data")

      tempfile.close!
    end

    it "extracts attributes from a string-keyed hash" do
      tempfile = Tempfile.new("upload")
      hash = {"tempfile" => tempfile, "filename" => "doc.pdf", "type" => "application/pdf", "head" => "Content-Disposition: form-data"}

      uploaded = Raxon::UploadedFile.new(hash)

      expect(uploaded.tempfile).to eq(tempfile)
      expect(uploaded.original_filename).to eq("doc.pdf")
      expect(uploaded.content_type).to eq("application/pdf")

      tempfile.close!
    end
  end

  describe "IO delegation" do
    it "delegates read, rewind, size, eof?, close, and path to tempfile" do
      tempfile = Tempfile.new("upload")
      tempfile.write("hello world")
      tempfile.rewind
      hash = {tempfile: tempfile, filename: "test.txt", type: "text/plain"}

      uploaded = Raxon::UploadedFile.new(hash)

      expect(uploaded.read).to eq("hello world")
      uploaded.rewind
      expect(uploaded.eof?).to be false
      expect(uploaded.size).to eq(11)
      expect(uploaded.path).to eq(tempfile.path)

      tempfile.close!
    end
  end

  describe "#to_io" do
    it "returns the tempfile" do
      tempfile = Tempfile.new("upload")
      hash = {tempfile: tempfile, filename: "test.txt", type: "text/plain"}

      uploaded = Raxon::UploadedFile.new(hash)

      expect(uploaded.to_io).to eq(tempfile)

      tempfile.close!
    end
  end
end
