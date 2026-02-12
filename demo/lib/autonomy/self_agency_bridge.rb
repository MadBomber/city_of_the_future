require_relative "code_extractor"

class SelfAgencyBridge
  def self.method_name_for(reason)
    base = reason.downcase.gsub(/[^a-z0-9\s]/, "").strip.gsub(/\s+/, "_").slice(0, 40)
    "coordinate_#{base}"
  end

  def initialize(robot:, target_class: "CityCouncil", logger: nil)
    @robot        = robot
    @target_class = target_class
    @logger       = logger
  end

  def attach(bus)
    @bus = bus

    bus.subscribe(:escalation) do |delivery|
      handle_escalation(delivery.message)
      delivery.ack!
    end
  end

  private

  def handle_escalation(esc)
    method_name = self.class.method_name_for(esc.reason)
    @logger&.info "SelfAgencyBridge: escalation #{esc.call_id} → #{@target_class}##{method_name}"

    @bus.publish(:display, DisplayEvent.new(
      type:      :escalation_analysis,
      data:      { call_id: esc.call_id, reason: esc.reason,
                   target_class: @target_class, method_name: method_name },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "Generating new capability: #{method_name} for #{@target_class}.",
      voice:      nil,
      department: "System",
      priority:   1
    ))

    prompt = <<~PROMPT
      Generate a Ruby method `#{method_name}` for class `#{@target_class}`.

      An emergency escalation occurred:
      - Call: #{esc.original_call}
      - Reason: #{esc.reason}
      - Tried departments: #{esc.attempted_departments.join(", ")}

      The method should coordinate a multi-department response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    PROMPT

    result  = @robot.run(message: prompt)
    content = result.last_text_content
    source  = CodeExtractor.extract(content)

    if source
      @logger&.info "SelfAgencyBridge: generated #{@target_class}##{method_name}"
      @bus.publish(:method_gen, MethodGen.new(
        target_class: @target_class,
        method_name:  method_name,
        source_code:  source,
        status:       :pending
      ))
    else
      @logger&.info "SelfAgencyBridge: extraction failed"
      @bus.publish(:display, DisplayEvent.new(
        type: :method_gen_failed,
        data: { class: @target_class, method: method_name, reason: "extraction failed" },
        timestamp: Time.now
      ))
    end
  end
end
