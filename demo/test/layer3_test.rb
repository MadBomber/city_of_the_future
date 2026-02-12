require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"
require_relative "../lib/voice/speaker"
require_relative "../lib/voice/listener"

class Layer3Test < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # --- Speaker publishes display event ---

  def test_speaker_publishes_display_event
    speaker = Speaker.new(enabled: false)
    speaker.attach(@bus)

    Async do
      received = nil

      @bus.subscribe(:display) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      @bus.publish(:voice_out, VoiceOut.new(
        text:       "Engine 7 dispatched to 4th and Main",
        voice:      nil,
        department: :dispatch,
        priority:   :normal
      ))

      sleep 0.05

      assert_instance_of DisplayEvent, received
      assert_equal :voice_spoken, received.type
      assert_equal :dispatch, received.data[:department]
      assert_equal "Engine 7 dispatched to 4th and Main", received.data[:text]
      assert_equal "Samantha", received.data[:voice]
    end
  end

  # --- Speaker selects correct voice per department ---

  def test_speaker_selects_correct_voice
    Speaker::VOICES.each do |dept, expected_voice|
      speaker = Speaker.new(enabled: false)
      speaker.attach(@bus)

      Async do
        received = nil

        @bus.subscribe(:display) do |delivery|
          received = delivery.message
          delivery.ack!
        end

        @bus.publish(:voice_out, VoiceOut.new(
          text:       "Test",
          voice:      nil,
          department: dept,
          priority:   :normal
        ))

        sleep 0.05

        assert_equal expected_voice, received.data[:voice],
          "Department :#{dept} should use voice #{expected_voice}"
      end

      @bus.close_all
      @bus = BusSetup.create_bus
    end
  end

  # --- Speaker falls back to system voice ---

  def test_speaker_falls_back_to_system_voice
    speaker = Speaker.new(enabled: false)
    speaker.attach(@bus)

    Async do
      received = nil

      @bus.subscribe(:display) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      @bus.publish(:voice_out, VoiceOut.new(
        text:       "Unknown department",
        voice:      nil,
        department: :unknown_dept,
        priority:   :normal
      ))

      sleep 0.05

      assert_equal "Zarvox", received.data[:voice]
    end
  end

  # --- Speaker handles nil department ---

  def test_speaker_handles_nil_department
    speaker = Speaker.new(enabled: false)
    speaker.attach(@bus)

    Async do
      received = nil

      @bus.subscribe(:display) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      @bus.publish(:voice_out, VoiceOut.new(
        text:       "No department",
        voice:      nil,
        department: nil,
        priority:   :normal
      ))

      sleep 0.05

      assert_equal "Zarvox", received.data[:voice]
    end
  end

  # --- VOICES constant covers expected departments ---

  def test_voices_covers_expected_departments
    expected = %i[dispatch caller fire police ems utilities council citycouncil operations system]
    assert_equal expected.sort, Speaker::VOICES.keys.sort
  end

  # --- Speaker resolves capitalized string department names ---

  def test_speaker_resolves_capitalized_department_names
    mapping = {
      "Fire"        => "Daniel",
      "Police"      => "Karen",
      "EMS"         => "Moira",
      "Utilities"   => "Fred",
      "CityCouncil" => "Flo",
      "Operations"  => "Samantha",
      "System"      => "Zarvox",
    }

    mapping.each do |dept_name, expected_voice|
      speaker = Speaker.new(enabled: false)
      speaker.attach(@bus)

      Async do
        received = nil

        @bus.subscribe(:display) do |delivery|
          received = delivery.message
          delivery.ack!
        end

        @bus.publish(:voice_out, VoiceOut.new(
          text:       "Test",
          voice:      nil,
          department: dept_name,
          priority:   :normal
        ))

        sleep 0.05

        assert_equal expected_voice, received.data[:voice],
          "Department '#{dept_name}' should use voice #{expected_voice}"
      end

      @bus.close_all
      @bus = BusSetup.create_bus
    end
  end

  # --- Listener transcribes and publishes call ---

  def test_listener_transcribes_and_publishes_call
    stub_segment = Struct.new(:text)
    stub_result  = Struct.new(:segments) do
      def each_segment
        segments
      end
    end

    segments = [
      stub_segment.new("There's a fire"),
      stub_segment.new(" on 5th street!")
    ]
    result = stub_result.new(segments)

    fake_whisper = Object.new
    fake_whisper.define_singleton_method(:transcribe) { |_path, _params| result }

    listener = Listener.allocate
    listener.instance_variable_set(:@whisper, fake_whisper)
    listener.instance_variable_set(:@params, Whisper::Params.new(language: "en"))
    listener.instance_variable_set(:@logger, nil)
    listener.attach(@bus)

    Async do
      received = nil

      @bus.subscribe(:calls) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      @bus.publish(:voice_in, VoiceIn.new(
        audio_path:    "/audio/test.wav",
        transcription: nil,
        caller_id:     "caller-042",
        timestamp:     Time.now
      ))

      sleep 0.05

      assert_instance_of EmergencyCall, received
      assert_equal "caller-042", received.caller
      assert_match(/There's a fire.*5th street!/, received.description)
      assert_match(/\AC-[0-9a-f]{8}\z/, received.call_id)
      assert_nil received.location
      assert_nil received.severity
    end
  end
end
