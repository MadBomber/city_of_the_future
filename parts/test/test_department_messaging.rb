# frozen_string_literal: true

require_relative "test_helper"
require "async"

class TestDepartmentMessaging < Minitest::Test
  def setup
    @dept = Department.new(name: "TestDept")
  end

  def teardown
    @dept.bus.close_all
  end

  def test_add_channel
    @dept.add_channel(:alerts, type: String, timeout: 5)
    assert @dept.bus.channel?(:alerts)
  end

  def test_publish_and_subscribe
    received = nil

    Async do
      @dept.add_channel(:alerts, type: String, timeout: 5)
      @dept.subscribe(:alerts) do |delivery|
        received = delivery.message
        delivery.ack!
      end
      @dept.publish(:alerts, "fire on 5th street")
    end

    assert_equal "fire on 5th street", received
  end

  def test_dead_letters_accessible
    @dept.add_channel(:alerts, type: String, timeout: 1)
    assert_instance_of TypedBus::DeadLetterQueue, @dept.dead_letters(:alerts)
  end

  def test_broadcast_and_listen_on_shared_bus
    received = nil
    channel  = :"test_broadcast_#{object_id}"

    Async do
      Department.shared_bus.add_channel(channel, type: String, timeout: 5)
      @dept.listen(channel) do |delivery|
        received = delivery.message
        delivery.ack!
      end
      @dept.broadcast(channel, "mutual aid request")
    end

    assert_equal "mutual aid request", received
  ensure
    Department.shared_bus.remove_channel(channel) if Department.shared_bus.channel?(channel)
  end

  def test_inter_department_communication
    fire_class   = Department.dup
    police_class = Department.dup

    fire   = fire_class.new(name: "Fire")
    police = police_class.new(name: "Police")

    received = nil
    channel  = :"inter_dept_#{object_id}"

    Async do
      Department.shared_bus.add_channel(channel, type: String, timeout: 5)
      police.listen(channel) do |delivery|
        received = delivery.message
        delivery.ack!
      end
      fire.broadcast(channel, "need crowd control at 3rd & Oak")
    end

    assert_equal "need crowd control at 3rd & Oak", received
  ensure
    Department.shared_bus.remove_channel(channel) if Department.shared_bus.channel?(channel)
  end
end
