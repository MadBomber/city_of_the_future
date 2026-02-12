require "bundler/setup"
require "minitest/autorun"
require "async"
require "tmpdir"
require "yaml"

require_relative "../lib/bus_setup"
require_relative "../lib/departments"
require_relative "../lib/vsm/intelligence"
require_relative "../lib/vsm/operations"
require_relative "../lib/scenario/player"

class ScenarioPlayerTest < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Scenario loading tests
  # ==========================================

  def test_loads_demo_scenario
    player = ScenarioPlayer.new(
      scenario_path: File.expand_path("../scenarios/demo_calls.yml", __dir__),
      skip_delays: true
    )

    assert_equal 0, player.calls_played
  end

  def test_loads_custom_scenario
    scenario = {
      "phases" => [
        {
          "name" => "Test Phase",
          "delay_before" => 0,
          "calls" => [
            {
              "call_id"     => "T-1",
              "caller"      => "Test Caller",
              "location"    => "Test Location",
              "description" => "Test emergency",
              "severity"    => "high",
              "delay"       => 0
            }
          ]
        }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "test_scenario.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      calls = []
      @bus.subscribe(:calls) do |delivery|
        calls << delivery.message
        delivery.ack!
      end

      @bus.subscribe(:display)   { |d| d.ack! }
      @bus.subscribe(:voice_out) { |d| d.ack! }

      Async do
        player.play
        sleep 0.05
      end

      assert_equal 1, player.calls_played
      assert_equal 1, calls.size
      assert_equal "T-1", calls.first.call_id
      assert_equal "Test Caller", calls.first.caller
    end
  end

  # ==========================================
  # build_call tests
  # ==========================================

  def test_build_call_returns_emergency_call
    player = ScenarioPlayer.new(
      scenario_path: File.expand_path("../scenarios/demo_calls.yml", __dir__),
      skip_delays: true
    )

    call = player.build_call(
      "call_id"     => "C-100",
      "caller"      => "Jane Doe",
      "location"    => "123 Test St",
      "description" => "Fire in the kitchen",
      "severity"    => "critical"
    )

    assert_instance_of EmergencyCall, call
    assert_equal "C-100", call.call_id
    assert_equal "Jane Doe", call.caller
    assert_equal :critical, call.severity
  end

  # ==========================================
  # Phase callback tests
  # ==========================================

  def test_phase_callback_called_for_each_phase
    scenario = {
      "phases" => [
        { "name" => "Phase A", "delay_before" => 0, "calls" => [] },
        { "name" => "Phase B", "delay_before" => 0, "calls" => [] }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "phases.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      @bus.subscribe(:display)   { |d| d.ack! }
      @bus.subscribe(:voice_out) { |d| d.ack! }

      phases_seen = []
      player.on_phase { |name| phases_seen << name }

      Async do
        player.play
        sleep 0.05
      end

      assert_equal ["Phase A", "Phase B"], phases_seen
    end
  end

  # ==========================================
  # Bus integration tests
  # ==========================================

  def test_publishes_calls_to_bus
    scenario = {
      "phases" => [
        {
          "name" => "Test",
          "delay_before" => 0,
          "calls" => [
            { "call_id" => "B-1", "caller" => "Alice", "location" => "A St",
              "description" => "Fire!", "severity" => "high", "delay" => 0 },
            { "call_id" => "B-2", "caller" => "Bob", "location" => "B St",
              "description" => "Robbery!", "severity" => "critical", "delay" => 0 }
          ]
        }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "bus_test.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      calls = []
      @bus.subscribe(:calls) do |delivery|
        calls << delivery.message
        delivery.ack!
      end

      @bus.subscribe(:display)   { |d| d.ack! }
      @bus.subscribe(:voice_out) { |d| d.ack! }

      Async do
        player.play
        sleep 0.05
      end

      assert_equal 2, calls.size
      assert_equal "B-1", calls[0].call_id
      assert_equal "B-2", calls[1].call_id
      assert_equal 2, player.calls_played
    end
  end

  def test_publishes_phase_change_display_events
    scenario = {
      "phases" => [
        { "name" => "Alpha", "delay_before" => 0, "calls" => [] },
        { "name" => "Beta", "delay_before" => 0, "calls" => [] }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "display_test.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      display_events = []
      @bus.subscribe(:display) do |delivery|
        display_events << delivery.message
        delivery.ack!
      end

      @bus.subscribe(:voice_out) { |d| d.ack! }

      Async do
        player.play
        sleep 0.05
      end

      phase_events = display_events.select { |e| e.type == :phase_change }
      assert_equal 2, phase_events.size
      assert_equal "Alpha", phase_events[0].data[:phase]
      assert_equal "Beta", phase_events[1].data[:phase]
    end
  end

  def test_no_voice_out_for_phase_announcements
    scenario = {
      "phases" => [
        { "name" => "Opening", "delay_before" => 0, "calls" => [] }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "voice_test.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      voice_events = []
      @bus.subscribe(:voice_out) do |delivery|
        voice_events << delivery.message
        delivery.ack!
      end

      @bus.subscribe(:display) { |d| d.ack! }

      Async do
        player.play
        sleep 0.05
      end

      assert_empty voice_events, "Phase changes should not produce voice events"
    end
  end

  # ==========================================
  # Caller voice narration
  # ==========================================

  def test_publishes_caller_voice_before_each_call
    scenario = {
      "phases" => [
        {
          "name" => "Test",
          "delay_before" => 0,
          "calls" => [
            { "call_id" => "V-1", "caller" => "Alice", "location" => "A St",
              "description" => "Fire in the kitchen!", "severity" => "high", "delay" => 0 },
            { "call_id" => "V-2", "caller" => "Bob", "location" => "B St",
              "description" => "Someone broke in!", "severity" => "critical", "delay" => 0 }
          ]
        }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "voice_caller.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      voice_events = []
      @bus.subscribe(:voice_out) do |delivery|
        voice_events << delivery.message
        delivery.ack!
      end

      calls = []
      @bus.subscribe(:calls) do |delivery|
        calls << delivery.message
        delivery.ack!
      end

      @bus.subscribe(:display) { |d| d.ack! }

      Async do
        player.play
        sleep 0.05
      end

      caller_voices = voice_events.select { |v| v.department == "Caller" }
      assert_equal 2, caller_voices.size, "Should publish one caller voice per call"

      assert_equal "Fire in the kitchen!", caller_voices[0].text
      assert_equal "Someone broke in!", caller_voices[1].text

      # Each caller gets a distinct voice from the rotation
      assert_equal "Rishi", caller_voices[0].voice
      assert_equal "Tessa", caller_voices[1].voice
      refute_equal caller_voices[0].voice, caller_voices[1].voice

      # No caller should use Samantha (dispatch voice)
      caller_voices.each do |v|
        refute_equal "Samantha", v.voice, "Caller voice must not be the dispatch voice"
      end

      assert_equal 2, calls.size, "Calls should still be published"
    end
  end

  # ==========================================
  # End-to-end: scenario → intelligence → operations
  # ==========================================

  def test_end_to_end_scenario_to_field_report
    scenario = {
      "phases" => [
        {
          "name" => "E2E Test",
          "delay_before" => 0,
          "calls" => [
            { "call_id" => "E2E-1", "caller" => "Tester", "location" => "Test Ave",
              "description" => "Building on fire", "severity" => "high", "delay" => 0 }
          ]
        }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "e2e.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      intel = Intelligence.new
      intel.attach(@bus)

      fire = FireDepartment.new
      ops  = Operations.new
      ops.register(fire)
      ops.attach(@bus)

      # Fake LLM subscriber
      @bus.subscribe(:llm_requests) do |delivery|
        req = delivery.message
        @bus.publish(:llm_responses, LLMResponse.new(
          content:        '{"department":"fire","priority":1,"units_requested":1,"eta":"4min"}',
          tool_calls:     nil,
          tokens:         42,
          correlation_id: req.correlation_id
        ))
        delivery.ack!
      end

      field_report = nil
      @bus.subscribe(:field_reports) do |delivery|
        field_report = delivery.message
        delivery.ack!
      end

      @bus.subscribe(:department_status) { |d| d.ack! }
      @bus.subscribe(:display)           { |d| d.ack! }
      @bus.subscribe(:voice_out)         { |d| d.ack! }

      Async do
        player.play
        sleep 0.15
      end

      assert field_report, "Should produce a FieldReport from scenario → intel → ops"
      assert_equal "E2E-1", field_report.call_id
      assert_equal "Fire", field_report.department
      assert_equal :dispatched, field_report.status
    end
  end

  def test_end_to_end_scenario_escalation
    scenario = {
      "phases" => [
        {
          "name" => "Unknown Threat",
          "delay_before" => 0,
          "calls" => [
            { "call_id" => "ESC-1", "caller" => "Witness", "location" => "Downtown",
              "description" => "Drones everywhere!", "severity" => "high", "delay" => 0 }
          ]
        }
      ]
    }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "escalation.yml")
      File.write(path, YAML.dump(scenario))

      player = ScenarioPlayer.new(scenario_path: path, skip_delays: true)
      player.attach(@bus)

      intel = Intelligence.new
      intel.attach(@bus)

      ops = Operations.new
      ops.attach(@bus)

      # Fake LLM — returns "unknown" department
      @bus.subscribe(:llm_requests) do |delivery|
        req = delivery.message
        @bus.publish(:llm_responses, LLMResponse.new(
          content:        '{"department":"unknown","priority":3,"units_requested":1,"eta":"unknown"}',
          tool_calls:     nil,
          tokens:         30,
          correlation_id: req.correlation_id
        ))
        delivery.ack!
      end

      escalation = nil
      @bus.subscribe(:escalation) do |delivery|
        escalation = delivery.message
        delivery.ack!
      end

      @bus.subscribe(:display)   { |d| d.ack! }
      @bus.subscribe(:voice_out) { |d| d.ack! }

      Async do
        player.play
        sleep 0.15
      end

      assert escalation, "Should escalate when LLM classifies as unknown"
      assert_equal "ESC-1", escalation.call_id
    end
  end

  # ==========================================
  # Demo scenario file validation
  # ==========================================

  def test_demo_scenario_has_four_phases
    scenario = YAML.load_file(
      File.expand_path("../scenarios/demo_calls.yml", __dir__),
      permitted_classes: [Symbol]
    )

    phases = scenario["phases"]
    assert_equal 4, phases.size
    assert_equal "Normal Operations", phases[0]["name"]
    assert_equal "Stress", phases[1]["name"]
    assert_equal "The Unknown", phases[2]["name"]
    assert_equal "Adaptation", phases[3]["name"]
  end

  def test_demo_scenario_has_nine_calls
    scenario = YAML.load_file(
      File.expand_path("../scenarios/demo_calls.yml", __dir__),
      permitted_classes: [Symbol]
    )

    total_calls = scenario["phases"].sum { |p| p["calls"].size }
    assert_equal 9, total_calls
  end

  def test_demo_scenario_calls_have_required_fields
    scenario = YAML.load_file(
      File.expand_path("../scenarios/demo_calls.yml", __dir__),
      permitted_classes: [Symbol]
    )

    required = %w[call_id caller location description severity]

    scenario["phases"].each do |phase|
      phase["calls"].each do |call|
        required.each do |field|
          assert call.key?(field), "Call #{call['call_id']} missing '#{field}' in phase '#{phase['name']}'"
        end
      end
    end
  end
end
