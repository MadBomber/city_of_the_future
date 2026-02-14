# frozen_string_literal: true

# Published on the :resource_updates channel when a department's
# resource availability changes. Use this to maintain a city-wide
# view of capacity so dispatch decisions can account for which
# departments have units available.
class ResourceUpdate < Message
  attribute :department,    Types::Coercible::String.default("Unknown") # name of the department reporting resources
  attribute :resource_type, Types::Coercible::Symbol                    # kind of resource (e.g. :engines, :personnel)
  attribute :available,     Types::Coercible::Integer.default(0)        # number of units currently available
  attribute :total,         Types::Coercible::Integer.default(0)        # total number of units in the department
end
