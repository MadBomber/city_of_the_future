require "ruby_llm"
require "json"

class ScenarioRecorder
  def initialize(output_path)
    @log = File.open(output_path, "w")
    @sequence = 0
  end

  def attach(bus)
    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      chat = RubyLLM.chat(model: req.model)
      response = chat.ask(req.prompt)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      record = {
        seq:             @sequence += 1,
        timestamp:       Time.now.iso8601(3),
        correlation_id:  req.correlation_id,
        request:         { prompt: req.prompt, tools: req.tools, model: req.model },
        response:        {
          content:    response.content,
          tool_calls: response.tool_calls,
          tokens:     (response.input_tokens || 0) + (response.output_tokens || 0)
        },
        elapsed_seconds: elapsed.round(3)
      }

      @log.puts(JSON.generate(record))
      @log.flush

      bus.publish(:llm_responses, LLMResponse.new(
        content:        response.content,
        tool_calls:     response.tool_calls,
        tokens:         (response.input_tokens || 0) + (response.output_tokens || 0),
        correlation_id: req.correlation_id
      ))

      delivery.ack!
    end
  end

  def close
    @log.close
  end
end
