require_relative "llm/live_handler"
require_relative "llm/scenario_recorder"
require_relative "llm/scenario_driver"

module LLMMode
  MODES = %w[live record replay].freeze

  def self.setup(bus, mode:, scenario_path: nil, logger: nil)
    case mode
    when "live"
      handler = LiveHandler.new(logger: logger)
      handler.attach(bus)
      handler
    when "record"
      path = scenario_path || "scenarios/demo.jsonl"
      handler = ScenarioRecorder.new(path)
      handler.attach(bus)
      handler
    when "replay"
      path = scenario_path || "scenarios/demo.jsonl"
      handler = ScenarioDriver.new(path)
      handler.attach(bus)
      handler
    else
      raise ArgumentError, "Unknown LLM mode: #{mode}. Use: #{MODES.join(', ')}"
    end
  end
end
