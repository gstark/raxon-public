# frozen_string_literal: true

module Raxon
  module Instrumentation
    # Tracks ActiveRecord query time during a request.
    #
    # One process-wide subscriber to sql.active_record adds each query's time
    # to the tracker of the thread that ran it. Subscribing and unsubscribing
    # for each request took the notifier's process-wide mutex two times per
    # request. The subscriber is added the first time a request is tracked,
    # and stays.
    #
    # Only the thread that runs the block counts: under a threaded server the
    # other request threads' queries would otherwise land in this request's
    # total. Queries on other threads (load_async) are not counted. Without
    # ActiveSupport::Notifications loaded, tracking is a no-op and runtime
    # stays 0.
    class ActiveRecordRuntime
      # The thread variable that holds the tracker for the running request.
      CURRENT = :raxon_active_record_runtime

      SUBSCRIBE_MUTEX = Mutex.new
      private_constant :SUBSCRIBE_MUTEX

      class << self
        # Add the process-wide subscriber, if it is not there yet.
        #
        # @return [void]
        def subscribe
          return if @subscribed

          SUBSCRIBE_MUTEX.synchronize do
            return if @subscribed

            ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
              Thread.current.thread_variable_get(CURRENT)&.add(ActiveSupport::Notifications::Event.new(*args).duration)
            end
            @subscribed = true
          end
        end
      end

      attr_reader :runtime

      def initialize
        @runtime = 0
      end

      # Track ActiveRecord runtime during the given block.
      #
      # @yield The block during which to track AR runtime
      # @return [Object] The return value of the block
      def track
        return yield unless Instrumentation.available?

        self.class.subscribe
        thread = Thread.current
        previous = thread.thread_variable_get(CURRENT)
        thread.thread_variable_set(CURRENT, self)
        begin
          yield
        ensure
          thread.thread_variable_set(CURRENT, previous)
        end
      end

      # @param duration [Float] Milliseconds
      # @return [void]
      def add(duration)
        @runtime += duration
      end
    end
  end
end
