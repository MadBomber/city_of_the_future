# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A RubyConf 2026 conference demo: a simulated 911 emergency dispatch system that demonstrates Viable Systems Model (VSM) principles using a typed message bus, LLM-powered call classification, text-to-speech, a live web dashboard, and runtime code generation (self-agency/autonomy).

## Commands

```bash
# Run all tests
bundle exec rake test

# Run tests by VSM layer
bundle exec rake test:layer1    # TypedBus channels & message types
bundle exec rake test:layer2    # (if exists)
bundle exec rake test:layer3    # (if exists)
bundle exec rake test:layer4    # Autonomy: CodeExtractor, Governance, ChaosBridge, SelfAgencyBridge
bundle exec rake test:layer5    # Departments, Intelligence, Operations
bundle exec rake test:integration
bundle exec rake test:scenario
bundle exec rake test:dashboard
bundle exec rake test:replay_robot
bundle exec rake test:autonomy_integration

# Run a single test file
bundle exec ruby -Ilib:test test/layer5_test.rb

# Run a single test method
bundle exec ruby -Ilib:test test/layer5_test.rb -n test_fire_department_handles_fire

# Demo lifecycle
rake start                    # Start demo (replay mode by default)
rake start REPLAY=1           # Start with scenario player
rake start VOICE=off          # Start with TTS disabled
rake start LLM_MODE=live      # Use real LLM API calls
rake stop
rake restart
rake status
```

## Architecture

### Threading Model

Single Ruby process, two threads:

- **Main thread** — runs an `Async` fiber reactor hosting the message bus, all VSM components (Intelligence, Operations, Governance), the autonomy pipeline (ChaosBridge, SelfAgencyBridge), voice output (Speaker), and the scenario player. All bus subscriptions and publishes happen here.
- **Web thread** — `Thread.new` in `bin/demo` runs Sinatra/Puma for the dashboard. Communicates with the main thread via `DisplayBridge` (Mutex-protected event buffer) and a `Thread::Queue` for live calls submitted through `POST /calls`.

### Message Bus (TypedBus)

The entire system communicates through a `TypedBus::MessageBus` with 12 typed channels defined in `lib/bus_setup.rb`. Every message type is a `Data.define` struct in `lib/messages/`. All components `attach(bus)` to subscribe/publish, using `delivery.ack!` / `delivery.nack!` for acknowledgment. NACKed messages go to per-channel dead letter queues.

### VSM Layers (mapped to the demo)

- **Layer 5 (Policy/Identity)**: `lib/vsm/intelligence.rb` — classifies emergency calls via LLM, publishes `DispatchOrder`. `lib/vsm/operations.rb` — routes dispatch orders to departments, handles unit exhaustion (budget requests), escalates unknowns.
- **Layer 4 (Autonomy)**: `lib/autonomy/` — runtime code generation. `ChaosBridge` intercepts `method_missing` on department classes, asks a robot (LLM/replay) to generate the missing method, publishes `MethodGen`. `Governance` validates generated code against an allowlist and dangerous-pattern blocklist before `class_eval` installation. `SelfAgencyBridge` handles escalations by using the `self_agency` gem's `_()` method to learn new capabilities on `CityCouncil`.
- **Layer 1 (Operations)**: `lib/departments/` — `BaseDepartment` with unit tracking. Concrete: `FireDepartment`, `PoliceDepartment`, `EMS`, `Utilities`, `CityCouncil`. Each includes `SelfAgency`, `SelfAgencyReplay`, and `SelfAgencyLearner` modules.

### LLM Modes (`lib/llm_mode.rb`)

Three modes controlled by `LLM_MODE` env var:
- `replay` (default) — `ScenarioDriver` plays back pre-recorded responses from `scenarios/demo.jsonl`
- `live` — `LiveHandler` uses `ruby_llm` gem for real API calls (falls back to keyword classification)
- `record` — `ScenarioRecorder` captures live responses to JSONL

The autonomy layer always uses `ReplayRobot` (YAML pattern-matched responses from `scenarios/demo_robot.yml`), independent of the LLM mode.

### Scenario Player

`lib/scenario/player.rb` reads `scenarios/demo_calls.yml` (phased YAML), publishes `EmergencyCall` messages with timing delays, and uses macOS `say` voices per caller.

### Web Dashboard

`web/app.rb` (Sinatra/Puma on port 4567). `DisplayBridge` aggregates events from multiple bus channels. SSE endpoint at `/events`, POST `/calls` for live input, GET `/stats` for bus statistics.

### Key Dependencies

- `typed_bus` — typed message bus with channels, DLQ, stats
- `self_agency` — runtime method generation via LLM (SelfAgency mixin, `_()` method)
- `ruby_llm` / `ruby_llm-mcp` — LLM API client (used in live mode)
- `robot_lab` — local gem at `../../robot_lab` (ReplayRobot pattern)
- `async` — concurrent execution (Async do blocks throughout)
- `whispercpp` — speech-to-text
- `sinatra` / `puma` — web dashboard

### Message Flow

```
EmergencyCall → :calls → Intelligence → :llm_requests → LLM handler
                                     ← :llm_responses ←
                         Intelligence → :dispatch → Operations → :field_reports
                                                              → :department_status
                                                              → :voice_out (TTS)
                                                              → :escalation (if no dept)
                         :escalation → SelfAgencyBridge → _() → :method_installed
                         :method_missing → ChaosBridge → Robot → :method_gen → Governance → install
```

### Test Organization

Tests mirror VSM layers. All use Minitest with `Async do` blocks. The `skip_delays: true` option on `ScenarioPlayer` is used in tests. Tests create/destroy temporary constants (e.g., `GovTestTarget`) with `Object.const_set`/`remove_const` in ensure blocks.

### Messages Directory Convention

All `Data.define` message structs live in `lib/messages/`. Auto-loaded by `lib/messages.rb` via `Dir.glob`.

### Department Class Pattern

Department classes inherit `BaseDepartment`, include `SelfAgency`, `SelfAgencyReplay`, `SelfAgencyLearner`. Class-level accessors `code_robot` and `event_bus` are set at boot in `bin/demo`.
