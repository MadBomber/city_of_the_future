require "ruby_llm"

class LiveHandler
  def attach(bus)
    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      chat = RubyLLM.chat(model: req.model)
      response = chat.ask(req.prompt)

      bus.publish(:llm_responses, LLMResponse.new(
        content:        response.content,
        tool_calls:     response.tool_calls,
        tokens:         (response.input_tokens || 0) + (response.output_tokens || 0),
        correlation_id: req.correlation_id
      ))

      delivery.ack!
    end
  end
end
