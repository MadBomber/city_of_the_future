# frozen_string_literal: true

# Published on the :method_generated channel when a department
# acquires a new handler via self_agency or chaos_to_the_rescue.
# Use this to track the system's learning progress and monitor
# which departments are gaining new capabilities at runtime.
class MethodGenerated < Message
  attribute :department,   Types::Coercible::String.default("Unknown") # name of the department that acquired the method
  attribute :method_name,  Types::Coercible::Symbol                    # symbol name of the generated method
  attribute :scope,        Types::Coercible::Symbol.default(:instance) # :instance or :class
  attribute :source_lines, Types::Coercible::Integer.default(0)        # number of lines in the generated source code
end
