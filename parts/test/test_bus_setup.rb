# frozen_string_literal: true

require_relative "test_helper"
require_relative "../bus_setup"

require "async"

class TestBusSetup < Minitest::Test
  def setup
    @bus = TypedBus::MessageBus.new
  end

  def teardown
    @bus.close_all
  end

  def test_configure_adds_all_channels
    BusSetup.configure(@bus)
    BusSetup::CHANNELS.each_key do |name|
      assert @bus.channel?(name), "Expected channel #{name} to exist"
    end
  end

  def test_configure_is_idempotent
    BusSetup.configure(@bus)
    BusSetup.configure(@bus)
    assert @bus.channel?(:incidents)
  end

  def test_channels_hash_is_frozen
    assert BusSetup::CHANNELS.frozen?
  end

  def test_incidents_channel_accepts_incident_report
    BusSetup.configure(@bus)
    received = nil

    Async do
      @bus.subscribe(:incidents) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      msg = IncidentReport.new(
        call_id: 1, department: "Fire", incident: :blaze,
        details: "test", severity: :normal, timestamp: Time.now
      )
      @bus.publish(:incidents, msg)
    end

    assert_instance_of IncidentReport, received
    assert_equal 1, received.call_id
  end

  def test_incidents_channel_rejects_wrong_type
    BusSetup.configure(@bus)

    error = nil
    Async do
      @bus.publish(:incidents, "not an IncidentReport")
    rescue ArgumentError => e
      error = e
    end

    assert_instance_of ArgumentError, error
    assert_includes error.message, "Expected IncidentReport"
  end

  def test_mutual_aid_channel_accepts_mutual_aid_request
    BusSetup.configure(@bus)
    received = nil

    Async do
      @bus.subscribe(:mutual_aid) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      msg = MutualAidRequest.new(
        from_department: "Fire", description: "help",
        priority: :high, call_id: 5
      )
      @bus.publish(:mutual_aid, msg)
    end

    assert_instance_of MutualAidRequest, received
  end

  def test_configure_returns_bus
    result = BusSetup.configure(@bus)
    assert_same @bus, result
  end
end
