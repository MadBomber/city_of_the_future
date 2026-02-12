require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/departments"
require_relative "../lib/vsm/intelligence"
require_relative "../lib/vsm/operations"
require_relative "../lib/autonomy/governance"
require_relative "../lib/autonomy/self_agency_bridge"
require_relative "../lib/llm/replay_robot"
require_relative "../lib/llm/scenario_driver"

class AutonomyIntegrationTest < Minitest::Test
  SCENARIO_PATH = File.expand_path("../scenarios/demo.jsonl", __dir__)
  ROBOT_PATH    = File.expand_path("../scenarios/demo_robot.yml", __dir__)

  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Full autonomy pipeline: escalation → code gen → governance → install
  # ==========================================

  def test_full_autonomy_pipeline
    # Wire up all layers
    driver = ScenarioDriver.new(SCENARIO_PATH)
    driver.attach(@bus)

    intel = Intelligence.new
    intel.attach(@bus)

    council = CityCouncil.new
    ops = Operations.new
    ops.register(council)
    ops.attach(@bus)

    governance = Governance.new
    governance.attach(@bus)

    robot = ReplayRobot.new(ROBOT_PATH)
    agency = SelfAgencyBridge.new(robot: robot)
    agency.attach(@bus)

    # Register departments so multi-agency dispatch has targets
    fire   = FireDepartment.new
    police = PoliceDepartment.new
    ems    = EMS.new
    utils  = Utilities.new
    [fire, police, ems, utils].each { |d| ops.register(d) }

    # Collect events
    escalations    = []
    method_gens    = []
    governance_evts = []
    voice_outs     = []
    display_evts   = []
    field_reports  = []

    @bus.subscribe(:escalation) do |delivery|
      escalations << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:governance) do |delivery|
      governance_evts << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:voice_out) do |delivery|
      voice_outs << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display) do |delivery|
      display_evts << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:department_status) { |d| d.ack! }
    @bus.subscribe(:field_reports) do |delivery|
      field_reports << delivery.message
      delivery.ack!
    end

    # Send one drone call: no department handles "unknown" → immediate escalation
    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id: "C-008", caller: "Derek", location: "Downtown",
        description: "Drones everywhere", severity: :high, timestamp: Time.now
      ))

      sleep 2.0
    end

    # Verify escalation happened
    assert escalations.size >= 1, "Drone call should escalate"
    assert_equal "C-008", escalations[0].call_id

    # Verify governance approved new methods OR reused existing ones
    # (methods may already exist from a prior test in the same process)
    approved = governance_evts.select { |e| e.decision == :approved }
    reused = display_evts.select { |e| e.type == :capability_reused }
    total_handled = approved.size + reused.size
    assert total_handled >= 1, "Should approve or reuse at least 1 method (got #{approved.size} approved, #{reused.size} reused)"
    approved.each { |a| assert_equal "install_method", a.action }

    # Verify voice narration includes autonomy events
    voice_texts = voice_outs.map(&:text)

    capability_voice = voice_texts.find { |t| t.include?("Generating new capability") || t.include?("Reusing existing capability") }
    assert capability_voice, "SelfAgencyBridge should announce generation or reuse via voice"

    # If new methods were generated, governance should announce approval
    if approved.any?
      approved_voice = voice_texts.find { |t| t.include?("Governance approved") }
      assert approved_voice, "Governance should announce approval via voice"
      assert_match(/installed/, approved_voice)
    end

    # Verify adaptation retry
    retry_voice = voice_texts.find { |t| t.include?("handled using new capability") }
    assert retry_voice, "SelfAgencyBridge should announce retry success via voice"
    assert_match(/C-008/, retry_voice)

    # Verify display events include the full pipeline
    display_types = display_evts.map(&:type)
    assert_includes display_types, :escalation_analysis, "Should show escalation analysis"
    assert_includes display_types, :method_installed, "Should show method installed"
    assert_includes display_types, :adaptation_success, "Should show adaptation success"

    # Verify multi-agency dispatch
    assert field_reports.size >= 4,
      "Multi-agency dispatch should deploy units from Fire, Police, EMS, Utilities (got #{field_reports.size})"
    dispatched_depts = field_reports.map(&:department).sort
    assert_includes dispatched_depts, "Fire", "Fire should be dispatched"
    assert_includes dispatched_depts, "Police", "Police should be dispatched"
    assert_includes dispatched_depts, "EMS", "EMS should be dispatched"
    assert_includes dispatched_depts, "Utilities", "Utilities should be dispatched"
  end

  # ==========================================
  # Governance rejection with voice
  # ==========================================

  def test_governance_rejection_narrates_via_voice
    governance = Governance.new
    governance.attach(@bus)

    voice_outs = []
    @bus.subscribe(:voice_out) do |delivery|
      voice_outs << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:governance) { |d| d.ack! }
    @bus.subscribe(:display)   { |d| d.ack! }

    Async do
      # Publish a dangerous method — should be rejected
      @bus.publish(:method_gen, MethodGen.new(
        target_class: "CityCouncil",
        method_name:  "dangerous_method",
        source_code:  "def dangerous_method\n  system('rm -rf /')\nend",
        status:       :pending
      ))

      sleep 0.1
    end

    rejected_voice = voice_outs.find { |v| v.text.include?("rejected") }
    assert rejected_voice, "Governance should announce rejection via voice"
    assert_match(/dangerous_method/, rejected_voice.text)
  end

  # ==========================================
  # SelfAgencyBridge announces code generation
  # ==========================================

  def test_self_agency_announces_generation_via_voice
    robot = ReplayRobot.new(ROBOT_PATH)
    agency = SelfAgencyBridge.new(robot: robot)
    agency.attach(@bus)

    voice_outs  = []
    method_gens = []

    @bus.subscribe(:voice_out) do |delivery|
      voice_outs << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:method_gen) do |delivery|
      method_gens << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display) { |d| d.ack! }

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-TEST",
        reason:                "No department available for 'unknown'",
        original_call:         "unknown",
        attempted_departments: [],
        timestamp:             Time.now
      ))

      sleep 0.8
    end

    # Voice should announce generation or reuse
    capability_voice = voice_outs.find { |v|
      v.text.include?("Generating new capability") || v.text.include?("Reusing existing capability")
    }
    assert capability_voice, "Should announce code generation or reuse via voice"
    assert_equal "System", capability_voice.department

    # Coordinator method should be generated or reused
    if method_gens.any?
      assert_equal "CityCouncil", method_gens[0].target_class
    else
      # Method already existed — verify it was reused via voice
      reuse_voice = voice_outs.find { |v| v.text.include?("Reusing existing capability") }
      assert reuse_voice, "Should announce reuse when method already exists"
    end
  end

  # ==========================================
  # Method installation actually works
  # ==========================================

  def test_installed_method_is_callable
    governance = Governance.new
    governance.attach(@bus)

    robot = ReplayRobot.new(ROBOT_PATH)
    agency = SelfAgencyBridge.new(robot: robot)
    agency.attach(@bus)

    @bus.subscribe(:governance) { |d| d.ack! }
    @bus.subscribe(:display)    { |d| d.ack! }
    @bus.subscribe(:voice_out)  { |d| d.ack! }

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-INSTALL",
        reason:                "No department available for 'unknown'",
        original_call:         "unknown",
        attempted_departments: [],
        timestamp:             Time.now
      ))

      sleep 1.0
    end

    # With "unknown" original_call and no scenario keywords, ReplayRobot matches
    # the generic "No department available" pattern → coordinate_emergency_response
    council = CityCouncil.new

    assert council.respond_to?(:coordinate_emergency_response),
      "CityCouncil should now have coordinate_emergency_response installed"

    result = council.coordinate_emergency_response
    assert_kind_of Hash, result, "Installed method should return a Hash"
    assert_equal :coordinated, result[:status]
    assert result[:departments], "Response should include multi-department plan"
    assert_equal 4, result[:departments].size, "Should plan dispatch for 4 departments"
  end
end
