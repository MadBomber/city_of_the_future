require "typed_bus"
require_relative "messages"

module BusSetup
  CHANNELS = {
    calls:             { type: EmergencyCall },
    dispatch:          { type: DispatchOrder },
    department_status: { type: DeptStatus },
    field_reports:     { type: FieldReport },
    escalation:        { type: Escalation },
    llm_requests:      { type: LLMRequest,    max_pending: 5 },
    llm_responses:     { type: LLMResponse },
    method_gen:        { type: MethodGen },
    governance:        { type: PolicyEvent },
    voice_in:          { type: VoiceIn },
    voice_out:         { type: VoiceOut,       timeout: 10 },
    display:           { type: DisplayEvent,   timeout: 5 },
  }.freeze

  def self.create_bus(logger: nil)
    bus = TypedBus::MessageBus.new

    CHANNELS.each do |name, opts|
      bus.add_channel(name, **opts)

      bus.dead_letters(name).on_dead_letter do |delivery|
        reason = delivery.timed_out? ? "timeout" : "nack"
        logger&.warn "DLQ [#{name}]: #{delivery.message.class} — #{reason}"
      end
    end

    bus
  end
end
