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
  # Pattern matching
  # ==========================================

  def test_matches_escalation_pattern
    result = @robot.run(message: "An emergency escalation occurred for call C-009")
    assert_match(/coordinate_drone_response/, result.last_text_content)
  end

  def test_matches_insufficient_units_pattern
    result = @robot.run(message: "Reason: insufficient units (0/1)")
    assert_match(/coordinate_drone_response/, result.last_text_content)
  end

  def test_matches_method_missing_pattern
    result = @robot.run(message: "Generate a Ruby instance method named `handle_drone_swarm` — method_missing")
    assert_match(/handle_novel_emergency/, result.last_text_content)
  end

  def test_returns_default_for_unmatched_prompt
    result = @robot.run(message: "something completely unrelated and unique xyz123")
    assert_match(/handle_unknown_situation/, result.last_text_content)
  end

  def test_pattern_matching_is_case_insensitive
    result = @robot.run(message: "ESCALATION occurred!")
    assert_match(/coordinate_drone_response/, result.last_text_content)
  end

  # ==========================================
  # CodeExtractor compatibility
  # ==========================================

  def test_escalation_response_passes_code_extractor
    result = @robot.run(message: "escalation for call C-009")
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

  def test_matches_self_agency_bridge_prompt
    # This is the actual prompt format from SelfAgencyBridge#handle_escalation
    prompt = <<~PROMPT
      Generate a Ruby method `coordinate_insufficient_units_01` for class `CityCouncil`.

      An emergency escalation occurred:
      - Call: #<data EmergencyCall call_id="C-009">
      - Reason: insufficient units (0/1)
      - Tried departments: CityCouncil

      The method should coordinate a multi-department response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    PROMPT

    result = @robot.run(message: prompt)
    source = CodeExtractor.extract(result.last_text_content)
    assert source, "Should produce extractable code from SelfAgencyBridge prompt"
    assert_match(/\Adef\s+/, source)
  end

  # ==========================================
  # Scenario file validation
  # ==========================================

  def test_scenario_file_has_required_structure
    responses = YAML.load_file(RESPONSES_PATH, permitted_classes: [Symbol])

    assert_kind_of Array, responses
    assert responses.size >= 2, "Should have at least 2 response entries"

    responses.each do |entry|
      assert entry.key?("response"), "Each entry must have a 'response'"
      assert entry.key?("patterns"), "Each entry must have 'patterns'"
    end

    defaults = responses.select { |e| e["default"] }
    assert_equal 1, defaults.size, "Should have exactly 1 default entry"
  end
end
