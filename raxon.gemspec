require_relative "lib/raxon/version"

Gem::Specification.new do |spec|
  spec.name = "raxon"
  spec.version = Raxon::VERSION
  spec.authors = ["Gavin Stark"]
  spec.email = ["gavin@gstark.com"]

  spec.summary = "A Rack 3 compatible JSON API library with file-based routing"
  spec.description = "A library for building JSON APIs in Ruby using Rack 3, with automatic routing based on file paths and a clean DSL for defining endpoints"
  spec.homepage = "https://github.com/gstark/raxon"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.7"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0", "< 9"
  spec.add_dependency "alba", "~> 3"
  spec.add_dependency "dry-initializer", "~> 3"
  spec.add_dependency "dry-schema", "~> 1"
  spec.add_dependency "mustermann", "~> 3"
  spec.add_dependency "ostruct", "~> 0"
  spec.add_dependency "rack", "~> 3"
  spec.add_dependency "rackup", "~> 2"
  spec.add_dependency "thor", "~> 1"
  spec.add_dependency "tty-table", "~> 0"
end
