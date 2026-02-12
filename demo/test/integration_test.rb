require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/departments"
require_relative "../lib/vsm/intelligence"
require_relative "../lib/vsm/operations"
require_relative "../lib/llm/scenario_driver"
require_relative "../lib/scenario/player"
require_relative "../lib/web/display_bridge"

class IntegrationTest < Minitest::Test
  SCENARIO_PATH = File.expand_path("../scenarios/demo.jsonl", __dir__)
  CALLS_PATH    = File.expand_path("../scenarios/demo_calls.yml", __dir__)

  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Replay driver tests
  # ==========================================

  def test_scenario_driver_loads_all_nine_responses
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    responses = []
    @bus.subscribe(:llm_responses) do |delivery|
      responses << delivery.message
      delivery.ack!
    end

    Async do
      9.times do |i|
        @bus.publish(:llm_requests, LLMRequest.new(
          prompt:         "test",
          tools:          nil,
          model:          nil,
          correlation_id: "intel-C-00#{i + 1}"
        ))
      end

      sleep 0.5
    end

    assert_equal 9, responses.size

    by_id = responses.each_with_object({}) { |r, h| h[r.correlation_id] = r }
    assert_match(/fire/, by_id["intel-C-001"].content)
    assert_match(/police/, by_id["intel-C-002"].content)
    assert_match(/ems/, by_id["intel-C-003"].content)
    assert_match(/utilities/, by_id["intel-C-004"].content)
  end

  def test_scenario_driver_handles_unknown_correlation_id
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    response = nil
    @bus.subscribe(:llm_responses) do |delivery|
      response = delivery.message
      delivery.ack!
    end

    Async do
      @bus.publish(:llm_requests, LLMRequest.new(
        prompt:         "unknown request",
        tools:          nil,
        model:          nil,
        correlation_id: "nonexistent-id"
      ))

      sleep 0.1
    end

    assert response, "Should still produce a response for unknown IDs"
    assert_match(/department/, response.content)
  end

  # ==========================================
  # Intelligence + replay integration
  # ==========================================

  def test_intelligence_with_replay_classifies_fire
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    dispatch_order = nil
    @bus.subscribe(:dispatch) do |delivery|
      dispatch_order = delivery.message
      delivery.ack!
    end

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-001",
        caller:      "Maria Santos",
        location:    "4th and Main Street",
        description: "Smoke pouring out of building",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.3
    end

    assert dispatch_order, "Should produce DispatchOrder from replayed LLM response"
    assert_equal "C-001", dispatch_order.call_id
    assert_equal "fire", dispatch_order.department
    assert_equal 2, dispatch_order.units_requested
  end

  def test_intelligence_with_replay_classifies_unknown
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    dispatch_order = nil
    @bus.subscribe(:dispatch) do |delivery|
      dispatch_order = delivery.message
      delivery.ack!
    end

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-008",
        caller:      "Derek Nguyen",
        location:    "Downtown",
        description: "Drones everywhere",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.3
    end

    assert dispatch_order, "Should produce DispatchOrder for drone call"
    assert_equal "C-008", dispatch_order.call_id
    assert_equal "unknown", dispatch_order.department
  end

  # ==========================================
  # Full pipeline: scenario → replay → operations
  # ==========================================

  def test_full_pipeline_dispatches_to_departments
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    fire   = FireDepartment.new
    police = PoliceDepartment.new
    ems    = EMS.new
    utils  = Utilities.new

    ops = Operations.new
    [fire, police, ems, utils].each { |d| ops.register(d) }
    ops.attach(@bus)

    field_reports = []
    @bus.subscribe(:field_reports) do |delivery|
      field_reports << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:department_status) { |d| d.ack! }
    @bus.subscribe(:display)           { |d| d.ack! }
    @bus.subscribe(:voice_out)         { |d| d.ack! }
    @bus.subscribe(:escalation)        { |d| d.ack! }

    calls = [
      { id: "C-001", caller: "Maria", loc: "4th and Main", desc: "Fire!", sev: :high },
      { id: "C-002", caller: "James", loc: "Oak and 12th", desc: "Robbery!", sev: :critical },
      { id: "C-003", caller: "Lisa",  loc: "200 Elm St",   desc: "Chest pains!", sev: :critical },
      { id: "C-004", caller: "Tom",   loc: "Industrial",   desc: "Water main!", sev: :medium },
    ]

    Async do
      calls.each do |c|
        @bus.publish(:calls, EmergencyCall.new(
          call_id: c[:id], caller: c[:caller], location: c[:loc],
          description: c[:desc], severity: c[:sev], timestamp: Time.now
        ))
        sleep 0.05
      end

      sleep 0.5
    end

    assert_equal 4, field_reports.size, "All 4 calls should produce field reports"

    depts = field_reports.map(&:department).sort
    assert_includes depts, "Fire"
    assert_includes depts, "Police"
    assert_includes depts, "EMS"
    assert_includes depts, "Utilities"
  end

  def test_full_pipeline_escalates_unknown_department
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    # No departments registered — unknown will escalate
    ops = Operations.new
    ops.attach(@bus)

    escalation = nil
    @bus.subscribe(:escalation) do |delivery|
      escalation = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display)   { |d| d.ack! }
    @bus.subscribe(:voice_out) { |d| d.ack! }

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-008",
        caller:      "Derek",
        location:    "Downtown",
        description: "Drones!",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.3
    end

    assert escalation, "Unknown department should trigger escalation"
    assert_equal "C-008", escalation.call_id
  end

  # ==========================================
  # Full demo scenario with scenario player
  # ==========================================

  def test_full_demo_scenario_with_player
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    fire    = FireDepartment.new
    police  = PoliceDepartment.new
    ems     = EMS.new
    utils   = Utilities.new
    council = CityCouncil.new

    ops = Operations.new
    [fire, police, ems, utils, council].each { |d| ops.register(d) }
    ops.attach(@bus)

    player = ScenarioPlayer.new(scenario_path: CALLS_PATH, skip_delays: true)
    player.attach(@bus)

    field_reports = []
    escalations  = []
    phases       = []

    @bus.subscribe(:field_reports) do |delivery|
      field_reports << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:escalation) do |delivery|
      escalations << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:department_status) { |d| d.ack! }
    @bus.subscribe(:display)           { |d| d.ack! }
    @bus.subscribe(:voice_out)         { |d| d.ack! }
    @bus.subscribe(:governance)        { |d| d.ack! }

    player.on_phase { |name| phases << name }

    Async do
      player.play
      sleep 1.0
    end

    assert_equal 9, player.calls_played, "All 9 calls should be played"
    assert_equal 4, phases.size, "Should have 4 phases"

    # Phase 1: Normal Operations — 4 calls dispatched
    # Phase 2: Stress — calls dispatched (fire C-005 needs 3 units, fire has 3 left)
    # Phase 3: Unknown — C-008 "drones" → no department handles it → escalation
    # Phase 4: Adaptation — C-009 "more drones" → escalation
    # (Without autonomy layer, both unknown calls escalate)

    total_handled = field_reports.size + escalations.size
    assert_equal 9, total_handled,
      "All 9 calls should be handled (#{field_reports.size} dispatched, #{escalations.size} escalated)"

    assert field_reports.size >= 7, "At least 7 calls should be dispatched"
    assert escalations.size >= 2, "At least 2 calls should escalate (C-008 and C-009, unknown department)"
  end

  # ==========================================
  # DisplayBridge captures full pipeline events
  # ==========================================

  def test_display_bridge_captures_pipeline_events
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    fire = FireDepartment.new
    ops  = Operations.new
    ops.register(fire)
    ops.attach(@bus)

    bridge = DisplayBridge.new
    bridge.attach(@bus)

    @bus.subscribe(:voice_out)         { |d| d.ack! }
    @bus.subscribe(:governance)        { |d| d.ack! }

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-001",
        caller:      "Maria",
        location:    "4th and Main",
        description: "Fire",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.5
    end

    events = bridge.events_since(0)
    types  = events.map { |e| e[:type] }

    assert_includes types, :incoming_call, "Should capture incoming call"
    assert_includes types, :dispatch, "Should capture dispatch event"
    assert_includes types, :field_report, "Should capture field report"
    assert_includes types, :dept_status, "Should capture department status"
    assert events.size >= 4, "Should capture at least 4 events for one call"
  end

  # ==========================================
  # Deterministic correlation IDs
  # ==========================================

  def test_intelligence_produces_deterministic_correlation_ids
    intel = Intelligence.new
    intel.attach(@bus)

    ids = []
    @bus.subscribe(:llm_requests) do |delivery|
      ids << delivery.message.correlation_id
      delivery.ack!
    end

    @bus.subscribe(:dispatch) { |d| d.ack! }

    Async do
      2.times do
        @bus.publish(:calls, EmergencyCall.new(
          call_id:     "C-DET",
          caller:      "Test",
          location:    "Here",
          description: "Test",
          severity:    :low,
          timestamp:   Time.now
        ))
      end

      sleep 0.1
    end

    assert_equal 2, ids.size
    assert_equal "intel-C-DET", ids[0]
    assert_equal "intel-C-DET", ids[1]
  end
end
