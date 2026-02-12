require "json"
require "thread"

class DisplayBridge
  def initialize
    @events = []
    @mutex  = Mutex.new
    @seq    = 0
  end

  def attach(bus)
    bus.subscribe(:display) do |delivery|
      evt = delivery.message
      push_event(type: evt.type, data: evt.data, source: :display)
      delivery.ack!
    end

    bus.subscribe(:calls) do |delivery|
      call = delivery.message
      push_event(
        type:   :incoming_call,
        data:   { call_id: call.call_id, caller: call.caller,
                  location: call.location, description: call.description,
                  severity: call.severity },
        source: :calls
      )
      delivery.ack!
    end

    bus.subscribe(:field_reports) do |delivery|
      rpt = delivery.message
      push_event(
        type:   :field_report,
        data:   { call_id: rpt.call_id, department: rpt.department,
                  unit_id: rpt.unit_id, status: rpt.status, notes: rpt.notes },
        source: :field_reports
      )
      delivery.ack!
    end

    bus.subscribe(:department_status) do |delivery|
      st = delivery.message
      push_event(
        type:   :dept_status,
        data:   { department: st.department, available_units: st.available_units,
                  active_calls: st.active_calls, capacity_pct: st.capacity_pct },
        source: :department_status
      )
      delivery.ack!
    end

    bus.subscribe(:escalation) do |delivery|
      esc = delivery.message
      push_event(
        type:   :escalation_event,
        data:   { call_id: esc.call_id, reason: esc.reason,
                  attempted_departments: esc.attempted_departments },
        source: :escalation
      )
      delivery.ack!
    end

    bus.subscribe(:governance) do |delivery|
      pol = delivery.message
      push_event(
        type:   :governance_event,
        data:   { action: pol.action, decision: pol.decision, reason: pol.reason },
        source: :governance
      )
      delivery.ack!
    end
  end

  def events_since(last_id)
    @mutex.synchronize do
      @events.select { |e| e[:id] > last_id }
    end
  end

  def event_count
    @mutex.synchronize { @events.size }
  end

  def last_id
    @mutex.synchronize { @seq }
  end

  private

  def push_event(type:, data:, source:)
    @mutex.synchronize do
      @seq += 1
      @events << {
        id:        @seq,
        type:      type,
        data:      data,
        source:    source,
        timestamp: Time.now.strftime("%H:%M:%S.%L")
      }
      @events.shift if @events.size > 500
    end
  end
end
