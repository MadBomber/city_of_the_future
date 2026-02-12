require "json"

class ScenarioDriver
  def initialize(scenario_path)
    @responses = {}
    File.foreach(scenario_path) do |line|
      record = JSON.parse(line, symbolize_names: true)
      @responses[record[:correlation_id]] = record
    end
  end

  def attach(bus)
    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      record = @responses[req.correlation_id]

      if record
        sleep(record[:elapsed_seconds] * 0.5)

        bus.publish(:llm_responses, LLMResponse.new(
          content:        record[:response][:content],
          tool_calls:     record[:response][:tool_calls],
          tokens:         record[:response][:tokens],
          correlation_id: req.correlation_id
        ))
      else
        warn "SCENARIO: No recorded response for #{req.correlation_id}"
        bus.publish(:llm_responses, LLMResponse.new(
          content:        '{"error":"no recorded response"}',
          tool_calls:     nil,
          tokens:         0,
          correlation_id: req.correlation_id
        ))
      end

      delivery.ack!
    end
  end
end
