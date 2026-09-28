RSpec.describe "Raxon environment methods" do
  around do |example|
    original_raxon_env = ENV["RAXON_ENV"]
    original_rack_env = ENV["RACK_ENV"]
    ENV.delete("RAXON_ENV")
    ENV.delete("RACK_ENV")
    example.run
  ensure
    ENV["RAXON_ENV"] = original_raxon_env
    ENV["RACK_ENV"] = original_rack_env
  end

  describe ".env" do
    it "returns RAXON_ENV when set" do
      ENV["RAXON_ENV"] = "production"
      ENV["RACK_ENV"] = "development"

      expect(Raxon.env).to eq("production")
    end

    it "falls back to RACK_ENV when RAXON_ENV is not set" do
      ENV["RACK_ENV"] = "test"

      expect(Raxon.env).to eq("test")
    end

    it "defaults to development when neither is set" do
      expect(Raxon.env).to eq("development")
    end
  end

  describe ".development?" do
    it "returns true when environment is development" do
      ENV["RAXON_ENV"] = "development"

      expect(Raxon.development?).to be true
    end

    it "returns true by default" do
      expect(Raxon.development?).to be true
    end

    it "returns false when environment is production" do
      ENV["RAXON_ENV"] = "production"

      expect(Raxon.development?).to be false
    end
  end

  describe ".production?" do
    it "returns true when environment is production" do
      ENV["RAXON_ENV"] = "production"

      expect(Raxon.production?).to be true
    end

    it "returns false when environment is development" do
      ENV["RAXON_ENV"] = "development"

      expect(Raxon.production?).to be false
    end
  end

  describe ".test?" do
    it "returns true when environment is test" do
      ENV["RAXON_ENV"] = "test"

      expect(Raxon.test?).to be true
    end

    it "returns false when environment is development" do
      ENV["RAXON_ENV"] = "development"

      expect(Raxon.test?).to be false
    end
  end
end
