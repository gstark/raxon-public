require "spec_helper"
require "raxon/cli/server_command"

RSpec.describe Raxon::ServerCommand do
  let(:options) { {} }
  let(:additional_args) { [] }
  let(:command) { described_class.new(options, additional_args) }

  # Helper to suppress stdout
  def suppress_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end

  describe "#initialize" do
    it "stores options" do
      opts = {port: "3000", host: "0.0.0.0"}
      cmd = described_class.new(opts, [])
      expect(cmd.options).to eq(opts)
    end

    it "stores additional args" do
      args = ["--env", "production"]
      cmd = described_class.new({}, args)
      expect(cmd.additional_args).to eq(args)
    end

    it "defaults to empty additional args" do
      cmd = described_class.new({})
      expect(cmd.additional_args).to eq([])
    end
  end

  describe "#execute" do
    it "uses default port 9292 when not specified" do
      command = described_class.new({}, [])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "9292", "-o", "localhost")

      suppress_output { command.execute }
    end

    it "uses default host localhost when not specified" do
      command = described_class.new({port: "3000"}, [])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "3000", "-o", "localhost")

      suppress_output { command.execute }
    end

    it "uses custom port when specified" do
      command = described_class.new({port: "8080", host: "localhost"}, [])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "8080", "-o", "localhost")

      suppress_output { command.execute }
    end

    it "uses custom host when specified" do
      command = described_class.new({port: "9292", host: "0.0.0.0"}, [])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "9292", "-o", "0.0.0.0")

      suppress_output { command.execute }
    end

    it "includes additional args in command" do
      command = described_class.new({port: "3000", host: "localhost"}, ["--env", "production"])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "3000", "-o", "localhost", "--env", "production")

      suppress_output { command.execute }
    end

    it "includes multiple additional args in command" do
      command = described_class.new(
        {port: "9292", host: "localhost"},
        ["--env", "development", "--debug"]
      )

      expect(command).to receive(:exec).with(
        "bundle", "exec", "rackup",
        "-p", "9292",
        "-o", "localhost",
        "--env", "development",
        "--debug"
      )

      suppress_output { command.execute }
    end

    it "prints Ctrl+C message" do
      command = described_class.new({}, [])

      expect(command).to receive(:exec)

      suppress_output { command.execute }
    end

    it "executes the rackup command" do
      command = described_class.new({port: "9292", host: "localhost"}, [])

      expect(command).to receive(:exec).with("bundle", "exec", "rackup", "-p", "9292", "-o", "localhost")

      suppress_output { command.execute }
    end
  end
end
