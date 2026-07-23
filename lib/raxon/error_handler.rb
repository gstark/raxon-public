# frozen_string_literal: true

module Raxon
  # Rack middleware for handling unhandled exceptions in API endpoints.
  #
  # This middleware catches any exceptions that occur during request processing
  # and converts them into properly formatted JSON error responses. This prevents
  # raw exception details from being leaked to clients and ensures consistent
  # error response formatting.
  #
  # Raxon::Server installs this automatically (config.wrap_error_handler, default
  # true), so you only need to add it explicitly to pass a logger/on_error or to
  # place it at a specific point in your middleware stack — doing so replaces the
  # automatic one.
  #
  # @example Basic usage (only needed to customize; on by default)
  #   use Raxon::ErrorHandler
  #
  # @example With custom logger
  #   use Raxon::ErrorHandler, logger: Rails.logger
  #
  # @example With custom error handler
  #   use Raxon::ErrorHandler, on_error: ->(request, response, error, env) {
  #     Sentry.capture_exception(error, extra: {
  #       path: request.path,
  #       params: request.params,
  #       user_agent: env['HTTP_USER_AGENT']
  #     })
  #   }
  #
  class ErrorHandler
    # Initialize the error handler middleware.
    #
    # @param app [Object] The Rack application
    # @param logger [Logger, nil] Optional logger for error logging
    # @param on_error [Proc, nil] Optional callback for custom error handling
    #
    # @example
    #   ErrorHandler.new(app, logger: Logger.new($stdout))
    def initialize(app, logger: nil, on_error: nil)
      @app = app
      @logger = logger
      @on_error = on_error
    end

    # Process the request and handle any exceptions.
    #
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response array [status, headers, body]
    def call(env)
      @app.call(env)
    rescue => e
      handle_error(e, env)
    end

    private

    # Handle an exception by logging it and returning a JSON error response.
    #
    # @param error [StandardError] The exception that was raised
    # @param env [Hash] Rack environment hash
    # @return [Array] Rack response array with 500 status
    def handle_error(error, env)
      log_error(error, env)
      notify_error(error, env)

      [
        500,
        {"content-type" => "application/json"},
        [JSON.generate({error: "Internal Server Error"})]
      ]
    end

    # Log the error with details.
    #
    # The exception message and request line are sanitized before logging: an
    # attacker-influenced message or path can carry CR/LF and forge extra log
    # lines. Backtrace frames are sanitized individually so the intentional
    # multi-line layout is kept while no single frame can inject a new record.
    #
    # @param error [StandardError] The exception to log
    # @param env [Hash] Rack environment hash
    # @return [void]
    def log_error(error, env)
      return unless @logger

      request = Rack::Request.new(env)
      @logger.error("#{error.class}: #{sanitize(error.message)}")
      @logger.error("Request: #{sanitize(request.request_method)} #{sanitize(request.path)}")
      return unless error.backtrace

      frames = error.backtrace.map { |frame| sanitize(frame) }.join("\n  ")
      @logger.error("Backtrace:\n  #{frames}")
    end

    # Notify external error tracking service if configured.
    #
    # Calls the on_error callback with: (request, response, error, env).
    #
    # SECURITY: +env+ is the raw Rack environment and carries credentials
    # (Authorization, Cookie, X-API-Key headers, the body stream, ...). It is
    # passed through so callbacks that need request context work, but a callback
    # that forwards data to an external service must filter first — see
    # {Raxon::ParameterFilter} and docs/security.md. Raxon does not serialize
    # +env+ itself.
    #
    # @param error [StandardError] The exception to notify
    # @param env [Hash] Rack environment hash
    # @return [void]
    def notify_error(error, env)
      return unless @on_error

      # Get Raxon request/response objects from env
      request = env["raxon.request"]
      response = env["raxon.response"]

      # Call the callback with all four arguments
      @on_error.call(request, response, error, env)
    rescue => e
      # Don't let error notification failures crash the app
      @logger&.error("Error notification failed: #{sanitize(e.message)}")
    end

    # Replace control characters (notably CR/LF) with spaces so a value cannot
    # forge additional log records.
    #
    # @param value [Object]
    # @return [String]
    def sanitize(value)
      value.to_s.gsub(/[[:cntrl:]]/, " ")
    end
  end
end
