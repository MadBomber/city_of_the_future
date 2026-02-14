# frozen_string_literal: true

require "dry-struct"

module Types
  include Dry.Types()
end

# Base class for all City 911 bus messages.
# Provides coercible types, symbol key transform, and
# automatic defaults for omitted fields.
#
# The bus channel name is derived from the class name:
#   IncidentReport -> :incident_report
#   MutualAidRequest -> :mutual_aid_request
class Message < Dry::Struct
  transform_keys(&:to_sym)

  def self.channel
    name
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .downcase
      .to_sym
  end
end
