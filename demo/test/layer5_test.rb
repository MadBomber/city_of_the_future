require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/departments"
require_relative "../lib/vsm/intelligence"
require_relative "../lib/vsm/operations"

class Layer5Test < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # ==========================================
  # Department unit tests
  # ==========================================

  def test_fire_department_handles_fire
    dept  = FireDepartment.new
    order = DispatchOrder.new(call_id: "C-1", department: "fire", units_requested: 1, priority: 1, eta: "5min")

    assert dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :dispatched, result[:status]
    assert_match(/^E-/, result[:unit_id])
  end

  def test_fire_department_rejects_wrong_type
    dept  = FireDepartment.new
    order = DispatchOrder.new(call_id: "C-2", department: "police", units_requested: 1, priority: 2, eta: "5min")

    refute dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :rejected, result[:status]
    assert_match(/wrong type/, result[:reason])
  end

  def test_police_department_handles_crime
    dept  = PoliceDepartment.new
    order = DispatchOrder.new(call_id: "C-3", department: "robbery", units_requested: 1, priority: 2, eta: "8min")

    assert dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :dispatched, result[:status]
    assert_match(/^U-/, result[:unit_id])
  end

  def test_ems_handles_medical
    dept  = EMS.new
    order = DispatchOrder.new(call_id: "C-4", department: "cardiac", units_requested: 1, priority: 1, eta: "4min")

    assert dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :dispatched, result[:status]
    assert_match(/^M-/, result[:unit_id])
  end

  def test_utilities_handles_gas_leak
    dept  = Utilities.new
    order = DispatchOrder.new(call_id: "C-5", department: "gas_leak", units_requested: 1, priority: 2, eta: "10min")

    assert dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :dispatched, result[:status]
    assert_match(/^UT-/, result[:unit_id])
  end

  def test_city_council_handles_anything
    dept  = CityCouncil.new
    order = DispatchOrder.new(call_id: "C-6", department: "alien_invasion", units_requested: 1, priority: 1, eta: "unknown")

    assert dept.can_handle?(order)
    result = dept.handle(order)
    assert_equal :dispatched, result[:status]
    assert_match(/^CC-/, result[:unit_id])
  end

  def test_department_rejects_insufficient_units
    dept = Utilities.new  # 2 units total

    # Exhaust all units
    dept.handle(DispatchOrder.new(call_id: "C-10", department: "gas_leak", units_requested: 1, priority: 1, eta: "5min"))
    dept.handle(DispatchOrder.new(call_id: "C-11", department: "water_main", units_requested: 1, priority: 2, eta: "5min"))

    order = DispatchOrder.new(call_id: "C-12", department: "power_outage", units_requested: 1, priority: 3, eta: "5min")
    result = dept.handle(order)

    assert_equal :rejected, result[:status]
    assert_match(/insufficient units/, result[:reason])
  end

  def test_department_resolve_frees_unit
    dept  = Utilities.new
    order = DispatchOrder.new(call_id: "C-20", department: "gas_leak", units_requested: 1, priority: 1, eta: "5min")

    dept.handle(order)
    assert_equal 1, dept.available_units

    dept.resolve("C-20")
    assert_equal 2, dept.available_units
  end

  def test_department_capacity_pct
    dept = FireDepartment.new
    assert_equal 1.0, dept.capacity_pct

    dept.handle(DispatchOrder.new(call_id: "C-30", department: "fire", units_requested: 1, priority: 1, eta: "5min"))
    assert_equal 4.0 / 5, dept.capacity_pct
  end

  def test_department_to_dept_status
    dept   = PoliceDepartment.new
    status = dept.to_dept_status

    assert_instance_of DeptStatus, status
    assert_equal "Police", status.department
    assert_equal 4, status.available_units
    assert_equal 0, status.active_calls
    assert_equal 1.0, status.capacity_pct
  end

  # ==========================================
  # Intelligence unit tests
  # ==========================================

  def test_parse_classification_valid_json
    intel = Intelligence.new
    result = intel.parse_classification('{"department":"fire","priority":1,"units_requested":2,"eta":"5min"}')

    assert_equal "fire", result[:department]
    assert_equal 1, result[:priority]
    assert_equal 2, result[:units_requested]
    assert_equal "5min", result[:eta]
  end

  def test_parse_classification_invalid_json
    intel = Intelligence.new
    result = intel.parse_classification("this is not json")

    assert_equal "unknown", result[:department]
    assert_equal 3, result[:priority]
    assert_equal 1, result[:units_requested]
  end

  # ==========================================
  # Intelligence bus tests
  # ==========================================

  def test_intelligence_publishes_llm_request_on_call
    intel = Intelligence.new
    intel.attach(@bus)

    llm_request = nil
    @bus.subscribe(:llm_requests) do |delivery|
      llm_request = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:dispatch) do |delivery|
      delivery.ack!
    end

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-100",
        caller:      "Jane Doe",
        location:    "123 Main St",
        description: "House on fire",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.05
    end

    assert llm_request, "Should publish LLMRequest on :llm_requests"
    assert_equal "intel-C-100", llm_request.correlation_id
    assert_match(/House on fire/, llm_request.prompt)
  end

  def test_intelligence_publishes_dispatch_on_llm_response
    intel = Intelligence.new
    intel.attach(@bus)

    # Fake LLM subscriber that immediately responds
    @bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      @bus.publish(:llm_responses, LLMResponse.new(
        content:        '{"department":"fire","priority":1,"units_requested":2,"eta":"5min"}',
        tool_calls:     nil,
        tokens:         50,
        correlation_id: req.correlation_id
      ))
      delivery.ack!
    end

    dispatch_order = nil
    @bus.subscribe(:dispatch) do |delivery|
      dispatch_order = delivery.message
      delivery.ack!
    end

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-101",
        caller:      "John Doe",
        location:    "456 Oak Ave",
        description: "Building fire",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.1
    end

    assert dispatch_order, "Should publish DispatchOrder on :dispatch"
    assert_equal "C-101", dispatch_order.call_id
    assert_equal "fire", dispatch_order.department
    assert_equal 2, dispatch_order.units_requested
  end

  # ==========================================
  # Operations bus tests
  # ==========================================

  def test_operations_dispatches_to_correct_department
    fire = FireDepartment.new
    ops  = Operations.new
    ops.register(fire)
    ops.attach(@bus)

    field_report = nil
    @bus.subscribe(:field_reports) do |delivery|
      field_report = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:department_status) { |d| d.ack! }
    @bus.subscribe(:display)           { |d| d.ack! }
    @bus.subscribe(:voice_out)         { |d| d.ack! }

    Async do
      @bus.publish(:dispatch, DispatchOrder.new(
        call_id:         "C-200",
        department:      "fire",
        units_requested: 1,
        priority:        1,
        eta:             "5min"
      ))

      sleep 0.05
    end

    assert field_report, "Should publish FieldReport on :field_reports"
    assert_equal "C-200", field_report.call_id
    assert_equal "Fire", field_report.department
    assert_equal :dispatched, field_report.status
  end

  def test_operations_escalates_unknown_department
    ops = Operations.new
    ops.attach(@bus)

    escalation = nil
    @bus.subscribe(:escalation) do |delivery|
      escalation = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display)   { |d| d.ack! }
    @bus.subscribe(:voice_out) { |d| d.ack! }

    Async do
      @bus.publish(:dispatch, DispatchOrder.new(
        call_id:         "C-201",
        department:      "unknown",
        units_requested: 1,
        priority:        3,
        eta:             "unknown"
      ))

      sleep 0.05
    end

    assert escalation, "Should publish Escalation on :escalation"
    assert_equal "C-201", escalation.call_id
    assert_match(/No department available/, escalation.reason)
  end

  # ==========================================
  # End-to-end: call → intelligence → operations → field report
  # ==========================================

  def test_end_to_end_call_to_field_report
    intel = Intelligence.new
    intel.attach(@bus)

    fire = FireDepartment.new
    ops  = Operations.new
    ops.register(fire)
    ops.attach(@bus)

    # Fake LLM subscriber
    @bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      @bus.publish(:llm_responses, LLMResponse.new(
        content:        '{"department":"fire","priority":1,"units_requested":1,"eta":"4min"}',
        tool_calls:     nil,
        tokens:         42,
        correlation_id: req.correlation_id
      ))
      delivery.ack!
    end

    field_report = nil
    @bus.subscribe(:field_reports) do |delivery|
      field_report = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:department_status) { |d| d.ack! }
    @bus.subscribe(:display)           { |d| d.ack! }
    @bus.subscribe(:voice_out)         { |d| d.ack! }

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-E2E-1",
        caller:      "Sarah",
        location:    "789 Elm St",
        description: "Kitchen fire spreading",
        severity:    :high,
        timestamp:   Time.now
      ))

      sleep 0.15
    end

    assert field_report, "Should produce a FieldReport end-to-end"
    assert_equal "C-E2E-1", field_report.call_id
    assert_equal "Fire", field_report.department
    assert_equal :dispatched, field_report.status
  end

  # ==========================================
  # End-to-end escalation: unknown call → escalation
  # ==========================================

  def test_end_to_end_unknown_call_escalation
    intel = Intelligence.new
    intel.attach(@bus)

    ops = Operations.new
    ops.attach(@bus)

    # Fake LLM subscriber — returns "unknown" department
    @bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      @bus.publish(:llm_responses, LLMResponse.new(
        content:        '{"department":"unknown","priority":3,"units_requested":1,"eta":"unknown"}',
        tool_calls:     nil,
        tokens:         30,
        correlation_id: req.correlation_id
      ))
      delivery.ack!
    end

    escalation = nil
    @bus.subscribe(:escalation) do |delivery|
      escalation = delivery.message
      delivery.ack!
    end

    @bus.subscribe(:display)   { |d| d.ack! }
    @bus.subscribe(:voice_out) { |d| d.ack! }

    Async do
      @bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-E2E-2",
        caller:      "Unknown",
        location:    "Downtown",
        description: "Strange lights in the sky",
        severity:    :medium,
        timestamp:   Time.now
      ))

      sleep 0.15
    end

    assert escalation, "Should escalate when no department can handle the call"
    assert_equal "C-E2E-2", escalation.call_id
  end
end
