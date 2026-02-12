require "bundler/setup"
require "minitest/autorun"

require_relative "../lib/llm/replay_robot"
require_relative "../lib/autonomy/code_extractor"

class ReplayRobotTest < Minitest::Test
  RESPONSES_PATH = File.expand_path("../scenarios/demo_robot.yml", __dir__)

  def setup
    @robot = ReplayRobot.new(RESPONSES_PATH)
  end

  # ==========================================
  # Basic API
  # ==========================================

  def test_run_returns_result_with_last_text_content
    result = @robot.run(message: "test prompt about escalation")
    assert_respond_to result, :last_text_content
    assert_kind_of String, result.last_text_content
  end

  def test_accepts_extra_kwargs
    result = @robot.run(message: "test", temperature: 0.5, max_tokens: 100)
    assert_respond_to result, :last_text_content
  end

  # ==========================================
  # Department pattern matching
  # ==========================================

  def test_matches_fire_department_pattern
    result = @robot.run(message: "Generate a Ruby method for class `FireDepartment`.")
    assert_match(/emergency_safety_standby/, result.last_text_content)
  end

  def test_matches_police_department_pattern
    result = @robot.run(message: "Generate a Ruby method for class `PoliceDepartment`.")
    assert_match(/emergency_perimeter_control/, result.last_text_content)
  end

  def test_matches_ems_pattern
    result = @robot.run(message: "Generate a Ruby method for class `EMS`.")
    assert_match(/emergency_medical_standby/, result.last_text_content)
  end

  def test_matches_utilities_pattern
    result = @robot.run(message: "Generate a Ruby method for class `Utilities`.")
    assert_match(/emergency_grid_protection/, result.last_text_content)
  end

  def test_department_responses_pass_code_extractor
    prompts = {
      "FireDepartment"    => /emergency_safety_standby/,
      "PoliceDepartment"  => /emergency_perimeter_control/,
      "class `EMS`"       => /emergency_medical_standby/,
      "class `Utilities`" => /emergency_grid_protection/
    }
    prompts.each do |keyword, method_pattern|
      result = @robot.run(message: "Generate method for #{keyword}")
      source = CodeExtractor.extract(result.last_text_content)
      assert source, "CodeExtractor should extract from #{keyword} response"
      assert_match(method_pattern, source)
    end
  end

  # ==========================================
  # Scenario-specific coordinator matching
  # ==========================================

  def test_matches_drone_scenario
    result = @robot.run(message: "Call: drones everywhere downtown dropping papers")
    assert_match(/coordinate_drone_response/, result.last_text_content)
  end

  def test_matches_portal_scenario
    result = @robot.run(message: "Call: portal opened at the park, armored figures marching through")
    assert_match(/coordinate_interdimensional_breach/, result.last_text_content)
  end

  def test_matches_sinkhole_scenario
    result = @robot.run(message: "Call: massive sinkhole opened up on Elm Street")
    assert_match(/coordinate_sinkhole_response/, result.last_text_content)
  end

  def test_matches_fog_scenario
    result = @robot.run(message: "Call: Strange glowing fog, people confused, can't remember")
    assert_match(/coordinate_anomalous_fog_response/, result.last_text_content)
  end

  def test_matches_swarm_scenario
    result = @robot.run(message: "Call: swarm of metallic things landing on buildings")
    assert_match(/coordinate_aerial_swarm_response/, result.last_text_content)
  end

  def test_matches_creature_scenario
    result = @robot.run(message: "Call: Giant creatures coming out of the river, centipede-like")
    assert_match(/coordinate_creature_emergence_response/, result.last_text_content)
  end

  def test_matches_emp_scenario
    result = @robot.run(message: "Call: Every car stopped working, electronics are dead, jamming")
    assert_match(/coordinate_emp_event_response/, result.last_text_content)
  end

  def test_matches_energy_field_scenario
    result = @robot.run(message: "Call: beam of light hit the clock tower, force field expanding")
    assert_match(/coordinate_energy_field_response/, result.last_text_content)
  end

  def test_matches_crashed_craft_scenario
    result = @robot.run(message: "Call: Something crashed, glowing craft, figures emerging")
    assert_match(/coordinate_unidentified_craft_response/, result.last_text_content)
  end

  def test_generic_escalation_fallback
    result = @robot.run(message: "An emergency escalation occurred, No department available")
    assert_match(/coordinate_emergency_response/, result.last_text_content)
  end

  # ==========================================
  # ChaosBridge and default
  # ==========================================

  def test_matches_method_missing_pattern
    result = @robot.run(message: "Generate a Ruby instance method named `handle_drone_swarm` — method_missing")
    assert_match(/handle_novel_emergency/, result.last_text_content)
  end

  def test_returns_default_for_unmatched_prompt
    result = @robot.run(message: "something completely unrelated and unique xyz123")
    assert_match(/handle_unknown_situation/, result.last_text_content)
  end

  def test_pattern_matching_is_case_insensitive
    result = @robot.run(message: "DRONE swarm overhead!")
    assert_match(/coordinate_drone_response/, result.last_text_content)
  end

  # ==========================================
  # CodeExtractor compatibility
  # ==========================================

  def test_escalation_response_passes_code_extractor
    result = @robot.run(message: "drone swarm escalation for call C-009")
    source = CodeExtractor.extract(result.last_text_content)
    assert source, "CodeExtractor should extract a method from the escalation response"
    assert_match(/\Adef\s+coordinate_drone_response/, source)
    assert_match(/^end\z/, source)
  end

  def test_method_missing_response_passes_code_extractor
    result = @robot.run(message: "method_missing: handle_drone_swarm")
    source = CodeExtractor.extract(result.last_text_content)
    assert source, "CodeExtractor should extract a method from the method_missing response"
    assert_match(/\Adef\s+handle_novel_emergency/, source)
  end

  def test_default_response_passes_code_extractor
    result = @robot.run(message: "something totally unknown xyz")
    source = CodeExtractor.extract(result.last_text_content)
    assert source, "CodeExtractor should extract a method from the default response"
    assert_match(/\Adef\s+handle_unknown_situation/, source)
  end

  # ==========================================
  # Integration: SelfAgencyBridge prompt format
  # ==========================================

  def test_matches_self_agency_bridge_prompt_with_description
    # Actual prompt format — now includes the call description
    prompt = <<~PROMPT
      Generate a Ruby method `coordinate_no_department_available_for_u` for class `CityCouncil`.

      An emergency escalation occurred:
      - Call: Something crashed in the financial district! It's not a plane, it's some kind of craft and it's still glowing!
      - Reason: No department available for 'unknown'
      - Tried departments:

      The method should coordinate a multi-department response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    PROMPT

    result = @robot.run(message: prompt)
    source = CodeExtractor.extract(result.last_text_content)
    assert source, "Should produce extractable code from SelfAgencyBridge prompt"
    assert_match(/coordinate_unidentified_craft_response/, source)
  end

  # ==========================================
  # Scenario file validation
  # ==========================================

  def test_scenario_file_has_required_structure
    responses = YAML.load_file(RESPONSES_PATH, permitted_classes: [Symbol])

    assert_kind_of Array, responses
    assert responses.size >= 15, "Should have at least 15 response entries (4 dept + 9 coordinator scenarios + fallback + missing + default)"

    responses.each do |entry|
      assert entry.key?("response"), "Each entry must have a 'response'"
      assert entry.key?("patterns"), "Each entry must have 'patterns'"
    end

    defaults = responses.select { |e| e["default"] }
    assert_equal 1, defaults.size, "Should have exactly 1 default entry"
  end
end
