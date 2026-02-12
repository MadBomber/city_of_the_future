require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/autonomy/code_extractor"
require_relative "../lib/autonomy/governance"
require_relative "../lib/autonomy/chaos_bridge"
require_relative "../lib/autonomy/self_agency_bridge"

class Layer4Test < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # --- Fake robot helper ---

  def build_fake_robot(response_text)
    fake_result = Object.new
    fake_result.define_singleton_method(:last_text_content) { response_text }

    fake_robot = Object.new
    fake_robot.define_singleton_method(:run) { |**_kwargs| fake_result }
    fake_robot
  end

  # ==========================================
  # CodeExtractor tests
  # ==========================================

  def test_extract_ruby_fenced
    content = <<~TEXT
      Here's the method:
      ```ruby
      def handle_fire
        { status: "responding" }
      end
      ```
      That should work.
    TEXT

    source = CodeExtractor.extract(content)
    assert_match(/def handle_fire/, source)
    assert_match(/end\z/, source)
  end

  def test_extract_plain_fenced
    content = <<~TEXT
      ```
      def handle_flood
        { status: "sandbagging" }
      end
      ```
    TEXT

    source = CodeExtractor.extract(content)
    assert_match(/def handle_flood/, source)
  end

  def test_extract_bare_def_end
    content = <<~TEXT
      You should use this method:
      def handle_quake
        { status: "sheltering" }
      end
      Hope that helps!
    TEXT

    source = CodeExtractor.extract(content)
    assert_match(/def handle_quake/, source)
  end

  def test_extract_nil_input
    assert_nil CodeExtractor.extract(nil)
  end

  def test_extract_empty_input
    assert_nil CodeExtractor.extract("")
    assert_nil CodeExtractor.extract("   ")
  end

  def test_extract_no_method
    assert_nil CodeExtractor.extract("Just some text with no code")
  end

  # ==========================================
  # Governance evaluate tests
  # ==========================================

  def test_evaluate_approves_valid_method
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "FireDepartment",
      method_name:  "handle_fire",
      source_code:  "def handle_fire\n  { status: \"responding\" }\nend",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :approved, decision
    assert_match(/Passed/, reason)
  end

  def test_evaluate_rejects_unlisted_class
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "HackerBot",
      method_name:  "pwn",
      source_code:  "def pwn\n  :hacked\nend",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :rejected, decision
    assert_match(/not on allowlist/, reason)
  end

  def test_evaluate_rejects_dangerous_system
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "FireDepartment",
      method_name:  "bad_method",
      source_code:  "def bad_method\n  system('rm -rf /')\nend",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :rejected, decision
    assert_match(/Dangerous pattern/, reason)
  end

  def test_evaluate_rejects_dangerous_eval
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "FireDepartment",
      method_name:  "bad_method",
      source_code:  "def bad_method\n  eval('puts 1')\nend",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :rejected, decision
  end

  def test_evaluate_rejects_dangerous_file_access
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "FireDepartment",
      method_name:  "bad_method",
      source_code:  "def bad_method\n  File.read('/etc/passwd')\nend",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :rejected, decision
  end

  def test_evaluate_rejects_missing_def
    gov = Governance.new(allowlist: ["FireDepartment"])
    gen = MethodGen.new(
      target_class: "FireDepartment",
      method_name:  "not_a_method",
      source_code:  "puts 'hello'",
      status:       :pending
    )

    decision, reason = gov.evaluate(gen)
    assert_equal :rejected, decision
    assert_match(/No method definition/, reason)
  end

  # ==========================================
  # Governance bus integration tests
  # ==========================================

  def test_governance_installs_approved_method
    # Create a test target class
    test_class = Class.new
    Object.const_set(:GovTestTarget, test_class) unless defined?(GovTestTarget)

    gov = Governance.new(allowlist: ["GovTestTarget"])
    gov.attach(@bus)

    installed = false
    @bus.subscribe(:display) do |delivery|
      installed = true if delivery.message.type == :method_installed
      delivery.ack!
    end

    Async do
      @bus.publish(:method_gen, MethodGen.new(
        target_class: "GovTestTarget",
        method_name:  "gov_test_method",
        source_code:  "def gov_test_method\n  { status: \"ok\" }\nend",
        status:       :pending
      ))

      sleep 0.05
    end

    assert installed, "Should have published :method_installed display event"
    assert GovTestTarget.instance_method(:gov_test_method),
           "Method should be installed on target class"
  ensure
    Object.send(:remove_const, :GovTestTarget) if defined?(GovTestTarget)
  end

  def test_governance_nacks_rejected_method
    gov = Governance.new(allowlist: ["AllowedClass"])
    gov.attach(@bus)

    rejected = false
    @bus.subscribe(:display) do |delivery|
      rejected = true if delivery.message.type == :method_rejected
      delivery.ack!
    end

    Async do
      @bus.publish(:method_gen, MethodGen.new(
        target_class: "NotAllowed",
        method_name:  "bad",
        source_code:  "def bad\n  :nope\nend",
        status:       :pending
      ))

      sleep 0.05
    end

    assert rejected, "Should have published :method_rejected display event"

    dlq = @bus.dead_letters(:method_gen)
    refute dlq.empty?, "Rejected method should be in DLQ"
  end

  # ==========================================
  # ChaosBridge tests
  # ==========================================

  def test_chaos_bridge_publishes_display_event_on_method_missing
    robot = build_fake_robot("def test_chaos\n  { ok: true }\nend")
    chaos = ChaosBridge.new(robot: robot)
    chaos.attach(@bus)

    test_class = Class.new
    Object.const_set(:ChaosTestTarget, test_class) unless defined?(ChaosTestTarget)
    chaos.watch(ChaosTestTarget)

    display_events = []
    @bus.subscribe(:display) do |delivery|
      display_events << delivery.message
      delivery.ack!
    end

    Async do
      begin
        ChaosTestTarget.new.nonexistent_method
      rescue NoMethodError
        # expected — method_missing calls super
      end

      sleep 0.1
    end

    missing_event = display_events.find { |e| e.type == :method_missing }
    assert missing_event, "Should publish :method_missing display event"
    assert_equal "ChaosTestTarget", missing_event.data[:class]
  ensure
    Object.send(:remove_const, :ChaosTestTarget) if defined?(ChaosTestTarget)
  end

  def test_chaos_bridge_generates_and_publishes_method_gen
    source = "def generated_method\n  { status: \"generated\" }\nend"
    robot = build_fake_robot("```ruby\n#{source}\n```")
    chaos = ChaosBridge.new(robot: robot)
    chaos.attach(@bus)

    test_class = Class.new
    Object.const_set(:ChaosGenTarget, test_class) unless defined?(ChaosGenTarget)
    chaos.watch(ChaosGenTarget)

    gen_received = nil
    @bus.subscribe(:method_gen) do |delivery|
      gen_received = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display) do |delivery|
      delivery.ack!
    end

    Async do
      begin
        ChaosGenTarget.new.generated_method
      rescue NoMethodError
        # expected
      end

      sleep 0.1
    end

    assert gen_received, "Should publish MethodGen to :method_gen channel"
    assert_equal "ChaosGenTarget", gen_received.target_class
    assert_equal "generated_method", gen_received.method_name
  ensure
    Object.send(:remove_const, :ChaosGenTarget) if defined?(ChaosGenTarget)
  end

  # ==========================================
  # SelfAgencyBridge tests
  # ==========================================

  def test_method_name_for
    assert_equal "coordinate_no_department_available",
                 SelfAgencyBridge.method_name_for("No department available")

    assert_equal "coordinate_drone_swarm_downtown",
                 SelfAgencyBridge.method_name_for("Drone swarm downtown!")
  end

  def test_self_agency_reacts_to_escalation
    source = "def coordinate_alien_invasion\n  { plan: \"call NASA\" }\nend"
    robot = build_fake_robot("```ruby\n#{source}\n```")

    agency = SelfAgencyBridge.new(robot: robot, target_class: "CityCouncil")
    agency.attach(@bus)

    gen_received = nil
    @bus.subscribe(:method_gen) do |delivery|
      gen_received = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display) do |delivery|
      delivery.ack!
    end

    @bus.subscribe(:governance) do |delivery|
      delivery.ack!
    end

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-999",
        reason:                "Alien invasion",
        original_call:         "UFO landing in park",
        attempted_departments: [:police, :fire],
        timestamp:             Time.now
      ))

      sleep 0.05
    end

    assert gen_received, "Should publish MethodGen after escalation"
    assert_equal "CityCouncil", gen_received.target_class
    assert_equal "coordinate_alien_invasion", gen_received.method_name
  end

  def test_self_agency_publishes_failure_on_bad_extraction
    robot = build_fake_robot("I don't know how to write that")
    agency = SelfAgencyBridge.new(robot: robot, target_class: "CityCouncil")
    agency.attach(@bus)

    display_events = []
    @bus.subscribe(:display) do |delivery|
      display_events << delivery.message
      delivery.ack!
    end

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-998",
        reason:                "Unknown threat",
        original_call:         "Something weird",
        attempted_departments: [:police],
        timestamp:             Time.now
      ))

      sleep 0.05
    end

    failure = display_events.find { |e| e.type == :method_gen_failed }
    assert failure, "Should publish :method_gen_failed on extraction failure"
  end

  # ==========================================
  # End-to-end: chaos → governance → installed
  # ==========================================

  def test_end_to_end_chaos_to_governance_install
    source = "def e2e_chaos_method\n  { status: \"working\" }\nend"
    robot = build_fake_robot("```ruby\n#{source}\n```")

    test_class = Class.new
    Object.const_set(:E2EChaosTarget, test_class) unless defined?(E2EChaosTarget)

    gov = Governance.new(allowlist: ["E2EChaosTarget"])
    gov.attach(@bus)

    chaos = ChaosBridge.new(robot: robot)
    chaos.attach(@bus)
    chaos.watch(E2EChaosTarget)

    installed = false
    @bus.subscribe(:display) do |delivery|
      installed = true if delivery.message.type == :method_installed
      delivery.ack!
    end

    @bus.subscribe(:governance) do |delivery|
      delivery.ack!
    end

    Async do
      begin
        E2EChaosTarget.new.e2e_chaos_method
      rescue NoMethodError
        # expected initially
      end

      sleep 0.2
    end

    assert installed, "Method should be installed after chaos → governance flow"
    result = E2EChaosTarget.new.e2e_chaos_method
    assert_equal({ status: "working" }, result)
  ensure
    Object.send(:remove_const, :E2EChaosTarget) if defined?(E2EChaosTarget)
  end

  # ==========================================
  # End-to-end: escalation → agency → governance → installed
  # ==========================================

  def test_end_to_end_escalation_to_governance_install
    source = "def coordinate_meteor_strike\n  { plan: \"evacuate\" }\nend"
    robot = build_fake_robot("```ruby\n#{source}\n```")

    test_class = Class.new
    Object.const_set(:CityCouncil, test_class) unless defined?(CityCouncil)

    gov = Governance.new(allowlist: ["CityCouncil"])
    gov.attach(@bus)

    agency = SelfAgencyBridge.new(robot: robot, target_class: "CityCouncil")
    agency.attach(@bus)

    installed = false
    @bus.subscribe(:display) do |delivery|
      installed = true if delivery.message.type == :method_installed
      delivery.ack!
    end

    @bus.subscribe(:governance) do |delivery|
      delivery.ack!
    end

    Async do
      @bus.publish(:escalation, Escalation.new(
        call_id:               "C-E2E",
        reason:                "Meteor strike",
        original_call:         "Huge meteor approaching",
        attempted_departments: [:fire, :police, :ems],
        timestamp:             Time.now
      ))

      sleep 0.1
    end

    assert installed, "Method should be installed after escalation → agency → governance flow"
    result = CityCouncil.new.coordinate_meteor_strike
    assert_equal({ plan: "evacuate" }, result)
  ensure
    Object.send(:remove_const, :CityCouncil) if defined?(CityCouncil)
  end
end
