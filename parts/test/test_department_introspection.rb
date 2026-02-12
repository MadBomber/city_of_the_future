# frozen_string_literal: true

require_relative "test_helper"

class TestDepartmentIntrospection < Minitest::Test
  def setup
    @klass = Department.dup
    @klass.department_name = "Test Department"
    @klass.instance_variable_set(:@chaos_class_sources, {
      handle_fire: "def handle_fire(details)\n  \"responding to fire\"\nend",
      handle_flood: "def handle_flood(details)\n  \"responding to flood\"\nend"
    })
    @dept = @klass.new
  end

  def test_generated_methods_returns_stored_method_names
    assert_equal [:handle_fire, :handle_flood], @dept.generated_methods
  end

  def test_generated_methods_empty_when_no_sources
    empty_class = Department.dup
    dept = empty_class.new
    assert_empty dept.generated_methods
  end

  def test_generated_source_returns_code_for_known_method
    source = @dept.generated_source(:handle_fire)
    assert_includes source, "def handle_fire(details)"
    assert_includes source, "responding to fire"
  end

  def test_generated_source_accepts_string_key
    source = @dept.generated_source("handle_flood")
    assert_includes source, "def handle_flood(details)"
  end

  def test_generated_source_returns_nil_for_unknown_method
    assert_nil @dept.generated_source(:handle_earthquake)
  end

  def test_generated_source_returns_nil_when_no_sources_exist
    empty_class = Department.dup
    dept = empty_class.new
    assert_nil dept.generated_source(:anything)
  end

  def test_sources_are_independent_across_dup_classes
    other_class = Department.dup
    other_class.instance_variable_set(:@chaos_class_sources, {
      handle_rescue: "def handle_rescue(details)\n  \"rescuing\"\nend"
    })

    other = other_class.new

    assert_equal [:handle_fire, :handle_flood], @dept.generated_methods
    assert_equal [:handle_rescue], other.generated_methods
    assert_nil other.generated_source(:handle_fire)
    assert_nil @dept.generated_source(:handle_rescue)
  end

  def test_multiple_instances_share_same_sources
    dept2 = @klass.new
    assert_equal @dept.generated_methods, dept2.generated_methods
    assert_equal @dept.generated_source(:handle_fire), dept2.generated_source(:handle_fire)
  end
end
