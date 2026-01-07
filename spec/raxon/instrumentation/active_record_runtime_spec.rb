# frozen_string_literal: true

require "spec_helper"
require "raxon/instrumentation/active_record_runtime"

RSpec.describe Raxon::Instrumentation::ActiveRecordRuntime do
  describe "#runtime" do
    it "starts at zero" do
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new
      expect(tracker.runtime).to eq(0)
    end
  end

  describe "#track" do
    it "accumulates runtime from sql.active_record events" do
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new

      tracker.track do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") do
          sleep 0.01
        end
      end

      expect(tracker.runtime).to be >= 10 # at least 10ms
    end

    it "only tracks events during the block" do
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new

      # Event before tracking
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") do
        sleep 0.01
      end

      tracker.track do
        # No AR events during block
      end

      expect(tracker.runtime).to eq(0)
    end

    it "stops tracking after block completes" do
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new

      tracker.track do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") do
          sleep 0.01
        end
      end

      runtime_after_block = tracker.runtime

      # Event after tracking should not be counted
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 2") do
        sleep 0.01
      end

      expect(tracker.runtime).to eq(runtime_after_block)
    end
  end
end
