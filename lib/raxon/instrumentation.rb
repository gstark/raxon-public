# frozen_string_literal: true

# ActiveSupport is optional: instrumentation is a no-op passthrough without it.
begin
  require "active_support/notifications"
rescue LoadError
end

require_relative "instrumentation/active_record_runtime"

module Raxon
  # Rails-compatible instrumentation for APM tools.
  #
  # Emits start_processing.action_controller and process_action.action_controller
  # events that match Rails payload format for compatibility with New Relic,
  # Datadog, Skylight, and other APM tools.
  #
  # Requires ActiveSupport::Notifications, which Raxon does not depend on;
  # without it, instrument_request simply yields.
  module Instrumentation
    class << self
      # Whether ActiveSupport::Notifications is loaded in the host application.
      #
      # @return [Boolean]
      def available?
        defined?(::ActiveSupport::Notifications) ? true : false
      end

      # Instrument a request, emitting Rails-compatible notifications.
      #
      # @param request [Raxon::Request] The request object
      # @param response [Raxon::Response] The response object
      # @param endpoint [Raxon::OpenApi::Endpoint] The matched endpoint
      # @yield The request handling block
      # @return [Object] The return value of the block
      def instrument_request(request, response, endpoint)
        return yield unless available?

        payload = build_payload(request, endpoint)
        ar_runtime = ActiveRecordRuntime.new

        ActiveSupport::Notifications.instrument("start_processing.action_controller", payload.dup)

        ActiveSupport::Notifications.instrument("process_action.action_controller", payload) do
          ar_runtime.track do
            yield
          end
        rescue => exception
          payload[:exception] = [exception.class.name, exception.message]
          raise
        ensure
          # An exception that escaped the block was NOT handled: the response
          # object still holds the pre-error status, and the real answer will
          # come from error-handling middleware — log 500 rather than the
          # stale status. Handled exceptions (dispatched inside the block)
          # never raise through here; surface them from request metadata.
          payload[:status] = if $! && !$!.is_a?(Raxon::HaltException)
            500
          else
            response.status_code
          end
          if (handled = request.metadata[:handled_exception])
            payload[:exception] ||= [handled.class.name, handled.message]
            payload[:exception_object] ||= handled
          end
          payload[:db_runtime] = ar_runtime.runtime
          payload[:view_runtime] = 0
        end
      end

      # Extract controller name from endpoint path.
      #
      # @param endpoint [Raxon::OpenApi::Endpoint] The endpoint
      # @return [String] The controller name (path without leading slash)
      def controller_from_endpoint(endpoint)
        path = endpoint.path || "/"
        path.sub(/\A\//, "")
      end

      private

      def build_payload(request, endpoint)
        filter = parameter_filter
        raw_headers = request.rack_request.env.select { |k, _| k.start_with?("HTTP_") }

        {
          controller: controller_from_endpoint(endpoint),
          action: request.rack_request.request_method,
          params: filter.filter(request.params.to_h),
          headers: filter.filter_headers(raw_headers),
          format: :json,
          method: request.rack_request.request_method,
          path: request.rack_request.path
        }
      end

      def parameter_filter
        Raxon::ParameterFilter.new(Raxon.configuration.filter_parameters || [])
      end
    end
  end
end
