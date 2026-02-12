# Adds bus integration and learning hooks to department classes.
# When SelfAgency installs a method, on_method_generated publishes
# governance, display, and voice events to the bus.
module SelfAgencyLearner
  def self.included(base)
    base.extend(ClassAccessors)
  end

  module ClassAccessors
    attr_accessor :code_robot, :event_bus
  end

  def on_method_generated(method_name, scope, code)
    bus = self.class.event_bus
    return unless bus

    bus.publish(:display, DisplayEvent.new(
      type:      :method_installed,
      data:      { class: self.class.name, method: method_name.to_s, source: code },
      timestamp: Time.now
    ))

    bus.publish(:governance, PolicyEvent.new(
      action:    "install_method",
      decision:  :approved,
      reason:    "Self-agency validated: passed security and sandbox checks",
      timestamp: Time.now
    ))

    bus.publish(:voice_out, VoiceOut.new(
      text:       "#{self.class.name} has learned: #{method_name}.",
      voice:      nil,
      department: "System",
      priority:   1
    ))
  end
end
