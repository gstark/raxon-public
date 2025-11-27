require "spec_helper"
require "raxon/cli/new_command"
require "tmpdir"

RSpec.describe Raxon::NewCommand do
  let(:project_path) { File.join(Dir.tmpdir, "test_raxon_project_#{Time.now.to_i}") }
  let(:options) { {} }
  let(:command) { described_class.new(project_path, options) }

  after do
    FileUtils.rm_rf(project_path) if File.exist?(project_path)
  end

  # Helper to suppress stdout
  def suppress_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end

  describe "#initialize" do
    it "expands the project path" do
      relative_path = "my_project"
      cmd = described_class.new(relative_path)
      expect(cmd.project_path).to eq(File.expand_path(relative_path))
    end

    it "extracts project name from path" do
      expect(command.project_name).to eq(File.basename(project_path))
    end

    it "stores options" do
      opts = {skip_git: true}
      cmd = described_class.new(project_path, opts)
      expect(cmd.options).to eq(opts)
    end
  end

  describe "#execute" do
    context "when project directory already exists" do
      it "exits with error message" do
        FileUtils.mkdir_p(project_path)

        expect { command.execute }.to output(/Error: Directory .* already exists/).to_stdout
          .and raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end
    end

    context "when project directory does not exist" do
      it "creates the project structure" do
        allow(command).to receive(:system) # Stub git/bundle commands

        suppress_output { command.execute }

        expect(File.directory?(project_path)).to be true
        expect(File.directory?(File.join(project_path, "config"))).to be true
        expect(File.directory?(File.join(project_path, "lib"))).to be true
        expect(File.directory?(File.join(project_path, "routes/api/v1"))).to be true
        expect(File.directory?(File.join(project_path, "spec/fixtures"))).to be true
        expect(File.directory?(File.join(project_path, "doc/apidoc"))).to be true
        expect(File.directory?(File.join(project_path, "tmp"))).to be true
        expect(File.directory?(File.join(project_path, "log"))).to be true
      end

      it "creates config.ru file" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        config_ru = File.join(project_path, "config.ru")
        expect(File.exist?(config_ru)).to be true
        content = File.read(config_ru)
        expect(content).to include("require \"bundler/setup\"")
        expect(content).to include("Raxon::Server.new")
      end

      it "creates Rakefile" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        rakefile = File.join(project_path, "Rakefile")
        expect(File.exist?(rakefile)).to be true
        content = File.read(rakefile)
        expect(content).to include("Raxon.load_tasks")
      end

      it "creates README.md with project name" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        readme = File.join(project_path, "README.md")
        expect(File.exist?(readme)).to be true
        content = File.read(readme)
        expect(content).to include("# #{File.basename(project_path).capitalize}")
        expect(content).to include("A Raxon JSON API project")
      end

      it "creates Gemfile" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        gemfile = File.join(project_path, "Gemfile")
        expect(File.exist?(gemfile)).to be true
        content = File.read(gemfile)
        expect(content).to include("gem \"raxon\"")
        expect(content).to include("gem \"puma\"")
      end

      it "creates config/app.rb" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        config_app = File.join(project_path, "config/app.rb")
        expect(File.exist?(config_app)).to be true
        content = File.read(config_app)
        expect(content).to include("require \"raxon\"")
        expect(content).to include("Raxon.configure")
      end

      it "creates example health check route" do
        allow(command).to receive(:system)

        suppress_output { command.execute }

        health_route = File.join(project_path, "routes/api/v1/health/get.rb")
        expect(File.exist?(health_route)).to be true
        content = File.read(health_route)
        expect(content).to include("Health check endpoint")
        expect(content).to include("success: true")
      end

      it "initializes git by default" do
        expect(command).to receive(:system).with("git init")
        expect(command).to receive(:system).with("git add .")
        expect(command).to receive(:system).with("git commit -m 'Initial commit'")
        expect(command).to receive(:system).with("bundle install")

        suppress_output { command.execute }

        gitignore = File.join(project_path, ".gitignore")
        expect(File.exist?(gitignore)).to be true
        content = File.read(gitignore)
        expect(content).to include("/.bundle/")
        expect(content).to include(".env")
      end

      it "runs bundle install by default" do
        expect(command).to receive(:system).with("git init")
        expect(command).to receive(:system).with("git add .")
        expect(command).to receive(:system).with("git commit -m 'Initial commit'")
        expect(command).to receive(:system).with("bundle install")

        suppress_output { command.execute }
      end

      it "skips git when skip_git option is true" do
        command_with_skip = described_class.new(project_path, {skip_git: true, skip_bundle: true})

        expect(command_with_skip).not_to receive(:system).with("git init")

        suppress_output { command_with_skip.execute }
      end

      it "skips bundle install when skip_bundle option is true" do
        command_with_skip = described_class.new(project_path, {skip_git: true, skip_bundle: true})

        expect(command_with_skip).not_to receive(:system).with("bundle install")

        suppress_output { command_with_skip.execute }
      end

      it "prints success message" do
        allow(command).to receive(:system)

        expect { command.execute }.to output(/✓ Project created successfully!/).to_stdout
      end
    end
  end
end
