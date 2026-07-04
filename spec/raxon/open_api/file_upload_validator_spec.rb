# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Raxon::OpenApi::FileUploadValidator do
  # Build the validator through RequestSchemaGenerator so the spec exercises
  # the same wiring production uses: Dry::Schema handles structure, the
  # validator layers file-shape checks on top.
  def validator_for(request_body)
    Raxon::OpenApi::RequestSchemaGenerator
      .new(Raxon::OpenApi::Parameters.new, request_body)
      .to_dry_schema
  end

  def request_body(&block)
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    block.call(body)
    body
  end

  let(:tempfile) { Tempfile.new("upload") }
  let(:file_hash) { {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"} }

  after { tempfile.close! }

  it "accepts a valid Rack upload hash for a file property" do
    body = request_body { |b| b.property :photo, type: :file, required: true }

    result = validator_for(body).call({photo: file_hash})

    expect(result.success?).to be(true)
    expect(result.to_h[:photo]).to eq(file_hash)
  end

  it "rejects a plain value submitted for a file property" do
    body = request_body { |b| b.property :photo, type: :file, required: true }

    result = validator_for(body).call({photo: "not-a-file"})

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:photo]).to eq(["must be a file upload"])
  end

  it "matches string-keyed params against declared file properties" do
    body = request_body { |b| b.property :photo, type: :file, required: true }

    result = validator_for(body).call({"photo" => "not-a-file"})

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:photo]).to include("must be a file upload")
  end

  it "allows nil for a nullable file property" do
    body = request_body { |b| b.property :photo, type: :file, required: true, nullable: true }

    result = validator_for(body).call({photo: nil})

    expect(result.errors.to_h[:photo]).to be_nil
  end

  it "validates file properties nested inside objects" do
    body = request_body do |b|
      b.property :profile, type: :object, required: true do |profile|
        profile.property :avatar, type: :file, required: true
      end
    end

    result = validator_for(body).call({profile: {avatar: "nope"}})

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:profile][:avatar]).to eq(["must be a file upload"])
  end

  it "validates files inside arrays of objects and keys errors by index" do
    body = request_body do |b|
      b.property :attachments, type: :array, of: :object, required: true do |attachment|
        attachment.property :file, type: :file, required: true
      end
    end

    result = validator_for(body).call(
      {attachments: [{file: file_hash}, {file: "broken"}]}
    )

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:attachments][1][:file]).to eq(["must be a file upload"])
    expect(result.errors.to_h[:attachments][0]).to be_nil
  end

  it "merges file errors with schema errors on sibling fields" do
    body = request_body do |b|
      b.property :title, type: :string, required: true
      b.property :photo, type: :file, required: true
    end

    result = validator_for(body).call({photo: "not-a-file"})

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:title]).to eq(["is missing"])
    expect(result.errors.to_h[:photo]).to eq(["must be a file upload"])
  end

  it "combines schema and file errors reported on the same field" do
    body = request_body do |b|
      b.property :profile, type: :object, required: true do |profile|
        profile.property :name, type: :string, required: true
        profile.property :avatar, type: :file, required: true
      end
    end

    result = validator_for(body).call({profile: {avatar: "nope"}})

    errors = result.errors.to_h[:profile]
    expect(errors[:name]).to eq(["is missing"])
    expect(errors[:avatar]).to eq(["must be a file upload"])
  end

  it "exposes the coerced schema params through to_h on failure" do
    body = request_body do |b|
      b.property :title, type: :string, required: true
      b.property :photo, type: :file, required: true
    end

    result = validator_for(body).call({title: "Hello", photo: "nope"})

    expect(result.to_h[:title]).to eq("Hello")
  end

  it "reports only schema errors for non-hash params" do
    body = request_body { |b| b.property :photo, type: :file, required: true }

    result = validator_for(body).call(nil)

    expect(result.success?).to be(false)
  end
end

RSpec.describe Raxon::OpenApi::FileUploadValidator, "error merging and guards" do
  def validator_for(request_body)
    Raxon::OpenApi::RequestSchemaGenerator
      .new(Raxon::OpenApi::Parameters.new, request_body)
      .to_dry_schema
  end

  def request_body(&block)
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    block.call(body)
    body
  end

  it "combines schema and file messages for the same field" do
    body = request_body { |b| b.property :photo, type: :file, required: true }

    result = validator_for(body).call({photo: nil})

    expect(result.errors.to_h[:photo]).to eq(["must be filled", "must be a file upload"])
  end

  it "leaves object-typed fields alone when the value is not a hash" do
    body = request_body do |b|
      b.property :profile, type: :object, required: true do |profile|
        profile.property :avatar, type: :file, required: true
      end
    end

    result = validator_for(body).call({profile: "flat"})

    expect(result.errors.to_h[:profile]).not_to include("must be a file upload")
  end

  it "leaves array-typed fields alone when the value is not an array" do
    body = request_body do |b|
      b.property :attachments, type: :array, of: :object, required: true do |attachment|
        attachment.property :file, type: :file, required: true
      end
    end

    result = validator_for(body).call({attachments: "flat"})

    expect(result.success?).to be(false)
    expect(result.errors.to_h[:attachments]).to be_a(Array)
  end

  it "skips non-hash items when validating arrays of objects" do
    body = request_body do |b|
      b.property :attachments, type: :array, of: :object, required: true do |attachment|
        attachment.property :file, type: :file, required: true
      end
    end

    result = validator_for(body).call({attachments: ["not-a-hash"]})

    file_messages = result.errors.to_h[:attachments]
    expect(file_messages.to_s).not_to include("must be a file upload")
  end
end

RSpec.describe Raxon::OpenApi::FileUploadValidator, "direct construction" do
  def dry_schema_stub(success:, errors: {})
    result = double("schema_result", success?: success, to_h: {}, errors: double("errors", to_h: errors))
    double("schema", call: result)
  end

  it "returns the schema result untouched when no request body is given" do
    schema = dry_schema_stub(success: true)

    result = described_class.new(schema, nil).call({photo: "anything"})

    expect(result.success?).to be(true)
  end

  it "returns the schema result untouched when the request body declares no properties" do
    schema = dry_schema_stub(success: true)
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)

    result = described_class.new(schema, body).call({photo: "anything"})

    expect(result.success?).to be(true)
  end

  it "lets file errors win when schema errors have a different shape for the same field" do
    schema = dry_schema_stub(success: false, errors: {photo: {malformed: ["boom"]}})
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    body.property :photo, type: :file, required: true

    result = described_class.new(schema, body).call({photo: "not-a-file"})

    expect(result.errors.to_h[:photo]).to eq(["must be a file upload"])
  end
end

RSpec.describe Raxon::OpenApi::FileUploadValidator, "non-file property shapes" do
  def validator_for(request_body)
    Raxon::OpenApi::RequestSchemaGenerator
      .new(Raxon::OpenApi::Parameters.new, request_body)
      .to_dry_schema
  end

  it "ignores object properties that declare no nested properties" do
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    body.property :metadata, type: :object, required: false
    body.property :photo, type: :file, required: false

    result = validator_for(body).call({metadata: {"free" => "form"}})

    expect(result.success?).to be(true)
  end

  it "ignores arrays of scalars" do
    body = Raxon::OpenApi::RequestBody.new(type: :object, required: true)
    body.property :tags, type: :array, of: :string, required: false
    body.property :photo, type: :file, required: false

    result = validator_for(body).call({tags: ["a", "b"]})

    expect(result.success?).to be(true)
  end
end
