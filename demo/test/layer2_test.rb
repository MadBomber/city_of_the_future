require "bundler/setup"
require "minitest/autorun"
require "async"
require "tempfile"
require "json"

require_relative "../lib/bus_setup"
require_relative "../lib/llm_mode"

class Layer2Test < Minitest::Test
  def setup
    @bus = BusSetup.create_bus
  end

  def teardown
    @bus.close_all
  end

  # --- Replay delivers recorded response ---

  def test_replay_delivers_recorded_response
    jsonl = Tempfile.new(["scenario", ".jsonl"])
    record = {
      seq: 1,
      timestamp: Time.now.iso8601(3),
      correlation_id: "req-replay-1",
      request: { prompt: "Classify this call", tools: nil, model: "claude-sonnet-4-5" },
      response: {
        content: '{"category":"fire","severity":"high"}',
        tool_calls: nil,
        tokens: 200
      },
      elapsed_seconds: 0.01
    }
    jsonl.puts(JSON.generate(record))
    jsonl.flush

    driver = ScenarioDriver.new(jsonl.path)

    Async do
      received = nil

      @bus.subscribe(:llm_responses) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      driver.attach(@bus)

      @bus.publish(:llm_requests, LLMRequest.new(
        prompt: "Classify this call",
        tools: nil,
        model: "claude-sonnet-4-5",
        correlation_id: "req-replay-1"
      ))

      sleep 0.05

      assert_equal '{"category":"fire","severity":"high"}', received.content
      assert_equal 200, received.tokens
      assert_equal "req-replay-1", received.correlation_id
    end
  ensure
    jsonl&.close
    jsonl&.unlink
  end

  # --- Replay handles missing correlation_id ---

  def test_replay_handles_missing_correlation_id
    jsonl = Tempfile.new(["scenario", ".jsonl"])
    record = {
      seq: 1,
      timestamp: Time.now.iso8601(3),
      correlation_id: "req-exists",
      request: { prompt: "Hello", tools: nil, model: "claude-sonnet-4-5" },
      response: { content: "Hi", tool_calls: nil, tokens: 10 },
      elapsed_seconds: 0.01
    }
    jsonl.puts(JSON.generate(record))
    jsonl.flush

    driver = ScenarioDriver.new(jsonl.path)

    Async do
      received = nil

      @bus.subscribe(:llm_responses) do |delivery|
        received = delivery.message
        delivery.ack!
      end

      driver.attach(@bus)

      @bus.publish(:llm_requests, LLMRequest.new(
        prompt: "Unknown request",
        tools: nil,
        model: "claude-sonnet-4-5",
        correlation_id: "req-missing"
      ))

      sleep 0.05

      assert_match(/department/, received.content)
      assert_equal 0, received.tokens
      assert_equal "req-missing", received.correlation_id
    end
  ensure
    jsonl&.close
    jsonl&.unlink
  end

  # --- JSONL round-trip ---

  def test_jsonl_roundtrip
    jsonl = Tempfile.new(["roundtrip", ".jsonl"])

    records = [
      {
        seq: 1, timestamp: Time.now.iso8601(3),
        correlation_id: "rt-1",
        request: { prompt: "First", tools: nil, model: "gpt-4" },
        response: { content: "Response 1", tool_calls: nil, tokens: 100 },
        elapsed_seconds: 0.01
      },
      {
        seq: 2, timestamp: Time.now.iso8601(3),
        correlation_id: "rt-2",
        request: { prompt: "Second", tools: nil, model: "gpt-4" },
        response: { content: "Response 2", tool_calls: nil, tokens: 150 },
        elapsed_seconds: 0.01
      }
    ]

    records.each { |r| jsonl.puts(JSON.generate(r)) }
    jsonl.flush

    driver = ScenarioDriver.new(jsonl.path)

    Async do
      responses = []

      @bus.subscribe(:llm_responses) do |delivery|
        responses << delivery.message
        delivery.ack!
      end

      driver.attach(@bus)

      @bus.publish(:llm_requests, LLMRequest.new(
        prompt: "First", tools: nil, model: "gpt-4", correlation_id: "rt-1"
      ))
      sleep 0.05

      @bus.publish(:llm_requests, LLMRequest.new(
        prompt: "Second", tools: nil, model: "gpt-4", correlation_id: "rt-2"
      ))
      sleep 0.05

      assert_equal 2, responses.size
      assert_equal "Response 1", responses[0].content
      assert_equal "rt-1", responses[0].correlation_id
      assert_equal "Response 2", responses[1].content
      assert_equal "rt-2", responses[1].correlation_id
    end
  ensure
    jsonl&.close
    jsonl&.unlink
  end

  # --- LLMMode rejects invalid mode ---

  def test_llm_mode_rejects_invalid_mode
    assert_raises(ArgumentError) do
      LLMMode.setup(@bus, mode: "turbo")
    end
  end

  # --- LLMMode selects correct handler class ---

  def test_llm_mode_selects_live_handler
    handler = LLMMode.setup(@bus, mode: "live")
    assert_instance_of LiveHandler, handler
  end

  def test_llm_mode_selects_scenario_recorder
    jsonl = Tempfile.new(["record", ".jsonl"])
    handler = LLMMode.setup(@bus, mode: "record", scenario_path: jsonl.path)
    assert_instance_of ScenarioRecorder, handler
    handler.close
  ensure
    jsonl&.close
    jsonl&.unlink
  end

  def test_llm_mode_selects_scenario_driver
    jsonl = Tempfile.new(["replay", ".jsonl"])
    jsonl.flush
    handler = LLMMode.setup(@bus, mode: "replay", scenario_path: jsonl.path)
    assert_instance_of ScenarioDriver, handler
  ensure
    jsonl&.close
    jsonl&.unlink
  end
end
