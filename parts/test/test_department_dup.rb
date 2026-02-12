# frozen_string_literal: true

require_relative "test_helper"

class TestDepartmentDup < Minitest::Test
  def setup
    @fire_class   = Department.dup
    @police_class = Department.dup
  end

  def test_dup_creates_distinct_classes
    refute_same @fire_class, @police_class
  end

  def test_dup_inherits_self_agency
    assert_includes @fire_class.ancestors, SelfAgency
  end

  def test_dup_inherits_chaos_rescue
    assert_includes @fire_class.ancestors, ChaosToTheRescue::ChaosRescue
  end

  def test_dup_department_name_from_explicit_set
    @fire_class.department_name = "FireDept"
    assert_equal "FireDept", @fire_class.department_name
  end

  def test_dup_classes_have_independent_names
    @fire_class.department_name   = "Fire"
    @police_class.department_name = "Police"

    assert_equal "Fire",   @fire_class.department_name
    assert_equal "Police", @police_class.department_name
  end

  def test_instances_of_dup_get_class_department_name
    @fire_class.department_name = "Fire"
    fire = @fire_class.new

    assert_equal "Fire", fire.name
  end

  def test_dup_instances_have_independent_buses
    fire   = @fire_class.new
    police = @police_class.new

    refute_same fire.bus, police.bus
  end

  def test_dup_instances_have_independent_robots
    fire   = @fire_class.new
    police = @police_class.new

    refute_same fire.robots, police.robots
  end
end
