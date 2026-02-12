require "async/semaphore"

class Speaker
  VOICES = {
    dispatch:    "Samantha",
    caller:      "Reed",
    fire:        "Daniel",
    police:      "Karen",
    ems:         "Moira",
    utilities:   "Fred",
    council:     "Flo",
    citycouncil: "Flo",
    operations:  "Samantha",
    system:      "Zarvox"
  }.freeze

  def initialize(logger: nil, enabled: true)
    @logger    = logger
    @enabled   = enabled
    @semaphore = Async::Semaphore.new(1)
  end

  def attach(bus)
    bus.subscribe(:voice_out) do |delivery|
      vout  = delivery.message
      voice = vout.voice || resolve_voice(vout.department)

      @semaphore.acquire do
        if @enabled
          @logger&.info "Speaking [#{voice}]: #{vout.text}"
          pid = spawn("say", "-v", voice, vout.text)
          Process.wait(pid)
        else
          @logger&.info "Speaker disabled, skipping [#{voice}]: #{vout.text}"
        end
      end

      bus.publish(:display, DisplayEvent.new(
        type:      :voice_spoken,
        data:      { department: vout.department, text: vout.text, voice: voice },
        timestamp: Time.now
      ))

      delivery.ack!
    end
  end

  private

  def resolve_voice(department)
    key = department.to_s.downcase.to_sym
    VOICES[key] || VOICES[:system]
  end
end
