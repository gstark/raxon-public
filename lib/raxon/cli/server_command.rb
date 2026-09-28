module Raxon
  class ServerCommand
    attr_reader :options, :additional_args

    def initialize(options = {}, additional_args = [])
      @options = options
      @additional_args = additional_args
    end

    def execute
      port = options[:port] || "9292"
      host = options[:host] || "localhost"

      # Build rackup command
      cmd = ["bundle", "exec", "rackup"]
      cmd << "-p" << port
      cmd << "-o" << host
      cmd.concat(additional_args)

      puts "Starting Raxon server on #{host}:#{port}..."
      puts "Press Ctrl+C to stop"

      # Execute rackup
      exec(*cmd)
    end
  end
end
