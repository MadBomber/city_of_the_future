# frozen_string_literal: true

# Published on the :dispatch_results channel after a department
# handler finishes processing an emergency. Use this to monitor
# handler performance, track newly generated methods, and log
# completed dispatches.
class DispatchResult < Message
  attribute :call_id,    Types::Coercible::Integer.default(0)        # unique identifier for the 911 call
  attribute :department, Types::Coercible::String.default("Unknown") # name of the department that handled the call
  attribute :handler,    Types::Coercible::Symbol                    # handler method invoked (e.g. :handle_structure_fire)
  attribute :result,     Types::Coercible::String.default("")        # truncated string of the handler's return value
  attribute :was_new,    Types::Params::Bool.default(false)          # true if the method was generated on the fly
  attribute :elapsed,    Types::Coercible::Float.default(0.0)        # seconds taken to execute the handler
end
