# frozen_string_literal: true

# Published on the :mutual_aid channel when a department needs
# assistance from other departments. Subscribers receive this
# to decide whether they can contribute resources to help with
# a large-scale or multi-department incident.
class MutualAidRequest < Message
  attribute :from_department, Types::Coercible::String.default("Unknown") # name of the department requesting assistance
  attribute :description,     Types::Coercible::String.default("")        # free-text explanation of what help is needed
  attribute :priority,        Types::Coercible::Symbol.default(:normal)   # urgency level (:critical, :high, :normal)
  attribute :call_id,         Types::Coercible::Integer.default(0)        # associated 911 call identifier
end
