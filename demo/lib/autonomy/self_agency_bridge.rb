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
      # Use the actual method name from the generated source
      actual_name = source[/\bdef\s+(\w+)/, 1] || method_name
      @logger&.info "SelfAgencyBridge: generated #{@target_class}##{actual_name}"
      @bus.publish(:method_gen, MethodGen.new(
        target_class: @target_class,
        method_name:  actual_name,
        source_code:  source,
        status:       :pending
      ))

      retry_with_new_capability(esc, actual_name)
    else
      @logger&.info "SelfAgencyBridge: extraction failed"
      @bus.publish(:display, DisplayEvent.new(
        type: :method_gen_failed,
        data: { class: @target_class, method: method_name, reason: "extraction failed" },
        timestamp: Time.now
      ))
    end
  end

  def retry_with_new_capability(esc, method_name)
    # Allow governance to process and install the method
    sleep 0.3

    klass = Object.const_get(@target_class)
    return unless klass.method_defined?(method_name)

    instance = klass.new
    result = instance.public_send(method_name, call_id: esc.call_id)
    @logger&.info "SelfAgencyBridge: retried #{esc.call_id} via #{@target_class}##{method_name} → #{result[:status]}"

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "Call #{esc.call_id} handled using new capability. #{result[:plan] || result[:notes]}",
      voice:      nil,
      department: @target_class,
      priority:   1
    ))

    @bus.publish(:display, DisplayEvent.new(
      type:      :adaptation_success,
      data:      { call_id: esc.call_id, method: method_name,
                   target_class: @target_class, result: result },
      timestamp: Time.now
    ))

    dispatch_multi_agency(esc, result) if result[:departments]
  rescue => e
    @logger&.info "SelfAgencyBridge: retry failed for #{esc.call_id} — #{e.message}"
  end

  def dispatch_multi_agency(esc, result)
    result[:departments].each do |dept_plan|
      dept_name = dept_plan[:department]
      @logger&.info "SelfAgencyBridge: multi-agency dispatch #{dept_name} for #{esc.call_id}"

      @bus.publish(:dispatch, DispatchOrder.new(
        call_id:         "#{esc.call_id}-#{dept_name[0..2].upcase}",
        department:      dept_name.downcase,
        units_requested: dept_plan[:units_requested] || 1,
        priority:        1,
        eta:             "immediate"
      ))
    end
  end
end
