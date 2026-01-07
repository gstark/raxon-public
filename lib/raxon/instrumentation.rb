# frozen_string_literal: true

require "active_support/notifications"
require_relative "instrumentation/active_record_runtime"

module Raxon
  # Rails-compatible instrumentation for APM tools.
  #
  # Emits start_processing.action_controller and process_action.action_controller
  # events that match Rails payload format for compatibility with New Relic,
  # Datadog, Skylight, and other APM tools.
  module Instrumentation
    class << self
      # Instrument a request, emitting Rails-compatible notifications.
      #
      # @param request [Raxon::Request] The request object
      # @param response [Raxon::Response] The response object
      # @param endpoint [Raxon::OpenApi::Endpoint] The matched endpoint
      # @yield The request handling block
      # @return [Object] The return value of the block
      def instrument_request(request, response, endpoint)
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
          payload[:status] = response.status_code
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
        {
          controller: controller_from_endpoint(endpoint),
          action: request.rack_request.request_method,
          params: request.params.to_h,
          headers: request.rack_request.env.select { |k, _| k.start_with?("HTTP_") },
          format: :json,
          method: request.rack_request.request_method,
          path: request.rack_request.path
        }
      end
    end
  end
end
