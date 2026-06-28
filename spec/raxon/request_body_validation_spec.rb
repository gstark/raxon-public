require "spec_helper"
require "rack/request"
require "rack/mock"
require "tempfile"

RSpec.describe Raxon::Request, "request_body validation" do
  describe "#params with request_body" do
    it "validates request_body properties" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
        body.property :age, type: :number, required: true
      end

      json_body = JSON.generate({
        name: "John",
        age: 30
      })

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:name]).to eq("John")
      expect(result[:age]).to eq(30)
      expect(request.validation_errors).to be_nil
    end

    it "validates and coerces types in request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :count, type: :number, required: true
      end

      json_body = JSON.generate({count: "42"})

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:count]).to eq(42)
      expect(request.validation_errors).to be_nil
    end

    it "sets validation errors when request_body properties are missing" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
        body.property :email, type: :string, required: true
      end

      json_body = JSON.generate({name: "John"})

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      request.params
      expect(request.validation_errors).to have_key(:email)
    end

    it "validates nested objects in request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.request_body type: :object, required: true do |body|
        body.property :user, type: :object, required: true do |user|
          user.property :name, type: :string, required: true
          user.property :age, type: :number, required: true
        end
      end

      json_body = JSON.generate({
        user: {
          name: "Jane",
          age: 25
        }
      })

      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:user][:name]).to eq("Jane")
      expect(result[:user][:age]).to eq(25)
      expect(request.validation_errors).to be_nil
    end

    it "merges path parameters with request_body" do
      endpoint = Raxon::OpenApi::Endpoint.new

      endpoint.parameters do |params|
        params.define :id, type: :number, in: :path, required: true
      end

      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
      end

      json_body = JSON.generate({name: "Updated Name"})

      env = Rack::MockRequest.env_for(
        "/test/42",
        :method => "PUT",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      env["router.params"] = {id: "42"}

      rack_request = Rack::Request.new(env)
      request = Raxon::Request.new(rack_request, endpoint)

      result = request.params
      expect(result[:id]).to eq(42)
      expect(result[:name]).to eq("Updated Name")
      expect(request.validation_errors).to be_nil
    end
  end

  context "with date/time convenience types" do
    it "validates date/time, uuid, email convenience types as strings" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :starts_at, type: :datetime
        body.property :birthday, type: :date
        body.property :user_id, type: :uuid
        body.property :email, type: :email
      end

      json_body = JSON.generate({starts_at: "2026-06-07T12:00:00Z", birthday: "2026-06-07", user_id: "123e4567-e89b-12d3-a456-426614174000", email: "user@example.com"})
      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_env), endpoint)

      request.params
      expect(request.validation_errors).to be_nil
    end

    it "rejects non-string values for date/time convenience types" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :starts_at, type: :datetime
      end

      json_body = JSON.generate({starts_at: 123})
      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_env), endpoint)

      request.params
      expect(request.validation_errors).to include(:starts_at)
    end
  end

  context "with schema constraints" do
    it "validates request body property constraints" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, min_length: 3, max_length: 5, pattern: "^[a-z]+$"
        body.property :age, type: :integer, minimum: 18, maximum: 65
        body.property :tags, type: :array, of: :string, min_items: 1, max_items: 2
      end

      json_body = JSON.generate({name: "AB", age: 17, tags: []})
      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => json_body,
        "CONTENT_TYPE" => "application/json"
      )
      request = Raxon::Request.new(Rack::Request.new(rack_env), endpoint)

      request.params
      expect(request.validation_errors).to include(:name, :age, :tags)
    end

    it "coerces integer request body properties and validates maximum" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :age, type: :integer, minimum: 0, maximum: 130
      end

      valid_body = JSON.generate({age: "42"})
      valid_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => valid_body,
        "CONTENT_TYPE" => "application/json"
      )
      valid_request = Raxon::Request.new(Rack::Request.new(valid_env), endpoint)

      expect(valid_request.params[:age]).to eq(42)
      expect(valid_request.validation_errors).to be_nil

      invalid_body = JSON.generate({age: 140})
      invalid_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => invalid_body,
        "CONTENT_TYPE" => "application/json"
      )
      invalid_request = Raxon::Request.new(Rack::Request.new(invalid_env), endpoint)

      invalid_request.params
      expect(invalid_request.validation_errors).to include(:age)
    end

    it "validates number request body property minimum and maximum" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :ratio, type: :number, minimum: 0.5, maximum: 1.5
      end

      valid_body = JSON.generate({ratio: 1.25})
      valid_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => valid_body,
        "CONTENT_TYPE" => "application/json"
      )
      valid_request = Raxon::Request.new(Rack::Request.new(valid_env), endpoint)

      expect(valid_request.params[:ratio]).to eq(1.25)
      expect(valid_request.validation_errors).to be_nil

      invalid_body = JSON.generate({ratio: 2.0})
      invalid_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => invalid_body,
        "CONTENT_TYPE" => "application/json"
      )
      invalid_request = Raxon::Request.new(Rack::Request.new(invalid_env), endpoint)

      invalid_request.params
      expect(invalid_request.validation_errors).to include(:ratio)
    end
  end

  context "with enum constraints" do
    def post_body(endpoint, payload)
      env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        :input => JSON.generate(payload),
        "CONTENT_TYPE" => "application/json"
      )
      Raxon::Request.new(Rack::Request.new(env), endpoint)
    end

    it "accepts a scalar enum value that is in the enum" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :status, type: :string, enum: %w[draft published]
      end

      request = post_body(endpoint, {status: "published"})

      expect(request.params[:status]).to eq("published")
      expect(request.validation_errors).to be_nil
    end

    it "rejects a scalar enum value that is outside the enum" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :status, type: :string, enum: %w[draft published]
      end

      request = post_body(endpoint, {status: "archived"})

      request.params
      expect(request.validation_errors).to include(:status)
    end

    it "enforces a deferred (callable) enum, resolved on read" do
      allowed = %w[a b]
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :kind, type: :string, enum: -> { allowed }
      end

      expect(post_body(endpoint, {kind: "a"}).validation_errors).to be_nil

      rejected = post_body(endpoint, {kind: "c"})
      rejected.params
      expect(rejected.validation_errors).to include(:kind)
    end

    it "enforces allowable_values as an enum alias" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :color, type: :string, allowable_values: %w[red green]
      end

      request = post_body(endpoint, {color: "blue"})

      request.params
      expect(request.validation_errors).to include(:color)
    end

    it "enforces an integer enum after coercion" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :level, type: :integer, enum: [1, 2, 3]
      end

      valid = post_body(endpoint, {level: "2"})
      expect(valid.params[:level]).to eq(2)
      expect(valid.validation_errors).to be_nil

      invalid = post_body(endpoint, {level: 9})
      invalid.params
      expect(invalid.validation_errors).to include(:level)
    end

    it "constrains each element of an array to the enum" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :tags, type: :array, of: :string, enum: %w[x y z]
      end

      expect(post_body(endpoint, {tags: %w[x z]}).validation_errors).to be_nil

      invalid = post_body(endpoint, {tags: %w[x bogus]})
      invalid.params
      expect(invalid.validation_errors).to have_key(:tags)
    end

    it "ignores the enum for an absent optional field" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :name, type: :string, required: true
        body.property :status, type: :string, required: false, enum: %w[draft published]
      end

      request = post_body(endpoint, {name: "John"})

      expect(request.params[:name]).to eq("John")
      expect(request.validation_errors).to be_nil
    end
  end

  context "with file type properties" do
    it "wraps Hash file params in Raxon::UploadedFile" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :photo, type: :file, required: true
      end

      tempfile = Tempfile.new("upload")
      file_hash = {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"}

      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data"
      )
      rack_request = Rack::Request.new(rack_env)
      allow(rack_request).to receive(:params).and_return({"photo" => file_hash})
      request = Raxon::Request.new(rack_request, endpoint)

      params = request.params
      expect(params[:photo]).to be_a(Raxon::UploadedFile)
      expect(params[:photo].original_filename).to eq("photo.jpg")
      expect(params[:photo].content_type).to eq("image/jpeg")
      expect(params[:photo].tempfile).to eq(tempfile)

      tempfile.close!
    end

    it "wraps file params inside array object items" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :multipart, required: true do |body|
        body.property :attachments, type: :array, of: :object do |attachment|
          attachment.property :file, type: :file, required: true
          attachment.property :caption, type: :string, required: false
        end
      end

      tempfile = Tempfile.new("upload")
      file_hash = {tempfile: tempfile, filename: "document.pdf", type: "application/pdf"}

      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data"
      )
      rack_request = Rack::Request.new(rack_env)
      allow(rack_request).to receive(:params).and_return({"attachments" => [{"file" => file_hash, "caption" => "Document"}]})
      request = Raxon::Request.new(rack_request, endpoint)

      params = request.params
      expect(params[:attachments][0][:file]).to be_a(Raxon::UploadedFile)
      expect(params[:attachments][0][:file].original_filename).to eq("document.pdf")
      expect(params[:attachments][0][:caption]).to eq("Document")
      expect(request.validation_errors).to be_nil

      tempfile.close!
    end

    it "reports validation errors for invalid file params" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :multipart, required: true do |body|
        body.property :photo, type: :file, required: true
      end

      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data"
      )
      rack_request = Rack::Request.new(rack_env)
      allow(rack_request).to receive(:params).and_return({"photo" => "not a file"})
      request = Raxon::Request.new(rack_request, endpoint)

      params = request.params
      expect(params[:photo]).to eq("not a file")
      expect(request.validation_errors).to have_key(:photo)
    end

    it "does not wrap non-Hash file params" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :photo, type: :file, required: true
      end

      tempfile = Tempfile.new("upload")
      already_wrapped = Raxon::UploadedFile.new({tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"})

      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data"
      )
      rack_request = Rack::Request.new(rack_env)
      allow(rack_request).to receive(:params).and_return({"photo" => already_wrapped})
      request = Raxon::Request.new(rack_request, endpoint)

      params = request.params
      expect(params[:photo]).to be_a(Raxon::UploadedFile)
      expect(params[:photo]).to eq(already_wrapped)

      tempfile.close!
    end

    it "wraps nested Hash file params in Raxon::UploadedFile" do
      endpoint = Raxon::OpenApi::Endpoint.new
      endpoint.request_body type: :object, required: true do |body|
        body.property :profile, type: :object, required: true do |profile|
          profile.property :photo, type: :file, required: true
        end
      end

      tempfile = Tempfile.new("upload")
      file_hash = {tempfile: tempfile, filename: "photo.jpg", type: "image/jpeg"}

      rack_env = Rack::MockRequest.env_for(
        "/test",
        :method => "POST",
        "CONTENT_TYPE" => "multipart/form-data"
      )
      rack_request = Rack::Request.new(rack_env)
      allow(rack_request).to receive(:params).and_return({"profile" => {"photo" => file_hash}})
      request = Raxon::Request.new(rack_request, endpoint)

      params = request.params
      expect(params[:profile][:photo]).to be_a(Raxon::UploadedFile)
      expect(params[:profile][:photo].original_filename).to eq("photo.jpg")
      expect(params[:profile][:photo].content_type).to eq("image/jpeg")
      expect(params[:profile][:photo].tempfile).to eq(tempfile)

      tempfile.close!
    end
  end
end
