require "bundler/setup"
require "minitest/autorun"
require "async"

require_relative "../lib/bus_setup"

class Layer1Test < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # --- Channel registration ---

  def test_all_channels_registered
    expected = BusSetup::CHANNELS.keys
    assert_equal expected.sort, @bus.channel_names.sort
  end

  # --- Message type factories ---

  def sample_messages
    {
      calls:             EmergencyCall.new(
                           call_id: "C-001", caller: "Jane Doe",
                           location: "4th & Main", description: "Structure fire",
                           severity: :high, timestamp: Time.now
                         ),
      dispatch:          DispatchOrder.new(
                           call_id: "C-001", department: :fire,
                           units_requested: 2, priority: :urgent,
                           eta: 240
                         ),
      department_status: DeptStatus.new(
                           department: :fire, available_units: 3,
                           active_calls: 2, capacity_pct: 0.6
                         ),
      field_reports:     FieldReport.new(
                           call_id: "C-001", department: :fire,
                           unit_id: "E7", status: :on_scene,
                           notes: "Two-alarm fire", timestamp: Time.now
                         ),
      escalation:        Escalation.new(
                           call_id: "C-005", reason: "No department available",
                           original_call: "Drone swarm downtown",
                           attempted_departments: [:police, :fire],
                           timestamp: Time.now
                         ),
      llm_requests:      LLMRequest.new(
                           prompt: "Classify this emergency",
                           tools: nil, model: "claude-sonnet-4-5",
                           correlation_id: "req-001"
                         ),
      llm_responses:     LLMResponse.new(
                           content: '{"category":"fire"}',
                           tool_calls: nil, tokens: 150,
                           correlation_id: "req-001"
                         ),
      method_gen:        MethodGen.new(
                           target_class: "FireDepartment",
                           method_name: "handle_drone_swarm",
                           source_code: "def handle_drone_swarm; end",
                           status: :pending
                         ),
      governance:        PolicyEvent.new(
                           action: "install_method",
                           decision: :approved, reason: "Matches allow pattern",
                           timestamp: Time.now
                         ),
      voice_in:          VoiceIn.new(
                           audio_path: "/audio/caller_1.wav",
                           transcription: "There's a fire!",
                           caller_id: "caller-001",
                           timestamp: Time.now
                         ),
      voice_out:         VoiceOut.new(
                           text: "Engine 7 dispatched",
                           voice: "Samantha", department: :dispatch,
                           priority: :normal
                         ),
      display:           DisplayEvent.new(
                           type: :call_received,
                           data: { call_id: "C-001" },
                           timestamp: Time.now
                         ),
    }
  end

  # --- Typed channels accept correct messages ---

  def test_channels_accept_correct_types
    messages = sample_messages

    Async do
      messages.each do |channel_name, message|
        received = nil

        @bus.subscribe(channel_name) do |delivery|
          received = delivery.message
          delivery.ack!
        end

        @bus.publish(channel_name, message)

        # Give the async reactor a chance to deliver
        sleep 0.01

        assert_equal message, received,
          "Channel :#{channel_name} should deliver #{message.class}"
      end
    end
  end

  # --- Typed channels reject wrong types ---

  def test_channels_reject_wrong_types
    wrong_message = "this is a plain string"

    BusSetup::CHANNELS.each_key do |channel_name|
      assert_raises(ArgumentError, "Channel :#{channel_name} should reject String") do
        Async do
          @bus.publish(channel_name, wrong_message)
        end.wait
      end
    end
  end

  # --- Pub/sub round-trip with ACK ---

  def test_pubsub_roundtrip_with_ack
    Async do
      received = nil
      acked = false

      @bus.subscribe(:calls) do |delivery|
        received = delivery.message
        delivery.ack!
        acked = true
      end

      call = EmergencyCall.new(
        call_id: "C-100", caller: "Test",
        location: "123 Test St", description: "Test emergency",
        severity: :low, timestamp: Time.now
      )

      @bus.publish(:calls, call)
      sleep 0.01

      assert_equal call, received
      assert acked, "Delivery should be ACKed"
    end
  end

  # --- Stats tracking ---

  def test_stats_increment_on_publish
    Async do
      @bus.subscribe(:calls) do |delivery|
        delivery.ack!
      end

      call = EmergencyCall.new(
        call_id: "C-200", caller: "Stats Test",
        location: "456 Stat Ave", description: "Stats test",
        severity: :medium, timestamp: Time.now
      )

      @bus.publish(:calls, call)
      sleep 0.01

      assert_equal 1, @bus.stats[:calls_published]
      assert_equal 1, @bus.stats[:calls_delivered]
    end
  end

  # --- DLQ catches NACKed deliveries ---

  def test_dlq_catches_nacked_deliveries
    Async do
      @bus.subscribe(:calls) do |delivery|
        delivery.nack!
      end

      call = EmergencyCall.new(
        call_id: "C-300", caller: "DLQ Test",
        location: "789 Dead Letter Ln", description: "Will be NACKed",
        severity: :high, timestamp: Time.now
      )

      @bus.publish(:calls, call)
      sleep 0.01

      dlq = @bus.dead_letters(:calls)
      refute dlq.empty?, "DLQ should contain the NACKed delivery"
      assert_equal 1, @bus.stats[:calls_nacked]
    end
  end

  # --- Message immutability ---

  def test_messages_are_frozen
    call = EmergencyCall.new(
      call_id: "C-400", caller: "Freeze Test",
      location: "Frozen St", description: "Immutable",
      severity: :critical, timestamp: Time.now
    )

    assert call.frozen?, "Data objects should be frozen"
  end
end
