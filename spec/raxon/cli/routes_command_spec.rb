require "spec_helper"
require "raxon/cli/routes_command"
require "raxon/routes_formatter"
require "tmpdir"

RSpec.describe Raxon::RoutesCommand do
  let(:options) { {} }
  let(:command) { described_class.new(options) }

  describe "#initialize" do
    it "stores options" do
      opts = {verbose: true}
      cmd = described_class.new(opts)
      expect(cmd.options).to eq(opts)
    end
  end

  describe "#execute" do
    context "when config.ru exists and loads successfully" do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            # Create a minimal config.ru
            File.write("config.ru", <<~RUBY)
              Raxon.configure do |config|
                config.routes_directory = "#{File.join(dir, "routes")}"
              end
            RUBY

            # Create routes directory
            FileUtils.mkdir_p("routes")

            example.run
          end
        end
      end

      it "loads config.ru and displays routes" do
        expect(Raxon::RoutesFormatter).to receive(:display)

        expect { command.execute }.not_to raise_error
      end
    end

    context "when config.ru exists but fails to load" do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            # Create a config.ru that will fail
            File.write("config.ru", "raise 'Test error'")

            # Create routes directory for fallback
            FileUtils.mkdir_p("routes")

            example.run
          end
        end
      end

      it "warns and falls back to directory configuration" do
        expect(Raxon::RoutesFormatter).to receive(:display)

        expect { command.execute }.to output(/Warning: Could not load config.ru/).to_stdout
      end
    end

    context "when config.ru does not exist" do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            FileUtils.mkdir_p("routes")
            example.run
          end
        end
      end

      it "uses default routes directory configuration" do
        expect(Raxon::RoutesFormatter).to receive(:display)

        command.execute
      end
    end

    context "when routes directory does not exist" do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            # Don't create routes directory
            example.run
          end
        end
      end

      it "exits with error message" do
        expect { command.execute }.to output(/Error: No routes directory found/).to_stdout
          .and raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end
  end
end
