# frozen_string_literal: true

require "vsm"

class ResourceQueryTool < VSM::ToolCapsule
  tool_name "query_resources"
  tool_description "Query department resource availability and active incident count"
  tool_schema({
    type: "object",
    properties: {
      department: { type: "string", description: "Department type to query (e.g. fire, police, ems)" }
    },
    required: %w[department]
  })

  attr_writer :city_memory

  def run(args)
    dept_key = args["department"].to_sym
    data     = @city_memory&.get(:departments) || {}
    dept     = data[dept_key]

    if dept
      "#{args["department"]}: #{dept[:handlers]} handlers, active since creation"
    else
      "No data for department: #{args["department"]}"
    end
  end
end
