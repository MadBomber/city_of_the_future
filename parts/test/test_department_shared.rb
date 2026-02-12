# frozen_string_literal: true

require_relative "test_helper"

class TestDepartmentShared < Minitest::Test
  def setup
    @fire_class   = Department.dup
    @police_class = Department.dup
  end

  def test_shared_bus_is_same_across_dup_classes
    assert_same @fire_class.shared_bus, @police_class.shared_bus
  end

  def test_shared_bus_is_same_as_department_bus
    assert_same Department.shared_bus, @fire_class.shared_bus
  end

  def test_shared_logger_is_same_across_dup_classes
    assert_same @fire_class.shared_logger, @police_class.shared_logger
  end

  def test_shared_logger_is_same_as_department_logger
    assert_same Department.shared_logger, @fire_class.shared_logger
  end

  def test_instance_logger_is_shared_logger
    fire = @fire_class.new
    assert_same Department.shared_logger, fire.logger
  end

  def test_instance_shared_bus_is_class_shared_bus
    fire = @fire_class.new
    assert_same Department.shared_bus, fire.shared_bus
  end

  def test_shared_bus_is_a_message_bus
    assert_instance_of TypedBus::MessageBus, Department.shared_bus
  end
end
