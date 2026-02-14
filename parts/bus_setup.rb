# frozen_string_literal: true

require_relative "messages"

module BusSetup
  MESSAGE_CLASSES = [
    IncidentReport,
    DispatchResult,
    MutualAidRequest,
    ResourceUpdate,
    MethodGenerated,
    Memo,
  ].freeze

  CHANNELS = MESSAGE_CLASSES.each_with_object({}) { |klass, h|
    h[klass.channel] = { type: klass }
  }.freeze

  def self.configure(bus)
    CHANNELS.each do |name, opts|
      bus.add_channel(name, **opts) unless bus.channel?(name)
    end
    bus
  end
end
