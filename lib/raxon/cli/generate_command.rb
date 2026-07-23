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

      # Honor the project's configured routes directory rather than the default.
      require_relative "project_loader"
      Raxon::ProjectLoader.load_configuration { nil }

      unless GENERATORS.include?(type)
        puts "Error: Unknown generator '#{type}' (available: #{GENERATORS.join(", ")})"
        exit 1
      end

      generate_route
    end

    private

    # A safe literal path segment: letters, digits, and a few URL/filename-safe
    # punctuation characters. Deliberately excludes separators, quotes, control
    # characters, and "#{" interpolation syntax; "." and ".." are rejected
    # separately (they match this format but are traversal components).
    SEGMENT_FORMAT = /\A[A-Za-z0-9._-]+\z/

    def generate_route
      if args.empty?
        abort_with "Missing route path (usage: raxon generate route PATH [METHOD ...])"
      end

      path, *methods = args
      methods = ["get"] if methods.empty?
      methods = methods.map(&:downcase)

      invalid = methods - Raxon::RouteLoader::VALID_HTTP_METHODS
      if invalid.any?
        abort_with "Invalid HTTP method(s): #{invalid.join(", ")} (valid: #{Raxon::RouteLoader::VALID_HTTP_METHODS.join(", ")})"
      end

      segments = normalize_segments(path)
      route_dir = File.join(routes_directory, *segments)
      ensure_within_routes!(route_dir)

      methods.each do |method|
        create_route_file(route_dir, segments, method)
      end
    end

    def routes_directory
      Array(Raxon.configuration.routes_directory).compact.first
    end

    # Normalize parameter segments ({id}, :id, $id) to dunder style and reject
    # anything that is not a safe literal segment. This prevents both directory
    # traversal (a ".." component escaping the routes tree) and Ruby source
    # injection (a segment such as `x#{...}` written into the generated file)
    # when the path originates from an untrusted source, e.g. CI metadata.
    def normalize_segments(path)
      path.split("/").reject(&:empty?).map { |segment| normalize_segment(segment) }
    end

    def normalize_segment(segment)
      if (param = segment[/\A\{(\w+)\}\z/, 1] || segment[/\A[:$](\w+)\z/, 1])
        return "__#{param}__"
      end

      unless segment.match?(SEGMENT_FORMAT) && segment != "." && segment != ".."
        abort_with "Invalid route segment #{segment.inspect}. " \
                   "Use letters, digits, '.', '_', '-', or a parameter segment ({id}, :id, $id, __id__)."
      end

      segment
    end

    # Refuse to generate outside the configured routes directory. Segment
    # validation already blocks "..", so this is belt-and-suspenders on the
    # resolved path.
    def ensure_within_routes!(route_dir)
      root = File.expand_path(routes_directory)
      full = File.expand_path(route_dir)
      return if full == root || full.start_with?(root + File::SEPARATOR)

      abort_with "Refusing to generate outside the routes directory (#{routes_directory})."
    end

    def create_route_file(route_dir, segments, method)
      file_path = File.join(route_dir, "#{method}.rb")

      abort_with "#{file_path} already exists" if File.exist?(file_path)

      FileUtils.mkdir_p(route_dir)
      File.write(file_path, route_template(segments, method))
      puts "Created #{file_path}"
    end

    def route_template(segments, method)
      url_path = "/" + segments.map { |segment|
        (param = param_name(segment)) ? "{#{param}}" : segment
      }.join("/")

      param_lines = segments.filter_map { |segment| param_name(segment) }.map do |param|
        # param is a validated \w+ identifier; the description is a String
        # literal serialized with #dump so no value can break out of it.
        "  endpoint.path_param :#{param}, type: :string, description: #{"TODO: describe #{param}".dump}\n"
      end.join
      param_lines += "\n" unless param_lines.empty?

      <<~RUBY
        Raxon.route do |endpoint|
          endpoint.description #{"TODO: describe #{method.upcase} #{url_path}".dump}

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

    def abort_with(message)
      puts "Error: #{message}"
      exit 1
    end
  end
end
