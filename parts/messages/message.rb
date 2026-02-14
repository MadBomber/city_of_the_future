# frozen_string_literal: true

require "dry-struct"

module Types
  include Dry.Types()
end

# Base class for all City 911 bus messages.
# Provides coercible types, symbol key transform, and
# automatic defaults for omitted fields.
class Message < Dry::Struct
  transform_keys(&:to_sym)
end
