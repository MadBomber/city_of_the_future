require "yaml"

class ScenarioPlayer
  attr_reader :calls_played

  def initialize(scenario_path:, logger: nil, skip_delays: false)
    @scenario    = YAML.load_file(scenario_path, permitted_classes: [Symbol])
    @logger      = logger
    @skip_delays = skip_delays
    @phase_callback = nil
    @calls_played   = 0
  end

  def on_phase(&block)
    @phase_callback = block
  end

  def attach(bus)
    @bus = bus
  end

  def play
    @scenario["phases"].each do |phase|
      play_phase(phase)
    end

    @logger&.info "ScenarioPlayer: === Scenario complete (#{@calls_played} calls) ==="
  end

  def play_phase(phase)
    wait(phase["delay_before"] || 0)

    phase_name = phase["name"]
    @logger&.info "ScenarioPlayer: === Phase: #{phase_name} ==="
    @phase_callback&.call(phase_name)

    @bus.publish(:display, DisplayEvent.new(
      type:      :phase_change,
      data:      { phase: phase_name },
      timestamp: Time.now
    ))

    @bus.publish(:voice_out, VoiceOut.new(
      text:       "Phase: #{phase_name}",
      voice:      nil,
      department: "System",
      priority:   1
    ))

    phase["calls"].each do |call_data|
      wait(call_data["delay"] || 0)
      publish_call(call_data)
    end
  end

  def build_call(call_data)
    EmergencyCall.new(
      call_id:     call_data["call_id"],
      caller:      call_data["caller"],
      location:    call_data["location"],
      description: call_data["description"],
      severity:    call_data["severity"]&.to_sym,
      timestamp:   Time.now
    )
  end

  private

  def publish_call(call_data)
    call = build_call(call_data)
    @logger&.info "ScenarioPlayer: [#{call.call_id}] #{call.caller} — #{call.description[0..60]}"
    @bus.publish(:calls, call)
    @calls_played += 1
  end

  def wait(seconds)
    return if @skip_delays || seconds <= 0
    sleep seconds
  end
end
