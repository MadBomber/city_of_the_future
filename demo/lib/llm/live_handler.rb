require "ruby_llm"

class LiveHandler
  DEFAULT_MODEL = "claude-sonnet-4-5-20250929"

  def initialize(logger: nil)
    @logger = logger
  end

  def attach(bus)
    @bus = bus

    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      handle_request(req)
      delivery.ack!
    end
  end

  private

  def handle_request(req)
    model = req.model || DEFAULT_MODEL
    @logger&.info "LiveHandler: requesting #{model} for #{req.correlation_id}"

    chat = RubyLLM.chat(model: model)
    response = chat.ask(req.prompt)

    @logger&.info "LiveHandler: response received for #{req.correlation_id}"

    @bus.publish(:llm_responses, LLMResponse.new(
      content:        response.content,
      tool_calls:     response.tool_calls,
      tokens:         (response.input_tokens || 0) + (response.output_tokens || 0),
      correlation_id: req.correlation_id
    ))
  rescue => e
    @logger&.error "LiveHandler: #{e.class} — #{e.message}"

    # Fall back to keyword classification so the demo doesn't stall
    @bus.publish(:llm_responses, LLMResponse.new(
      content:        classify_fallback(req.prompt),
      tool_calls:     nil,
      tokens:         0,
      correlation_id: req.correlation_id
    ))
  end

  KEYWORDS = {
    "fire"      => %w[fire smoke flames burning blaze explosion],
    "police"    => %w[robbed robbery gun theft stolen assault weapon],
    "ems"       => %w[chest\ pain breathing heart collapsed injured bleeding unconscious],
    "utilities" => %w[water pipe burst power outage gas\ leak sewer electrical]
  }.freeze

  def classify_fallback(prompt)
    text = prompt.to_s
    description = text[/Description:\s*(.+)/i, 1] || text
    desc = description.downcase

    dept = KEYWORDS.each do |d, words|
      break d if words.any? { |w| desc.include?(w) }
    end
    dept = "unknown" if dept.is_a?(Hash)

    "{\"department\":\"#{dept}\",\"priority\":2,\"units_requested\":1,\"eta\":\"5min\"}"
  end
end
