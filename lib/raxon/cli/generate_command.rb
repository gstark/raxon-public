# frozen_string_literal: true

require "fileutils"

module Raxon
  # Scaffolds project files. Currently generates route files:
  #
  #   raxon generate route api/v1/users get post
  #   raxon generate route api/v1/users/__id__ get
  #
  # Path parameter segments may be written as __id__, {id}, :id, or $id; all
  # are normalized to the recommended dunder style.
  class GenerateCommand
    GENERATORS = %w[route].freeze

    attr_reader :type, :args, :options

    def initialize(type, args, options = {})
      @type = type
      @args = args
      @options = options
    end

    def execute
      # The raxon executable only loads the CLI; pull in the framework for
      # RouteLoader and configuration access.
      require_relative "../../raxon"

      unless GENERATORS.include?(type)
        puts "Error: Unknown generator '#{type}' (available: #{GENERATORS.join(", ")})"
        exit 1
      end

      generate_route
    end

    private

    def generate_route
      if args.empty?
        puts "Error: Missing route path (usage: raxon generate route PATH [METHOD ...])"
        exit 1
      end

      path, *methods = args
      methods = ["get"] if methods.empty?
      methods = methods.map(&:downcase)

      invalid = methods - Raxon::RouteLoader::VALID_HTTP_METHODS
      if invalid.any?
        puts "Error: Invalid HTTP method(s): #{invalid.join(", ")} (valid: #{Raxon::RouteLoader::VALID_HTTP_METHODS.join(", ")})"
        exit 1
      end

      segments = normalize_segments(path)
      route_dir = File.join(routes_directory, *segments)

      methods.each do |method|
        create_route_file(route_dir, segments, method)
      end
    end

    def routes_directory
      Array(Raxon.configuration.routes_directory).compact.first
    end

    # Normalize path parameter segments ({id}, :id, $id) to dunder style.
    def normalize_segments(path)
      path.split("/").reject(&:empty?).map do |segment|
        param = segment[/\A\{(\w+)\}\z/, 1] || segment[/\A[:$](\w+)\z/, 1]
        param ? "__#{param}__" : segment
      end
    end

    def create_route_file(route_dir, segments, method)
      file_path = File.join(route_dir, "#{method}.rb")

      if File.exist?(file_path)
        puts "Error: #{file_path} already exists"
        exit 1
      end

      FileUtils.mkdir_p(route_dir)
      File.write(file_path, route_template(segments, method))
      puts "Created #{file_path}"
    end

    def route_template(segments, method)
      url_path = "/" + segments.map { |segment|
        (param = param_name(segment)) ? "{#{param}}" : segment
      }.join("/")

      param_lines = segments.filter_map { |segment| param_name(segment) }.map do |param|
        %(  endpoint.path_param :#{param}, type: :string, description: "TODO: describe #{param}"\n)
      end.join

      <<~RUBY
        Raxon.route do |endpoint|
          endpoint.description "TODO: describe #{method.upcase} #{url_path}"

        #{param_lines}  endpoint.response 200, type: :object do |response|
            response.property :success, type: :boolean
          end

          endpoint.handler do |request, response, metadata|
            response.ok success: true
          end
        end
      RUBY
    end

    def param_name(segment)
      segment[/\A__(\w+)__\z/, 1]
    end
  end
end
