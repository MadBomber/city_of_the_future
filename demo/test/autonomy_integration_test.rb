require "bundler/setup"
require "minitest/autorun"
require "async"
require "self_agency"

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
    configure_self_agency
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Full autonomy pipeline: escalation → self_agency _() → install
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
    wire_departments(robot, @bus)

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
    # on_method_generated publishes governance events for self_agency path
    approved = governance_evts.select { |e| e.decision == :approved }
    reused = display_evts.select { |e| e.type == :capability_reused }
    total_handled = approved.size + reused.size
    assert total_handled >= 1, "Should approve or reuse at least 1 method (got #{approved.size} approved, #{reused.size} reused)"
    approved.each { |a| assert_equal "install_method", a.action }

    # Verify voice narration includes autonomy events
    voice_texts = voice_outs.map(&:text)

    capability_voice = voice_texts.find { |t|
      t.include?("is learning a new capability") ||
      t.include?("Reusing existing capability")
    }
    assert capability_voice, "SelfAgencyBridge should announce learning or reuse via voice"

    # If new methods were generated, on_method_generated should announce
    if approved.any?
      learned_voice = voice_texts.find { |t| t.include?("has learned:") }
      assert learned_voice, "on_method_generated should announce learned method via voice"
    end

    # Verify adaptation retry
    retry_voice = voice_texts.find { |t| t.include?("handled using new capability") }
    assert retry_voice, "SelfAgencyBridge should announce retry success via voice"
    assert_match(/C-008/, retry_voice)

    # Verify display events include the full pipeline
    display_types = display_evts.map(&:type)
    assert(display_types.include?(:escalation_analysis) || display_types.include?(:capability_reused),
      "Should show escalation analysis or capability reuse")
    assert(display_types.include?(:method_installed) || display_types.include?(:capability_reused),
      "Should show method installed or capability reused")
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
  # Governance rejection with voice (ChaosBridge path — unchanged)
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
  # SelfAgencyBridge announces learning via voice
  # ==========================================

  def test_self_agency_announces_learning_via_voice
    robot = ReplayRobot.new(ROBOT_PATH)
    wire_departments(robot, @bus)

    agency = SelfAgencyBridge.new(robot: robot)
    agency.attach(@bus)

    voice_outs  = []
    display_evts = []

    @bus.subscribe(:voice_out) do |delivery|
      voice_outs << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:governance) { |d| d.ack! }
    @bus.subscribe(:display) do |delivery|
      display_evts << delivery.message
      delivery.ack!
    end

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

    # Voice should announce learning or reuse
    capability_voice = voice_outs.find { |v|
      v.text.include?("is learning a new capability") ||
      v.text.include?("Reusing existing capability")
    }
    assert capability_voice, "Should announce learning or reuse via voice"
    assert_equal "System", capability_voice.department

    # If new capability was learned, verify method_installed display event
    installed = display_evts.find { |e| e.type == :method_installed }
    if installed
      assert_equal "CityCouncil", installed.data[:class]
      assert installed.data[:source], "method_installed should include source"
    end
  end

  # ==========================================
  # Method installation via self_agency actually works
  # ==========================================

  def test_installed_method_is_callable
    robot = ReplayRobot.new(ROBOT_PATH)
    wire_departments(robot, @bus)

    agency = SelfAgencyBridge.new(robot: robot)
    agency.attach(@bus)

    display_evts = []
    @bus.subscribe(:governance) { |d| d.ack! }
    @bus.subscribe(:display) do |delivery|
      display_evts << delivery.message
      delivery.ack!
    end
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

    council = CityCouncil.new

    # Find whichever coordinator method was installed or reused
    coordinator = CityCouncil.instance_methods(false).find { |m| m.to_s.start_with?("coordinate_") }
    # Also check prepended modules (self_agency installs via module_eval on a prepended module)
    coordinator ||= council.methods.find { |m| m.to_s.start_with?("coordinate_") }

    assert coordinator,
      "CityCouncil should have a coordinate_* method installed"

    result = council.public_send(coordinator)
    assert_kind_of Hash, result, "Installed method should return a Hash"
    assert result[:status], "Result should include :status"

    # Verify the bridge handled the escalation (learned or reused)
    display_types = display_evts.map(&:type)
    assert(display_types.include?(:adaptation_success) || display_types.include?(:capability_reused),
      "Should show adaptation success or capability reuse")

    # Verify _source_for works (self_agency introspection)
    source = CityCouncil._source_for(coordinator)
    if source
      assert_match(/def /, source)
    end
  end

  private

  def configure_self_agency
    SelfAgency.configure do |config|
      config.provider = :ollama
      config.model    = "replay"
      config.api_base = "http://localhost:0"
      config.logger   = nil
    end
  end

  def wire_departments(robot, bus)
    [CityCouncil, FireDepartment, PoliceDepartment, EMS, Utilities].each do |klass|
      klass.code_robot = robot
      klass.event_bus  = bus
    end
  end
end
