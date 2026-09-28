require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"

RSpec::Core::RakeTask.new(:spec)

# Load custom rake tasks (includes routes, openapi:generate)
Dir.glob("lib/tasks/**/*.rake").each { |r| load r }

# Define standard:fix task for auto-correction
desc "Run Standard with auto-fix"
task "standard:fix" do
  sh "standardrb --fix"
end

task default: [:spec, :standard]
