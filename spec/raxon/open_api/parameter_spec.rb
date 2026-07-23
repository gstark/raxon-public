require "spec_helper"

RSpec.describe Raxon::OpenApi::Parameter do
  describe "#initialize" do
    it "sets the name" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.name).to eq(:id)
    end

    it "sets the in location" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.in).to eq(:path)
    end

    it "sets the type" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.type).to eq("number")
    end

    it "raises ArgumentError on an unknown option" do
      expect { described_class.new(:id, in: :path, type: :number, bogus: true) }
        .to raise_error(ArgumentError, /unknown option for .*Parameter: :bogus/)
    end

    it "sets the description" do
      parameter = described_class.new(:id, in: :path, type: :number, description: "ID of the post")
      expect(parameter.description).to eq("ID of the post")
    end

    it "defaults path parameters to required" do
      parameter = described_class.new(:id, in: :path, type: :number)
      expect(parameter.required).to be true
    end

    it "defaults query parameters to optional" do
      parameter = described_class.new(:page, in: :query, type: :integer)
      expect(parameter.required).to be false
    end

    it "defaults header parameters to optional" do
      parameter = described_class.new(:authorization, in: :header, type: :string)
      expect(parameter.required).to be false
    end

    it "defaults cookie parameters to optional" do
      parameter = described_class.new(:session_id, in: :cookie, type: :string)
      expect(parameter.required).to be false
    end

    it "defaults parameters without a location to optional query parameters" do
      parameter = described_class.new(:filter, type: :string)
      expect(parameter.in).to eq(:query)
      expect(parameter.required).to be false
    end

    it "sets required to false when specified" do
      parameter = described_class.new(:id, in: :path, type: :string, required: false)
      expect(parameter.required).to be false
    end

    it "sets required to true when specified" do
      parameter = described_class.new(:filter, in: :query, type: :string, required: true)
      expect(parameter.required).to be true
    end

    it "sets the enum values" do
      parameter = described_class.new(:format, in: :path, type: :string, enum: ["pdf", "png"])
      expect(parameter.enum).to eq(["pdf", "png"])
    end

    it "sets the allowable values" do
      parameter = described_class.new(:state, in: :query, type: :string, allowable_values: ["active", "inactive"])
      expect(parameter.allowable_values).to eq(["active", "inactive"])
    end

    it "resolves a callable enum lazily on each read" do
      calls = 0
      parameter = described_class.new(:format, in: :path, type: :string, enum: -> {
        calls += 1
        ["docx", "pdf"]
      })

      expect(calls).to eq(0)
      expect(parameter.enum).to eq(["docx", "pdf"])
      expect(parameter.enum).to eq(["docx", "pdf"])
      expect(calls).to eq(2)
    end

    it "returns nil when no enum is set" do
      parameter = described_class.new(:id, in: :path, type: :integer)
      expect(parameter.enum).to be_nil
      expect(parameter.allowable_values).to be_nil
    end
  end

  describe "in: validation" do
    it "raises on an invalid location rather than emitting an invalid parameter" do
      expect { described_class.new(:id, type: :string, in: :qeury) }
        .to raise_error(ArgumentError, /invalid `in:` location.*qeury.*Valid locations: query, header, path, cookie/m)
    end

    it "accepts each valid OpenAPI location" do
      %i[query header path cookie].each do |location|
        expect { described_class.new(:id, type: :string, in: location) }.not_to raise_error
      end
    end
  end

  describe "body-only type rejection" do
    # A :file parameter used to half-work: an in: :query parameter is validated
    # against the lenient source merge (which includes form params), so a real
    # upload reached it, but neither FileUploadValidator nor RequestBodyCoercer
    # consults parameters — the handler got a raw Rack hash and a non-file value
    # passed validation. OpenAPI cannot describe binary in a parameter either.
    it "rejects type: :file, pointing at the request-body form" do
      expect { described_class.new(:photo, type: :file) }
        .to raise_error(Raxon::OpenApi::Error, /type: :file is not valid for a parameter \(photo\)/)
    end

    it "rejects type: :multipart" do
      expect { described_class.new(:upload, type: :multipart) }
        .to raise_error(Raxon::OpenApi::Error, /type: :multipart is not valid for a parameter/)
    end

    it "rejects a body-only type inside a union" do
      expect { described_class.new(:photo, type: [:string, :file]) }
        .to raise_error(Raxon::OpenApi::Error, /type: :file is not valid for a parameter/)
    end

    it "rejects it in every location, not just query" do
      %i[query header path cookie].each do |location|
        expect { described_class.new(:photo, type: :file, in: location) }
          .to raise_error(Raxon::OpenApi::Error, /not valid for a parameter/)
      end
    end

    it "suggests a request body declaration using the parameter's own name" do
      expect { described_class.new(:avatar, type: :file) }
        .to raise_error(Raxon::OpenApi::Error, /body\.property :avatar, type: :file/)
    end

    it "still allows :file on a request body property" do
      body = Raxon::OpenApi::RequestBody.new(type: :multipart)
      expect { body.property :photo, type: :file }.not_to raise_error
      expect(body.properties[:photo].type).to eq("file")
    end
  end
end
