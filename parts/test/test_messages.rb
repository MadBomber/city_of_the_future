# frozen_string_literal: true

require_relative "test_helper"

class TestMessages < Minitest::Test
  def test_incident_report_fields
    msg = IncidentReport.new(
      call_id: 1, department: "Fire", incident: :blaze,
      details: "fire at 123 Main", severity: :critical, timestamp: Time.now
    )
    assert_equal 1, msg.call_id
    assert_equal "Fire", msg.department
    assert_equal :blaze, msg.incident
    assert_equal :critical, msg.severity
  end

  def test_incident_report_is_frozen
    msg = IncidentReport.new(
      call_id: 1, department: "Fire", incident: :blaze,
      details: "details", severity: :normal, timestamp: Time.now
    )
    assert msg.frozen?
  end

  def test_dispatch_result_fields
    msg = DispatchResult.new(
      call_id: 2, department: "EMS", method: :handle_cardiac,
      result: "ok", was_new: true, elapsed: 1.5
    )
    assert_equal 2, msg.call_id
    assert_equal "EMS", msg.department
    assert_equal :handle_cardiac, msg.method
    assert_equal true, msg.was_new
    assert_equal 1.5, msg.elapsed
  end

  def test_mutual_aid_request_fields
    msg = MutualAidRequest.new(
      from_department: "Fire", description: "need help",
      priority: :critical, call_id: 3
    )
    assert_equal "Fire", msg.from_department
    assert_equal :critical, msg.priority
    assert_equal 3, msg.call_id
  end

  def test_resource_update_fields
    msg = ResourceUpdate.new(
      department: "Police", resource_type: :officers,
      available: 5, total: 10
    )
    assert_equal "Police", msg.department
    assert_equal 5, msg.available
    assert_equal 10, msg.total
  end

  def test_method_generated_fields
    msg = MethodGenerated.new(
      department: "Fire", method_name: :handle_blaze,
      scope: :instance, source_lines: 12
    )
    assert_equal "Fire", msg.department
    assert_equal :handle_blaze, msg.method_name
    assert_equal 12, msg.source_lines
  end

  def test_messages_are_data_classes
    assert IncidentReport < Data
    assert DispatchResult < Data
    assert MutualAidRequest < Data
    assert ResourceUpdate < Data
    assert MethodGenerated < Data
  end

  def test_equality_by_value
    t = Time.now
    a = IncidentReport.new(call_id: 1, department: "X", incident: :y, details: "z", severity: :normal, timestamp: t)
    b = IncidentReport.new(call_id: 1, department: "X", incident: :y, details: "z", severity: :normal, timestamp: t)
    assert_equal a, b
  end
end
