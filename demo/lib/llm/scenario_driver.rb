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
        dept = classify_from_prompt(req.prompt)
        bus.publish(:llm_responses, LLMResponse.new(
          content:        "{\"department\":\"#{dept}\",\"priority\":2,\"units_requested\":1,\"eta\":\"5min\"}",
          tool_calls:     nil,
          tokens:         0,
          correlation_id: req.correlation_id
        ))
      end

      delivery.ack!
    end
  end

  private

  KEYWORDS = {
    "fire"      => %w[fire smoke flames burning blaze explosion grease engulfed],
    "police"    => %w[robbed robbery gun theft stolen broke\ in assault weapon
                      fight knife hit\ and\ run breaking\ into road\ rage chase
                      gunshot shots bank\ robbery shoplifter erratic bat
                      suspect carjack],
    "ems"       => %w[chest\ pain breathing heart collapsed injured bleeding
                      unconscious allergic seizure labor pregnant fell\ from
                      drowning pulse CPR accident not\ responding overdose
                      hit\ by struck\ by],
    "utilities" => %w[water pipe burst power outage gas\ leak sewer electrical
                      gas\ smell hydrant transformer manhole steam
                      street\ light corroded flooding brown\ water]
  }.freeze

  def classify_from_prompt(prompt)
    text = prompt.to_s
    description = text[/Description:\s*(.+)/i, 1] || text
    desc = description.downcase

    KEYWORDS.each do |dept, words|
      return dept if words.any? { |w| desc.include?(w) }
    end
    "unknown"
  end
end
