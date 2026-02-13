# frozen_string_literal: true

require_relative "test_helper"
require "vsm"
require_relative "../tools/dispatch_tool"
require_relative "../tools/resource_query_tool"

class TestTools < Minitest::Test
  def test_dispatch_tool_name
    assert_equal "dispatch", DispatchTool.tool_name
  end

  def test_dispatch_tool_description
    assert_includes DispatchTool.tool_description, "Dispatch"
  end

  def test_dispatch_tool_schema_has_required_fields
    schema = DispatchTool.tool_schema
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "department"
    assert_includes schema[:required], "incident"
    assert_includes schema[:required], "details"
  end

  def test_dispatch_tool_descriptor
    tool = DispatchTool.new
    desc = tool.tool_descriptor
    assert_instance_of VSM::Tool::Descriptor, desc
    assert_equal "dispatch", desc.name
  end

  def test_dispatch_tool_to_openai_tool
    tool = DispatchTool.new
    openai = tool.tool_descriptor.to_openai_tool
    assert_equal "function", openai[:type]
    assert_equal "dispatch", openai[:function][:name]
    assert openai[:function][:parameters]
  end

  def test_dispatch_tool_to_anthropic_tool
    tool = DispatchTool.new
    anthropic = tool.tool_descriptor.to_anthropic_tool
    assert_equal "dispatch", anthropic[:name]
    assert anthropic[:input_schema]
  end

  def test_resource_query_tool_name
    assert_equal "query_resources", ResourceQueryTool.tool_name
  end

  def test_resource_query_tool_schema
    schema = ResourceQueryTool.tool_schema
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "department"
  end

  def test_resource_query_tool_descriptor
    tool = ResourceQueryTool.new
    desc = tool.tool_descriptor
    assert_instance_of VSM::Tool::Descriptor, desc
    assert_equal "query_resources", desc.name
  end

  def test_resource_query_tool_run_with_no_memory
    tool = ResourceQueryTool.new
    tool.city_memory = nil
    result = tool.run({ "department" => "fire" })
    assert_includes result, "No data"
  end

  def test_tools_are_vsm_tool_capsules
    assert DispatchTool < VSM::ToolCapsule
    assert ResourceQueryTool < VSM::ToolCapsule
  end
end
