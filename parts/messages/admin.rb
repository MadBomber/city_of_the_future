# frozen_string_literal: true

# Published on the :admin channel for directives from city
# leadership to departments. Departments subscribe to this
# channel and act on messages addressed to them or to "all".
class Admin < Message
  attribute :from, Types::Coercible::String.default("Unknown") # sender department or office name
  attribute :to,   Types::Coercible::String.default("all")     # recipient department name or "all" for broadcast
  attribute :body, Types::Coercible::String.default("")         # directive the department must comply with
end
