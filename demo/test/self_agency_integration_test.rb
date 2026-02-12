require "bundler/setup"
require "minitest/autorun"
require "async"
require "self_agency"

require_relative "../lib/bus_setup"
require_relative "../lib/departments"
require_relative "../lib/autonomy/self_agency_bridge"
require_relative "../lib/llm/replay_robot"

class SelfAgencyIntegrationTest < Minitest::Test
  ROBOT_PATH = File.expand_path("../scenarios/demo_robot.yml", __dir__)

  def setup
    @bus   = BusSetup.create_bus
    @robot = ReplayRobot.new(ROBOT_PATH)

    SelfAgency.configure do |config|
      config.provider = :ollama
      config.model    = "replay"
      config.api_base = "http://localhost:0"
      config.logger   = nil
    end

    wire_departments(@robot, @bus)
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # CityCouncil includes SelfAgency
  # ==========================================

  def test_city_council_includes_self_agency
    assert CityCouncil.ancestors.include?(SelfAgency),
      "CityCouncil should include SelfAgency"
    assert CityCouncil.ancestors.include?(SelfAgencyReplay),
      "CityCouncil should include SelfAgencyReplay"
    assert CityCouncil.ancestors.include?(SelfAgencyLearner),
      "CityCouncil should include SelfAgencyLearner"
  end

  # ==========================================
  # _() generates and installs method via ReplayRobot
  # ==========================================

  def test_underscore_generates_and_installs_method
    council = CityCouncil.new
    description = <<~DESC
      Generate a Ruby method for class `CityCouncil`.
      An emergency escalation occurred with drones everywhere.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    DESC

    method_names = council._(description)
    assert method_names.is_a?(Array), "_() should return an Array"
    assert method_names.size >= 1, "Should install at least 1 method"

    actual_name = method_names.first
    assert council.respond_to?(actual_name),
      "Installed method should be callable on the instance"

    result = council.public_send(actual_name)
    assert_kind_of Hash, result, "Method should return a Hash"
    assert result[:status], "Result should include :status"
  end

  # ==========================================
  # _source_for returns the generated code
  # ==========================================

  def test_source_for_returns_generated_code
    council = CityCouncil.new
    description = <<~DESC
      Generate a Ruby method for class `CityCouncil`.
      No department available for 'unknown'. Coordinate emergency response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    DESC

    method_names = council._(description)
    actual_name = method_names.first

    source = CityCouncil._source_for(actual_name)
    assert source, "_source_for should return source code"
    assert_match(/def /, source)
    assert_match(/end/, source)
  end

  # ==========================================
  # _source_versions_for returns version history
  # ==========================================

  def test_source_versions_for_returns_history
    council = CityCouncil.new
    description = <<~DESC
      Generate a Ruby method for class `CityCouncil`.
      No department available for 'unknown'. Coordinate emergency response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    DESC

    method_names = council._(description)
    actual_name = method_names.first

    versions = CityCouncil._source_versions_for(actual_name)
    assert versions.is_a?(Array), "_source_versions_for should return an Array"
    assert versions.size >= 1, "Should have at least 1 version"

    version = versions.last
    assert version[:code], "Version should include :code"
    assert version[:description], "Version should include :description"
    assert version[:at], "Version should include :at"
  end

  # ==========================================
  # on_method_generated fires and publishes bus events
  # ==========================================

  def test_on_method_generated_publishes_bus_events
    governance_evts = []
    display_evts    = []
    voice_outs      = []

    @bus.subscribe(:governance) do |delivery|
      governance_evts << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display) do |delivery|
      display_evts << delivery.message
      delivery.ack!
    end

    @bus.subscribe(:voice_out) do |delivery|
      voice_outs << delivery.message
      delivery.ack!
    end

    Async do
      council = CityCouncil.new
      description = <<~DESC
        Generate a Ruby method for class `CityCouncil`.
        No department available for 'unknown'. Coordinate emergency response.
        Return ONLY a def...end block. No class wrapper.
        Return a Hash with a response plan.
        Do NOT use system, exec, eval, File, IO, or shell commands.
      DESC

      council._(description)
      sleep 0.1
    end

    # Governance event from on_method_generated
    approved = governance_evts.select { |e| e.decision == :approved }
    assert approved.size >= 1, "on_method_generated should publish governance approval"
    assert_equal "install_method", approved.first.action

    # Display event: method_installed
    installed = display_evts.select { |e| e.type == :method_installed }
    assert installed.size >= 1, "on_method_generated should publish method_installed display event"
    assert_equal "CityCouncil", installed.first.data[:class]

    # Voice event: learned
    learned_voice = voice_outs.find { |v| v.text.include?("has learned:") }
    assert learned_voice, "on_method_generated should announce via voice"
    assert_match(/CityCouncil/, learned_voice.text)
  end

  # ==========================================
  # SecurityError for dangerous code
  # ==========================================

  def test_security_error_for_dangerous_code
    # The gem's validator catches dangerous patterns before install.
    # This tests that the validation pipeline works end-to-end.
    # We use a robot that returns dangerous code to verify rejection.
    dangerous_robot = DangerousRobot.new
    CityCouncil.code_robot = dangerous_robot

    council = CityCouncil.new
    assert_raises(SelfAgency::SecurityError) do
      council._("Generate a method that does system calls")
    end
  ensure
    CityCouncil.code_robot = @robot
  end

  # ==========================================
  # Department classes also learn via _()
  # ==========================================

  def test_department_classes_learn_via_underscore
    fire = FireDepartment.new
    description = <<~DESC
      Generate a Ruby method for class `FireDepartment`.
      Department capability for drone emergency response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with status and actions.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    DESC

    method_names = fire._(description)
    assert method_names.size >= 1, "FireDepartment should learn via _()"

    actual_name = method_names.first
    assert fire.respond_to?(actual_name),
      "FireDepartment should have the learned method"

    result = fire.public_send(actual_name)
    assert_kind_of Hash, result
    assert result[:status]
  end

  private

  def wire_departments(robot, bus)
    [CityCouncil, FireDepartment, PoliceDepartment, EMS, Utilities].each do |klass|
      klass.code_robot = robot
      klass.event_bus  = bus
    end
  end

  # Test helper: returns dangerous code to verify the gem rejects it
  class DangerousRobot
    Result = Struct.new(:last_text_content)

    def run(message:, **_kwargs)
      Result.new(<<~RUBY)
        ```ruby
        def dangerous_action
          system("echo pwned")
        end
        ```
      RUBY
    end
  end
end
