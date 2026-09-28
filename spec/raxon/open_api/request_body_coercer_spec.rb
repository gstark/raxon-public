# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Raxon::OpenApi::RequestBodyCoercer do
  describe "#call" do
    it "recursively wraps nested Rack file hashes in UploadedFile" do
      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :profile, type: :object do |profile|
        profile.property :photo, type: :file, required: true
      end

      tempfile = Tempfile.new("upload")
      file_hash = {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"}
      params = {profile: {photo: file_hash, name: "Jane"}, other: "unchanged"}

      result = described_class.new(request_body).call(params)

      expect(result).to equal(params)
      expect(result[:profile][:photo]).to be_a(Raxon::UploadedFile)
      expect(result[:profile][:photo].original_filename).to eq("photo.jpg")
      expect(result[:profile][:photo].content_type).to eq("image/jpeg")
      expect(result[:profile][:photo].tempfile).to eq(tempfile)
      expect(result[:profile][:name]).to eq("Jane")
      expect(result[:other]).to eq("unchanged")

      tempfile.close!
    end

    it "wraps file fields inside array object items" do
      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :attachments, type: :array, of: :object do |attachment|
        attachment.property :file, type: :file, required: true
        attachment.property :caption, type: :string, required: false
      end

      tempfile = Tempfile.new("upload")
      file_hash = {tempfile: tempfile, filename: "document.pdf", type: "application/pdf"}
      params = {attachments: [{file: file_hash, caption: "Document"}]}

      result = described_class.new(request_body).call(params)

      expect(result[:attachments][0][:file]).to be_a(Raxon::UploadedFile)
      expect(result[:attachments][0][:file].original_filename).to eq("document.pdf")
      expect(result[:attachments][0][:caption]).to eq("Document")

      tempfile.close!
    end

    it "preserves already wrapped file values inside array object items" do
      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :attachments, type: :array, of: :object do |attachment|
        attachment.property :file, type: :file, required: true
      end

      tempfile = Tempfile.new("upload")
      uploaded_file = Raxon::UploadedFile.new({tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"})
      params = {attachments: [{file: uploaded_file}]}

      result = described_class.new(request_body).call(params)

      expect(result[:attachments][0][:file]).to equal(uploaded_file)

      tempfile.close!
    end

    it "preserves already wrapped file values" do
      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :photo, type: :file, required: true

      tempfile = Tempfile.new("upload")
      uploaded_file = Raxon::UploadedFile.new({tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"})
      params = {photo: uploaded_file}

      result = described_class.new(request_body).call(params)

      expect(result[:photo]).to equal(uploaded_file)

      tempfile.close!
    end

    it "leaves unrelated hashes unchanged" do
      request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
      request_body.property :metadata, type: :object do |metadata|
        metadata.property :title, type: :string
      end

      params = {metadata: {title: "Profile", details: {tempfile: "not declared as a file"}}}

      result = described_class.new(request_body).call(params)

      expect(result).to eq(params)
      expect(result[:metadata][:details]).to eq(tempfile: "not declared as a file")
    end
  end
end

RSpec.describe Raxon::OpenApi::RequestBodyCoercer, "pass-through behavior" do
  it "returns params untouched when there is no request body definition" do
    params = {name: "Jane"}

    expect(described_class.new(nil).call(params)).to equal(params)
  end

  it "returns params untouched when the request body declares no properties" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    params = {name: "Jane"}

    expect(described_class.new(request_body).call(params)).to equal(params)
  end

  it "returns non-hash params untouched" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    request_body.property :photo, type: :file, required: true

    expect(described_class.new(request_body).call(nil)).to be_nil
    expect(described_class.new(request_body).call("raw")).to eq("raw")
  end

  it "leaves non-hash values for object properties untouched" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    request_body.property :profile, type: :object do |profile|
      profile.property :photo, type: :file, required: true
    end
    params = {profile: "not-a-hash"}

    expect(described_class.new(request_body).call(params)[:profile]).to eq("not-a-hash")
  end

  it "leaves non-array values for array properties untouched" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    request_body.property :attachments, type: :array, of: :object do |attachment|
      attachment.property :file, type: :file, required: true
    end
    params = {attachments: "not-an-array"}

    expect(described_class.new(request_body).call(params)[:attachments]).to eq("not-an-array")
  end

  it "skips non-hash items inside arrays of objects" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    request_body.property :attachments, type: :array, of: :object do |attachment|
      attachment.property :file, type: :file, required: true
    end
    params = {attachments: ["oops", 42]}

    expect(described_class.new(request_body).call(params)[:attachments]).to eq(["oops", 42])
  end
end

RSpec.describe Raxon::OpenApi::RequestBodyCoercer, "object properties without nested declarations" do
  it "passes hash values through untouched" do
    request_body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    request_body.property :metadata, type: :object
    request_body.property :photo, type: :file, required: true

    params = {metadata: {"free" => "form"}}

    expect(described_class.new(request_body).call(params)[:metadata]).to eq({"free" => "form"})
  end
end
