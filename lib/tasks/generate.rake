# frozen_string_literal: true

require "json"
require "erb"
require "fileutils"
require "active_support/core_ext/hash"

namespace :raxon do
  namespace :openapi do
    desc "Generate OpenAPI documentation and typescript types"
    task generate: "raxon:routes:load" do
      # Find project root (where Rakefile is located)
      project_root = Rake.application.original_dir

      # Create doc directory if it doesn't exist
      doc_dir = File.join(project_root, "doc", "apidoc")
      FileUtils.mkdir_p(doc_dir)

      json_path = File.join(doc_dir, "api.json")
      html_path = File.join(doc_dir, "api.html")

      json = JSON.pretty_generate(Raxon::OpenApi::DSL.to_open_api)
      File.write(json_path, json)

      erb = ERB.new(File.read(File.join(__dir__, "template.html.erb")))
      result = erb.result(binding)
      File.write(html_path, result)
      puts "OpenAPI documentation generated: #{json_path} #{html_path}\n"
    end
  end
end
