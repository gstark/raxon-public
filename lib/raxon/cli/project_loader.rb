# frozen_string_literal: true

module Raxon
  # Loads a project's `config.ru` for its Raxon configuration (routes
  # directory, helpers path, …) without starting a server. Shared by the CLI
  # commands that need the project's real configuration rather than defaults.
  module ProjectLoader
    module_function

    # Load `config.ru` if present, so `Raxon.configuration` reflects the
    # project. `run` is stubbed because rackup normally provides it and we only
    # want the configuration side effects.
    #
    # @yield called instead when there is no config.ru, or when loading it fails
    # @return [void]
    def load_configuration
      stub_rackup_run

      return yield unless File.exist?("config.ru")

      begin
        load File.expand_path("config.ru")
      rescue Raxon::Error => e
        # A Raxon::Error means the project's own routes or DSL are invalid.
        # Falling back to defaults would bury the actionable message.
        puts "Error: #{e.message}"
        exit 1
      rescue LoadError, StandardError => e
        puts "Warning: Could not load config.ru (#{e.message}), using default configuration"
        yield
      end
    end

    def stub_rackup_run
      return if Object.method_defined?(:run)

      Object.class_eval do
        def run(_app)
          # Stub method - do nothing
        end
      end
    end
  end
end
