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

    it "no-ops when ActiveSupport::Notifications is absent" do
      hide_const("ActiveSupport::Notifications")
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new

      result = tracker.track { :handled }

      expect(result).to eq(:handled)
      expect(tracker.runtime).to eq(0)
    end

    it "ignores queries that other threads run during the block" do
      tracker = Raxon::Instrumentation::ActiveRecordRuntime.new

      tracker.track do
        Thread.new do
          ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") do
            sleep 0.01
          end
        end.join
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

RSpec.describe Raxon::Instrumentation::ActiveRecordRuntime, "subscription" do
  it "subscribes one time, not once per request" do
    described_class.new.track {}
    allow(ActiveSupport::Notifications).to receive(:subscribe).and_call_original
    allow(ActiveSupport::Notifications).to receive(:unsubscribe).and_call_original

    3.times { described_class.new.track {} }

    expect(ActiveSupport::Notifications).not_to have_received(:subscribe)
    expect(ActiveSupport::Notifications).not_to have_received(:unsubscribe)
  end

  it "counts a nested block's queries only in the inner tracker, then resumes the outer one" do
    outer = described_class.new
    inner = described_class.new

    outer.track do
      inner.track do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") { sleep 0.01 }
      end
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 2") { sleep 0.01 }
    end

    expect(inner.runtime).to be >= 10
    expect(outer.runtime).to be >= 10
    expect(outer.runtime).to be < inner.runtime + 10
  end

  it "stops counting after a block that raises" do
    tracker = described_class.new

    expect { tracker.track { raise "boom" } }.to raise_error("boom")
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1") { sleep 0.01 }

    expect(tracker.runtime).to eq(0)
  end

  it "raises and counts nothing when the notification subscription fails" do
    subscribed = described_class.instance_variable_get(:@subscribed)
    described_class.instance_variable_set(:@subscribed, nil)
    tracker = described_class.new
    allow(ActiveSupport::Notifications).to receive(:subscribe).and_raise("subscription broken")

    expect { tracker.track { :never_reached } }.to raise_error("subscription broken")
    expect(tracker.runtime).to eq(0)
  ensure
    described_class.instance_variable_set(:@subscribed, subscribed)
  end
end
