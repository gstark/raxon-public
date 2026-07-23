# frozen_string_literal: true

module Raxon
  # Rack boundary for mounting Raxon beside another Rack application. Only a
  # matched request enters the Raxon stack; fallback requests keep their env and
  # exception handling untouched.
  class Mount
    def initialize(fallback, app:, suffixes: {})
      @fallback = fallback
      @app = app.respond_to?(:call) ? app : app.call
      @suffixes = suffixes
    end

    def call(env)
      original_path = env["PATH_INFO"]
      candidate_paths(original_path).each do |path, format|
        next unless Raxon::RouteLoader.routes.find(env["REQUEST_METHOD"], path)

        routed_env = env.dup
        routed_env["PATH_INFO"] = path
        routed_env["raxon.original_path"] = original_path
        routed_env["raxon.format"] = format if format
        return @app.call(routed_env)
      end
      @fallback.call(env)
    end

    private

    def candidate_paths(path)
      candidates = [[path, nil]]
      @suffixes.each do |suffix, format|
        candidates << [path.delete_suffix(suffix), format] if path.end_with?(suffix) && path != suffix
      end
      candidates
    end
  end
end
