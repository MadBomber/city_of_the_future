require "whisper"

class Listener
  def initialize(model: "base.en", logger: nil)
    @whisper = Whisper::Context.new(model)
    @params  = Whisper::Params.new(language: "en")
    @logger  = logger
  end

  def attach(bus)
    bus.subscribe(:voice_in) do |delivery|
      vin = delivery.message

      @logger&.info "Transcribing #{vin.audio_path}..."
      text = transcribe(vin.audio_path)
      @logger&.info "Transcription: #{text}"

      bus.publish(:calls, EmergencyCall.new(
        call_id:     "C-#{SecureRandom.hex(4)}",
        caller:      vin.caller_id,
        location:    nil,
        description: text,
        severity:    nil,
        timestamp:   Time.now
      ))

      delivery.ack!
    end
  end

  private

  def transcribe(audio_path)
    result = @whisper.transcribe(audio_path, @params)
    result.each_segment.map(&:text).join(" ").strip
  end
end
