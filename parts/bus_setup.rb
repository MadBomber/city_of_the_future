# frozen_string_literal: true

require_relative "messages"

module BusSetup
  CHANNELS = {
    incidents:        { type: IncidentReport },
    dispatch_results: { type: DispatchResult },
    mutual_aid:       { type: MutualAidRequest },
    resources:        { type: ResourceUpdate },
    method_generated: { type: MethodGenerated },
  }.freeze

  def self.configure(bus)
    CHANNELS.each do |name, opts|
      bus.add_channel(name, **opts) unless bus.channel?(name)
    end
    bus
  end
end
