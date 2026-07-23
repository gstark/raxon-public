# frozen_string_literal: true

require "spec_helper"

RSpec.describe "route simplification APIs" do
  def endpoint(path, method, &block)
    Raxon::OpenApi::Endpoint.new.tap do |value|
      value.path(path)
      value.method = method
      value.operation((method == "all") ? :get : method.to_sym)
      value.route_file_path = "routes#{path}/#{method}.rb"
      block&.call(value)
    end
  end

  it "composes inferred parameters and all.rb declarations into the runtime contract" do
    parent = endpoint("/widgets/{id}", "all") do |value|
      value.infer_path_parameters([:id])
      value.path_param :id, type: :integer
      value.default_response(404, type: :object) { |response| response.property :error, type: :string }
      value.security []
      value.metadata organization_scoped: true
    end
    leaf = endpoint("/widgets/{id}", "get") { |value| value.handler { |_request, response| response.ok(id: 1) } }
    effective = Raxon::EffectiveEndpoint.new(leaf, [parent, leaf])

    parameter = effective.parameters.parameters.first
    expect([parameter.name, parameter.type, parameter.required]).to eq([:id, "integer", true])
    expect(effective.responses).to include(404)
    expect(effective.security).to eq([])
    expect(effective.static_metadata).to eq(organization_scoped: true)
  end

  it "maps an opt-in handle return value using its declared response status" do
    value = endpoint("/widgets", "get") do |item|
      item.response(201, type: :object) { |response| response.property :id, type: :integer }
      item.handle { |_request| {id: 1} }
    end
    request = instance_double(Raxon::Request, params: {}, json_parse_error: false, validation_errors: nil, endpoint_context: nil)
    response = Raxon::Response.new(value)

    described_class = Raxon::EndpointInvocation.new(value, [value])
    described_class.send(:run_handler, request, response, {})

    expect([response.status_code, response.body]).to eq([201, {id: 1}])
  end

  it "validates a response declared only through a component reference" do
    Raxon::OpenApi::DSL.component(:Widget, type: :object) { |component| component.property :id, type: :integer }
    response = Raxon::OpenApi::Response.new(type: :object, as: :Widget)

    validator = Raxon::OpenApi::ResponseSchemaGenerator.new(response).to_dry_schema
    expect(validator.call(id: "1")).to be_success
    expect(validator.call(name: "missing")).not_to be_success
  end

  it "checks declarative file content types without reading the file" do
    property = Raxon::OpenApi::Property.new(type: :file, content_types: ["image/png"])
    body = Raxon::OpenApi::RequestBody.new(type: :multipart)
    body.properties[:upload] = property
    tempfile = Tempfile.new("raxon-upload")
    tempfile.write("x")
    tempfile.rewind
    schema = Dry::Schema.Params { required(:upload).filled }
    result = Raxon::OpenApi::FileUploadValidator.new(schema, body).call(upload: {tempfile: tempfile, filename: "a.png", type: "IMAGE/JPEG; charset=binary"})

    expect(result).not_to be_success
    expect(result.errors.to_h[:upload]).to include(/content types/)
  ensure
    tempfile&.close!
  end
end
