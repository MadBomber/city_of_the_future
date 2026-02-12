require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/web/display_bridge"

class DisplayBridgeTest < Minitest::Test
  def setup
    @bus    = BusSetup.create_bus
    @bridge = DisplayBridge.new
    @bridge.attach(@bus)
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Event storage tests
  # ==========================================

  def test_starts_empty
    assert_equal 0, @bridge.event_count
    assert_equal 0, @bridge.last_id
  end

  def test_stores_display_events
    drain_channels

    Async do
      @bus.publish(:display, DisplayEvent.new(
        type:      :test_event,
        data:      { message: "hello" },
        timestamp: Time.now
      ))

      sleep 0.05
    end

    assert_equal 1, @bridge.event_count
    events = @bridge.events_since(0)
    assert_equal 1, events.size
    assert_equal :test_event, events.first[:type]
    assert_equal({ message: "hello" }, events.first[:data])
  end

  def test_stores_incoming_call_events
    drain_channels

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-1",
        caller:      "Jane",
        location:    "123 Main",
        description: "Fire",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    call_event = events.find { |e| e[:type] == :incoming_call }
    assert call_event, "Should store incoming call events"
    assert_equal "C-1", call_event[:data][:call_id]
    assert_equal "Jane", call_event[:data][:caller]
  end

  def test_stores_field_report_events
    drain_channels

    Async do
      @bus.publish(:field_reports, FieldReport.new(
        call_id:    "C-2",
        department: "Fire",
        unit_id:    "E-1",
        status:     :dispatched,
        notes:      "En route",
        timestamp:  Time.now
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    rpt = events.find { |e| e[:type] == :field_report }
    assert rpt, "Should store field report events"
    assert_equal "Fire", rpt[:data][:department]
    assert_equal "E-1", rpt[:data][:unit_id]
  end

  def test_stores_dept_status_events
    drain_channels

    Async do
      @bus.publish(:department_status, DeptStatus.new(
        department:      "Police",
        available_units: 3,
        active_calls:    1,
        capacity_pct:    0.75
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    st = events.find { |e| e[:type] == :dept_status }
    assert st, "Should store dept status events"
    assert_equal "Police", st[:data][:department]
    assert_equal 0.75, st[:data][:capacity_pct]
  end

  def test_stores_escalation_events
    drain_channels

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-3",
        reason:                "No department",
        original_call:         "unknown",
        attempted_departments: [:fire],
        timestamp:             Time.now
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    esc = events.find { |e| e[:type] == :escalation_event }
    assert esc, "Should store escalation events"
    assert_equal "C-3", esc[:data][:call_id]
  end

  def test_stores_governance_events
    drain_channels

    Async do
      @bus.publish(:governance, PolicyEvent.new(
        action:    "install_method",
        decision:  :approved,
        reason:    "Passed checks",
        timestamp: Time.now
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    gov = events.find { |e| e[:type] == :governance_event }
    assert gov, "Should store governance events"
    assert_equal :approved, gov[:data][:decision]
  end

  # ==========================================
  # events_since filtering
  # ==========================================

  def test_events_since_returns_only_new_events
    drain_channels

    Async do
      3.times do |i|
        @bus.publish(:display, DisplayEvent.new(
          type:      :seq_test,
          data:      { n: i },
          timestamp: Time.now
        ))
      end

      sleep 0.05
    end

    all = @bridge.events_since(0)
    assert_equal 3, all.size

    after_first = @bridge.events_since(all[0][:id])
    assert_equal 2, after_first.size
    assert_equal 1, after_first[0][:data][:n]

    after_second = @bridge.events_since(all[1][:id])
    assert_equal 1, after_second.size
    assert_equal 2, after_second[0][:data][:n]
  end

  def test_events_since_returns_empty_when_caught_up
    drain_channels

    Async do
      @bus.publish(:display, DisplayEvent.new(
        type: :one, data: {}, timestamp: Time.now
      ))

      sleep 0.05
    end

    last = @bridge.last_id
    assert_equal [], @bridge.events_since(last)
  end

  # ==========================================
  # Sequencing
  # ==========================================

  def test_event_ids_are_sequential
    drain_channels

    Async do
      5.times do
        @bus.publish(:display, DisplayEvent.new(
          type: :seq, data: {}, timestamp: Time.now
        ))
      end

      sleep 0.05
    end

    events = @bridge.events_since(0)
    ids = events.map { |e| e[:id] }
    assert_equal ids, ids.sort
    assert_equal ids.uniq, ids
  end

  def test_events_have_timestamp
    drain_channels

    Async do
      @bus.publish(:display, DisplayEvent.new(
        type: :ts_test, data: {}, timestamp: Time.now
      ))

      sleep 0.05
    end

    events = @bridge.events_since(0)
    assert events.first[:timestamp], "Events should have a timestamp"
    assert_match(/\d{2}:\d{2}:\d{2}/, events.first[:timestamp])
  end

  private

  # Drain channels that aren't subscribed by the bridge
  def drain_channels
    @bus.subscribe(:dispatch)      { |d| d.ack! }
    @bus.subscribe(:llm_requests)  { |d| d.ack! }
    @bus.subscribe(:llm_responses) { |d| d.ack! }
    @bus.subscribe(:method_gen)    { |d| d.ack! }
    @bus.subscribe(:voice_in)      { |d| d.ack! }
    @bus.subscribe(:voice_out)     { |d| d.ack! }
  end
end
