# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "File parts and tempfiles" do
  let(:upload) do
    file = Tempfile.new(["upload", ".txt"])
    file.write("hello")
    file.rewind
    Rack::Multipart::UploadedFile.new(file.path, "text/plain")
  end

  def multipart_env(path, params)
    Rack::MockRequest.env_for(path, method: "POST", params: params)
  end

  it "answers 400 before writing a file part for an endpoint with no file fields" do
    define_route("routes/notes/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :title, type: :string
      end
      endpoint.handler { |request, response, _metadata| response.ok(request.params) }
    end
    env = multipart_env("/notes", title: "a", attachment: upload)
    expect(Tempfile).not_to receive(:new)

    status, _headers, body = Raxon::Router.new.call(env)

    expect(status).to eq(400)
    expect(body.join).to eq(%({"error":"File uploads are not accepted"}))
  end

  it "accepts text-only multipart fields for an endpoint with no file fields" do
    define_route("routes/notes/post.rb") do |endpoint|
      endpoint.body type: :object do |body|
        body.property :title, type: :string
      end
      endpoint.handler { |request, response, _metadata| response.ok(request.params) }
    end
    env = Rack::MockRequest.env_for("/notes", :method => "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=AaB03x",
      :input => "--AaB03x\r\ncontent-disposition: form-data; name=\"title\"\r\n\r\na\r\n--AaB03x--\r\n")

    status, _headers, body = Raxon::Router.new.call(env)

    expect(status).to eq(200)
    expect(JSON.parse(body.join)).to eq("title" => "a")
  end

  it "accepts a file part for an endpoint that declares a file field" do
    define_route("routes/photos/post.rb") do |endpoint|
      endpoint.body type: :multipart do |body|
        body.property :photo, type: :file
      end
      endpoint.handler { |request, response, _metadata| response.ok(name: request.params[:photo].original_filename) }
    end

    status, = Raxon::Router.new.call(multipart_env("/photos", photo: upload))

    expect(status).to eq(200)
  end

  it "deletes multipart tempfiles when the response body closes" do
    define_route("routes/photos/post.rb") do |endpoint|
      endpoint.body type: :multipart do |body|
        body.property :photo, type: :file
      end
      endpoint.handler { |_request, response, _metadata| response.ok({}) }
    end
    env = multipart_env("/photos", photo: upload)

    _status, _headers, body = Raxon::Server.new.call(env)
    tempfiles = env[Rack::RACK_TEMPFILES]
    body.close

    expect(tempfiles).not_to be_empty
    expect(tempfiles.map(&:path)).to all(be_nil)
  end
end
