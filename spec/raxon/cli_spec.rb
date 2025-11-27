require "spec_helper"
require "raxon/cli"
require "raxon/cli/new_command"
require "raxon/cli/server_command"
require "raxon/cli/routes_command"

RSpec.describe Raxon::Command do
  describe ".exit_on_failure?" do
    it "returns true" do
      expect(described_class.exit_on_failure?).to be true
    end
  end

  describe "#version" do
    it "displays the Raxon version" do
      expect { described_class.new.version }.to output("Raxon #{Raxon::VERSION}\n").to_stdout
    end
  end

  describe "#new" do
    it "creates and executes a NewCommand with project path and options" do
      project_path = "/tmp/test_project"
      options = {database: "postgresql", skip_git: false, skip_bundle: false}

      command = described_class.new
      allow(command).to receive(:options).and_return(options)

      new_command_instance = instance_double(Raxon::NewCommand)
      expect(Raxon::NewCommand).to receive(:new).with(project_path, options).and_return(new_command_instance)
      expect(new_command_instance).to receive(:execute)

      command.new(project_path)
    end
  end

  describe "#server" do
    it "creates and executes a ServerCommand with options and additional args" do
      options = {port: "3000", host: "0.0.0.0"}
      additional_args = ["--env", "production"]

      command = described_class.new
      allow(command).to receive(:options).and_return(options)

      server_command_instance = instance_double(Raxon::ServerCommand)
      expect(Raxon::ServerCommand).to receive(:new).with(options, additional_args).and_return(server_command_instance)
      expect(server_command_instance).to receive(:execute)

      command.server(*additional_args)
    end

    it "handles empty additional args" do
      options = {port: "9292", host: "localhost"}

      command = described_class.new
      allow(command).to receive(:options).and_return(options)

      server_command_instance = instance_double(Raxon::ServerCommand)
      expect(Raxon::ServerCommand).to receive(:new).with(options, []).and_return(server_command_instance)
      expect(server_command_instance).to receive(:execute)

      command.server
    end
  end

  describe "#routes" do
    it "creates and executes a RoutesCommand with options" do
      options = {}

      command = described_class.new
      allow(command).to receive(:options).and_return(options)

      routes_command_instance = instance_double(Raxon::RoutesCommand)
      expect(Raxon::RoutesCommand).to receive(:new).with(options).and_return(routes_command_instance)
      expect(routes_command_instance).to receive(:execute)

      command.routes
    end
  end

  describe "Raxon::CLI alias" do
    it "is an alias for Raxon::Command" do
      expect(Raxon::CLI).to eq(Raxon::Command)
    end
  end
end
