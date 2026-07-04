# frozen_string_literal: true

require "spec_helper"
require "rake"
require "tmpdir"

RSpec.describe "Raxon rake tasks" do
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  before do
    Raxon.load_tasks unless Rake::Task.task_defined?("raxon:routes")
    Raxon.configure do |config|
      config.routes_directory = File.join(__dir__, "..", "fixtures", "routes")
    end
  end

  it "defines the bundled tasks" do
    expect(Rake::Task.task_defined?("raxon:openapi:generate")).to be(true)
    expect(Rake::Task.task_defined?("raxon:routes")).to be(true)
    expect(Rake::Task.task_defined?("raxon:routes:load")).to be(true)
  end

  it "loads routes and prints the route table via raxon:routes" do
    output = capture_stdout do
      Rake::Task["raxon:routes:load"].execute
      Rake::Task["raxon:routes"].execute
    end

    expect(output).to match(/Loaded \d+ route\(s\)/)
    expect(output).to include("/api/v1/json_test")
    expect(output).to match(/Total routes: \d+/)
  end

  it "generates OpenAPI JSON and HTML docs via raxon:openapi:generate" do
    Dir.mktmpdir do |dir|
      allow(Rake.application).to receive(:original_dir).and_return(dir)

      capture_stdout do
        Rake::Task["raxon:routes:load"].execute
        Rake::Task["raxon:openapi:generate"].execute
      end

      json_path = File.join(dir, "doc", "apidoc", "api.json")
      html_path = File.join(dir, "doc", "apidoc", "api.html")

      spec = JSON.parse(File.read(json_path))
      expect(spec["openapi"]).to eq("3.1.0")
      expect(spec["paths"]).to have_key("/api/v1/json_test")

      expect(File.read(html_path)).to include("swagger")
    end
  end
end
