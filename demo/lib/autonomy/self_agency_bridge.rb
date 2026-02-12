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
    return if @handled.any? { |h| esc.call_id.start_with?(h) }
    @handled << esc.call_id

    klass = Object.const_get(@target_class)
    method_name = self.class.method_name_for(esc.reason)

    if klass.method_defined?(method_name) || already_has_coordinator?(klass, esc)
      reuse_existing(esc, klass, method_name)
    else
      learn_new_capability(esc, klass)
    end
  end

  def already_has_coordinator?(klass, esc)
    # Check if any coordinate_* method exists that could handle this
    klass.instance_methods.any? { |m| m.to_s.start_with?("coordinate_") }
  end

  def reuse_existing(esc, klass, method_name = nil)
    # Find the best coordinator method
    actual_name = if method_name && klass.method_defined?(method_name)
      method_name
    else
      klass.instance_methods.find { |m| m.to_s.start_with?("coordinate_") }&.to_s
    end

    return unless actual_name

    @logger&.info "SelfAgencyBridge: reusing #{@target_class}##{actual_name} for #{esc.call_id}"

    @bus.publish(:display, DisplayEvent.new(
      type:      :capability_reused,
      data:      { call_id: esc.call_id, target_class: @target_class, method_name: actual_name.to_s },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "Reusing existing capability: #{actual_name} on #{@target_class}.",
      voice:      nil,
      department: "System",
      priority:   1
    ))

    retry_with_new_capability(esc, actual_name.to_s)
  end

  def learn_new_capability(esc, klass)
    description = build_description(esc)

    @bus.publish(:display, DisplayEvent.new(
      type:      :escalation_analysis,
      data:      { call_id: esc.call_id, reason: esc.reason,
                   target_class: @target_class },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "#{@target_class} is learning a new capability...",
      voice:      nil,
      department: "System",
      priority:   1
    ))

    instance = klass.new
    method_names = instance._(description)
    actual_name = method_names.first

    retry_with_new_capability(esc, actual_name.to_s)

    generate_department_capabilities(esc)
  rescue SelfAgency::Error => e
    @logger&.info "SelfAgencyBridge: self_agency failed — #{e.message}"
    @bus.publish(:display, DisplayEvent.new(
      type:      :method_gen_failed,
      data:      { class: @target_class, method: "unknown", reason: e.message },
      timestamp: Time.now
    ))
  end

  def build_description(esc)
    <<~DESC
      Generate a Ruby method for class `#{@target_class}`.

      An emergency escalation occurred:
      - Call: #{esc.original_call}
      - Reason: #{esc.reason}
      - Tried departments: #{esc.attempted_departments.join(", ")}

      The method should coordinate a multi-department response.
      Return ONLY a def...end block. No class wrapper.
      Return a Hash with a response plan.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    DESC
  end

  def retry_with_new_capability(esc, method_name)
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
  end

  def generate_department_capabilities(esc)
    DEPT_CLASS_MAP.each do |dept_name, class_name|
      klass = Object.const_get(class_name)

      # Skip if self_agency has already generated methods for this class
      next if klass.respond_to?(:self_agency_class_sources) && klass.self_agency_class_sources.any?

      role = "emergency response coordination"

      description = <<~DESC
        Generate a Ruby method for class `#{class_name}`.
        Department capability for drone emergency response.
        Role: #{role}
        Context: #{esc.original_call}
        Return ONLY a def...end block. No class wrapper.
        Return a Hash with status and actions.
        Do NOT use system, exec, eval, File, IO, or shell commands.
      DESC

      instance = klass.new
      instance._(description)
    rescue SelfAgency::Error => e
      @logger&.info "SelfAgencyBridge: department capability gen failed for #{class_name} — #{e.message}"
    end
  end
end
