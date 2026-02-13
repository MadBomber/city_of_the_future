# frozen_string_literal: true

require "vsm"

class DispatchTool < VSM::ToolCapsule
  tool_name "dispatch"
  tool_description "Dispatch an emergency to the appropriate department"
  tool_schema({
    type: "object",
    properties: {
      department: { type: "string", description: "Department type (e.g. fire, police, ems)" },
      incident:   { type: "string", description: "Incident type (e.g. structure_fire, burglary)" },
      details:    { type: "string", description: "Incident details" }
    },
    required: %w[department incident details]
  })

  attr_writer :center

  def run(args)
    emergency = {
      dept:     args["department"].to_sym,
      incident: args["incident"].to_sym,
      details:  args["details"]
    }
    @center.dispatch(emergency)
    "Dispatched #{args["incident"]} to #{args["department"]}"
  end
end
