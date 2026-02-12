require "json"

class Intelligence
  def initialize(logger: nil)
    @logger        = logger
    @pending_calls = {}  # correlation_id => EmergencyCall
  end

  def attach(bus)
    @bus = bus

    bus.subscribe(:calls) do |delivery|
      classify_call(delivery.message)
      delivery.ack!
    end

    bus.subscribe(:llm_responses) do |delivery|
      resp = delivery.message
      if @pending_calls.key?(resp.correlation_id)
        handle_llm_response(resp)
        delivery.ack!
      end
    end
  end

  def classify_call(call)
    correlation_id = "intel-#{call.call_id}"
    @pending_calls[correlation_id] = call
    @logger&.info "Intelligence: classifying #{call.call_id} (#{correlation_id})"

    prompt = <<~PROMPT
      Classify this 911 emergency call. Return ONLY valid JSON, no markdown.

      Caller: #{call.caller}
      Location: #{call.location}
      Description: #{call.description}
      Severity: #{call.severity}

      Return JSON with these fields:
      {"department": "<fire|police|ems|utilities>", "priority": <1-5>, "units_requested": <integer>, "eta": "<estimated response time>"}
    PROMPT

    @bus.publish(:llm_requests, LLMRequest.new(
      prompt:         prompt,
      tools:          nil,
      model:          nil,
      correlation_id: correlation_id
    ))
  end

  def handle_llm_response(resp)
    call = @pending_calls.delete(resp.correlation_id)
    return unless call

    classification = parse_classification(resp.content)
    @logger&.info "Intelligence: classified #{call.call_id} → #{classification[:department]}"

    @bus.publish(:dispatch, DispatchOrder.new(
      call_id:         call.call_id,
      department:      classification[:department],
      units_requested: classification[:units_requested],
      priority:        classification[:priority],
      eta:             classification[:eta]
    ))
  end

  def parse_classification(content)
    data = JSON.parse(content, symbolize_names: true)
    {
      department:      data[:department]&.to_s || "unknown",
      priority:        data[:priority]&.to_i || 3,
      units_requested: data[:units_requested]&.to_i || 1,
      eta:             data[:eta]&.to_s || "unknown"
    }
  rescue JSON::ParserError
    @logger&.info "Intelligence: JSON parse failed, defaulting to unknown"
    { department: "unknown", priority: 3, units_requested: 1, eta: "unknown" }
  end
end
