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
    @handled      = []
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
    # Prevent infinite recursion: skip sub-dispatches and already-handled calls
    return if @handled.any? { |h| esc.call_id.start_with?(h) }
    @handled << esc.call_id

    method_name = self.class.method_name_for(esc.reason)
    @logger&.info "SelfAgencyBridge: escalation #{esc.call_id} → #{@target_class}##{method_name}"

    # Generate code to discover the method name the LLM would produce
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

    unless source
      @logger&.info "SelfAgencyBridge: extraction failed"
      @bus.publish(:display, DisplayEvent.new(
        type: :method_gen_failed,
        data: { class: @target_class, method: method_name, reason: "extraction failed" },
        timestamp: Time.now
      ))
      return
    end

    actual_name = source[/\bdef\s+(\w+)/, 1] || method_name
    klass = Object.const_get(@target_class)

    if klass.method_defined?(actual_name)
      # Capability already exists — reuse it
      @logger&.info "SelfAgencyBridge: reusing #{@target_class}##{actual_name} for #{esc.call_id}"

      @bus.publish(:display, DisplayEvent.new(
        type:      :capability_reused,
        data:      { call_id: esc.call_id, target_class: @target_class, method_name: actual_name },
        timestamp: Time.now
      ))

      @bus.publish(:voice_out, VoiceOut.new(
        text:       "Reusing existing capability: #{actual_name} on #{@target_class}.",
        voice:      nil,
        department: "System",
        priority:   1
      ))

      retry_with_new_capability(esc, actual_name)
    else
      # New capability needed — send through governance
      @logger&.info "SelfAgencyBridge: generated #{@target_class}##{actual_name}"

      @bus.publish(:display, DisplayEvent.new(
        type:      :escalation_analysis,
        data:      { call_id: esc.call_id, reason: esc.reason,
                     target_class: @target_class, method_name: actual_name },
        timestamp: Time.now
      ))

      @bus.publish(:voice_out, VoiceOut.new(
        text:       "Generating new capability: #{actual_name} for #{@target_class}.",
        voice:      nil,
        department: "System",
        priority:   1
      ))

      @bus.publish(:method_gen, MethodGen.new(
        target_class: @target_class,
        method_name:  actual_name,
        source_code:  source,
        status:       :pending
      ))

      retry_with_new_capability(esc, actual_name)
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

  DEPT_CLASS_MAP = {
    "Fire"      => "FireDepartment",
    "Police"    => "PoliceDepartment",
    "EMS"       => "EMS",
    "Utilities" => "Utilities"
  }.freeze

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

    generate_department_capabilities(esc, result)
  end

  def generate_department_capabilities(esc, result)
    result[:departments].each do |dept_plan|
      dept_name  = dept_plan[:department]
      class_name = DEPT_CLASS_MAP[dept_name]
      next unless class_name

      role = dept_plan[:role] || "emergency response"

      prompt = <<~PROMPT
        Generate a Ruby method for class `#{class_name}`.
        Department capability for drone emergency response.
        Role: #{role}
        Context: #{esc.original_call}
        Return ONLY a def...end block. No class wrapper.
        Return a Hash with status and actions.
        Do NOT use system, exec, eval, File, IO, or shell commands.
      PROMPT

      robot_result = @robot.run(message: prompt)
      content = robot_result.last_text_content
      source  = CodeExtractor.extract(content)

      next unless source

      actual_name = source[/\bdef\s+(\w+)/, 1]
      next unless actual_name

      klass = Object.const_get(class_name)
      if klass.method_defined?(actual_name)
        @logger&.info "SelfAgencyBridge: #{class_name}##{actual_name} already exists, skipping"
        next
      end

      @logger&.info "SelfAgencyBridge: generated #{class_name}##{actual_name}"

      @bus.publish(:display, DisplayEvent.new(
        type:      :escalation_analysis,
        data:      { call_id: esc.call_id, reason: role,
                     target_class: class_name, method_name: actual_name },
        timestamp: Time.now
      ))

      @bus.publish(:method_gen, MethodGen.new(
        target_class: class_name,
        method_name:  actual_name,
        source_code:  source,
        status:       :pending
      ))
    end
  end
end
