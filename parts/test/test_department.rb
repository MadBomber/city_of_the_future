# frozen_string_literal: true

require_relative "test_helper"

class TestDepartment < Minitest::Test
  def setup
    @dept = Department.new
  end

  def test_default_name
    assert_equal "Department", @dept.name
  end

  def test_custom_name
    dept = Department.new(name: "Parks")
    assert_equal "Parks", dept.name
  end

  def test_robots_starts_empty
    assert_empty @dept.robots
  end

  def test_networks_starts_empty
    assert_empty @dept.networks
  end

  def test_bus_is_a_message_bus
    assert_instance_of TypedBus::MessageBus, @dept.bus
  end

  def test_memory_is_lazy_initialized
    assert_instance_of RobotLab::Memory, @dept.memory
  end

  def test_logger_returns_shared_logger
    assert_instance_of Lumberjack::Logger, @dept.logger
  end

  def test_includes_self_agency
    assert_includes Department.ancestors, SelfAgency
  end

  def test_includes_chaos_rescue
    assert_includes Department.ancestors, ChaosToTheRescue::ChaosRescue
  end
end
