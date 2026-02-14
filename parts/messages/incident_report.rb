# frozen_string_literal: true

# Published on the :incidents channel when a 911 call is received
# and dispatched to a department. Allows bus subscribers to track
# incoming emergencies in real time before a handler runs.
class IncidentReport < Message
  attribute :call_id,    Types::Coercible::Integer.default(0)    # unique identifier for the 911 call
  attribute :department, Types::Coercible::String.default("Unknown") # name of the responding department
  attribute :incident,   Types::Coercible::Symbol                # type of incident (e.g. :structure_fire, :burglary)
  attribute :details,    Types::Coercible::String.default("")    # free-text description of the situation
  attribute :severity,   Types::Coercible::Symbol.default(:normal) # priority level (:normal, :critical, etc.)
  attribute :timestamp,  Types::Strict::Time.default { Time.now } # Time when the incident was reported
end
