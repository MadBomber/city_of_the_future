class Operations
  def initialize(logger: nil)
    @logger      = logger
    @departments = {}  # :name => department
  end

  def register(dept)
    @departments[dept.name.downcase.to_sym] = dept
  end

  def attach(bus)
    @bus = bus

    bus.subscribe(:dispatch) do |delivery|
      handle_dispatch(delivery.message)
      delivery.ack!
    end
  end

  def handle_dispatch(order)
    dept = find_department(order)

    if dept.nil?
      escalate(order, "No department available for '#{order.department}'")
      return
    end

    result = dept.handle(order)

    if result[:status] == :dispatched
      dispatch_success(order, dept, result)
    else
      escalate(order, result[:reason], [dept.name])
    end
  end

  private

  def find_department(order)
    key = order.department.to_s.downcase.to_sym
    dept = @departments[key]
    return dept if dept

    @departments.values.find { |d| d.can_handle?(order) }
  end

  def dispatch_success(order, dept, result)
    @logger&.info "Operations: dispatched #{order.call_id} → #{dept.name} #{result[:unit_id]}"

    @bus.publish(:field_reports, FieldReport.new(
      call_id:    order.call_id,
      department: dept.name,
      unit_id:    result[:unit_id],
      status:     :dispatched,
      notes:      result[:notes],
      timestamp:  Time.now
    ))

    @bus.publish(:department_status, dept.to_dept_status)

    @bus.publish(:display, DisplayEvent.new(
      type:      :dispatch,
      data:      { call_id: order.call_id, department: dept.name,
                   unit_id: result[:unit_id] },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "#{dept.name} #{result[:unit_id]} dispatched for call #{order.call_id}",
      voice:      "Samantha",
      department: "Dispatch",
      priority:   order.priority
    ))
  end

  def escalate(order, reason, attempted = [])
    @logger&.info "Operations: escalating #{order.call_id} — #{reason}"

    @bus.publish(:escalation, Escalation.new(
      call_id:               order.call_id,
      reason:                reason,
      original_call:         order.department,
      attempted_departments: attempted,
      timestamp:             Time.now
    ))

    @bus.publish(:display, DisplayEvent.new(
      type:      :escalation,
      data:      { call_id: order.call_id, reason: reason },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "Escalation for call #{order.call_id}: #{reason}",
      voice:      nil,
      department: "Operations",
      priority:   1
    ))
  end
end
