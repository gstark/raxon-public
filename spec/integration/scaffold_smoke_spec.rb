# frozen_string_literal: true

require "spec_helper"
# Loaded explicitly: under `bundle exec` the constant is already there, but a
# bare `rake` is not, and with_unbundled_env below needs it either way.
require "bundler"
require "open3"
require "shellwords"
require "tmpdir"

# Boots the actual output of `raxon new` and runs the loop the docs tell users
# to run.
#
# Every other spec here runs inside the repo's own bundle, which is not the
# environment a user gets. That gap hid B-1: lib/tasks/generate.rake required
# active_support/core_ext/hash, which is not a gemspec dependency but resolved
# transitively in this repo. Every spec passed while `rake -T`,
# `raxon:openapi:generate`, and `raxon:routes` all raised LoadError in a real
# project — the primary "did my schema compile?" loop, broken out of the box.
#
# The bug was in what the gemspec *declares*, not in what the code does, so no
# in-process test could see it. This one resolves a bundle from the gemspec
# alone and shells out, so a runtime dependency that is used but undeclared
# fails here.
RSpec.describe "raxon new output", :scaffold do
  def self.repo_root = File.expand_path("../..", __dir__)

  # Run a command with the target project's bundle rather than this repo's.
  # with_unbundled_env is what makes the isolation real: without it the parent's
  # BUNDLE_GEMFILE and RUBYOPT leak in and the subprocess resolves against the
  # repo's gems, which is exactly the contamination this spec exists to catch.
  def self.run_in(directory, command, gemfile: File.join(directory, "Gemfile"))
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({"BUNDLE_GEMFILE" => gemfile}, command, chdir: directory)
    end
    {ok: status.success?, output: output}
  end

  def run_in(...) = self.class.run_in(...)

  # Generating and bundling costs a second or two, so it happens once for the
  # whole group rather than per example.
  before(:context) do
    root = self.class.repo_root
    @workspace = Dir.mktmpdir("raxon-scaffold")
    @project = File.join(@workspace, "smoke-api")

    exe = Shellwords.escape(File.join(root, "exe", "raxon"))
    generate = self.class.run_in(@workspace, "bundle exec #{exe} new smoke-api --skip-bundle --skip-git",
      gemfile: File.join(root, "Gemfile"))
    raise "raxon new failed:\n#{generate[:output]}" unless generate[:ok]

    # The scaffold depends on the published gem; point it at this checkout so
    # the test exercises the working tree.
    gemfile = File.join(@project, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub(/^gem "raxon".*$/, %(gem "raxon", path: #{root.dump})))

    install = self.class.run_in(@project, "bundle install")
    raise "bundle install failed in the scaffolded project:\n#{install[:output]}" unless install[:ok]
  end

  after(:context) { FileUtils.remove_entry(@workspace) if @workspace }

  it "generates a project whose bundle excludes this repo's dev dependencies" do
    # Guards the guard. If the scaffolded project could see the repo's gems,
    # every assertion below would be meaningless. activesupport is the gem B-1
    # accidentally relied on, and it is not a Raxon dependency.
    result = run_in(@project, %(bundle exec ruby -e 'require "active_support"'))

    expect(result[:ok]).to be(false)
    expect(result[:output]).to match(/cannot load such file.*active_support/m)
  end

  it "lists its routes" do
    result = run_in(@project, "bundle exec raxon routes")

    expect(result[:ok]).to be(true), "raxon routes failed:\n#{result[:output]}"
    expect(result[:output]).to include("/api/v1/health")
  end

  it "exposes its rake tasks" do
    # `rake -T` loads every .rake file, so an undeclared require in any of them
    # surfaces here even when the task itself is never invoked.
    result = run_in(@project, "bundle exec rake -T")

    expect(result[:ok]).to be(true), "rake -T failed:\n#{result[:output]}"
    expect(result[:output]).to include("raxon:openapi:generate")
  end

  it "generates a valid OpenAPI document" do
    result = run_in(@project, "bundle exec rake raxon:openapi:generate")
    expect(result[:ok]).to be(true), "openapi:generate failed:\n#{result[:output]}"

    document = JSON.parse(File.read(File.join(@project, "doc", "apidoc", "api.json")))

    expect(document["openapi"]).to start_with("3.")
    expect(document["paths"]).to have_key("/api/v1/health")
  end

  it "passes its own generated test suite" do
    # The scaffold ships a spec that runs conform_to_response_schema against the
    # declared contract, so this covers the whole declare/serve/verify loop.
    result = run_in(@project, "bundle exec rspec")

    expect(result[:ok]).to be(true), "rspec failed in the scaffolded project:\n#{result[:output]}"
  end
end
