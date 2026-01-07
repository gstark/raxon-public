# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

module Raxon
  module Instrumentation
    # Tracks ActiveRecord query time during a request.
    #
    # Subscribes to sql.active_record events during a block and accumulates
    # the total time spent in database queries.
    class ActiveRecordRuntime
      attr_reader :runtime

      def initialize
        @runtime = 0
        @subscriber = nil
      end

      # Track ActiveRecord runtime during the given block.
      #
      # @yield The block during which to track AR runtime
      # @return [Object] The return value of the block
      def track
        start_tracking
        yield
      ensure
        stop_tracking
      end

      private

      def start_tracking
        @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          @runtime += event.duration
        end
      end

      def stop_tracking
        ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
        @subscriber = nil
      end
    end
  end
end
