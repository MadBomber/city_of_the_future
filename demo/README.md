# Giving Robots Free Will — City 911 Simulation

A live conference demo for [RubyConf 2026](https://rubyconf.org) (July 14-16, Las Vegas) that simulates a city 911 emergency dispatch system. Emergency calls arrive, an LLM classifies and routes them to departments, and when no department can handle a novel emergency, the system writes new Ruby methods at runtime and extends its own capabilities — all governed by safety checks.

The demo illustrates [Stafford Beer's Viable System Model](https://en.wikipedia.org/wiki/Viable_system_model) (VSM) using Ruby's dynamic runtime: `method_missing`, `define_method`, `class_eval`, and the [self_agency](https://github.com/madbomber/self_agency) gem for autonomous method generation.

## What the Audience Sees

A browser dashboard at `http://localhost:4567` with a city map, active calls, department status bars, a live event stream, governance stats, and `typed_bus` throughput counters. Distinct macOS voices speak each role — callers, dispatch, fire, police, EMS, and a robotic voice for system announcements. The demo runs through four phases:

1. **Normal Operations** — routine emergencies routed to Fire, Police, EMS, and Utilities
2. **Stress** — departments hit capacity, budget requests escalate to City Council
3. **The Unknown** — a drone swarm arrives with no department to handle it; the system escalates
4. **Adaptation** — `self_agency` generates a `coordinate_*` method on `CityCouncil` at runtime; governance approves it; the second drone call is handled by the new capability

## Prerequisites

- Ruby >= 3.2
- macOS (uses the built-in `say` command for text-to-speech)
- Bundler

## Quick Start

```bash
bundle install

# Run the demo in replay mode (no API keys needed)
rake start REPLAY=1

# Open the dashboard
open http://localhost:4567

# Watch the log
tail -f log/demo.log

# Stop the demo
rake stop
```

## Running Modes

The demo supports three LLM modes, controlled by the `LLM_MODE` environment variable:

| Mode | Command | What It Does |
|------|---------|--------------|
| `replay` (default) | `rake start` | Plays back pre-recorded LLM responses from `scenarios/demo.jsonl`. No network required. |
| `live` | `rake start LLM_MODE=live` | Makes real LLM API calls via `ruby_llm`. Requires API keys configured for your provider. Falls back to keyword classification on failure. |
| `record` | `rake start LLM_MODE=record` | Runs live LLM calls and records every request/response pair to JSONL for future replay. |

### Options

| Flag / Variable | Effect |
|-----------------|--------|
| `REPLAY=1` | Enables the scenario player (phased call sequence from `scenarios/demo_calls.yml`) |
| `VOICE=off` | Disables text-to-speech output |
| `SCENARIO_PATH=path` | Custom JSONL scenario file for the LLM driver |
| `DEMO_CALLS=path` | Custom YAML call sequence for the scenario player |
| `DASHBOARD_PORT=9292` | Change the dashboard port (default: 4567) |

## Running Tests

```bash
# All tests
bundle exec rake test

# By VSM layer
bundle exec rake test:layer1          # TypedBus channels and message types
bundle exec rake test:layer5          # Departments, Intelligence, Operations
bundle exec rake test:layer4          # Autonomy: Governance, ChaosBridge, SelfAgencyBridge
bundle exec rake test:integration     # Full pipeline: scenario replay through dispatch

# Single test file
bundle exec ruby -Ilib:test test/layer5_test.rb

# Single test method
bundle exec ruby -Ilib:test test/layer5_test.rb -n test_fire_department_handles_fire
```

## Architecture

### Threading Model

The demo runs as a single Ruby process with two threads:

- **Main thread** — runs an `Async` fiber reactor that hosts the message bus, all VSM components (Intelligence, Operations, Governance), the autonomy pipeline (ChaosBridge, SelfAgencyBridge), voice output (Speaker), and the scenario player. All bus subscriptions and publishes happen here.
- **Web thread** — runs Sinatra/Puma serving the dashboard. Communicates with the main thread through `DisplayBridge` (thread-safe with a `Mutex`) and a `Thread::Queue` for live calls submitted via `POST /calls`.

### Message Bus

All components communicate through a single `TypedBus::MessageBus` with 12 typed channels. Each channel enforces a specific `Data.define` message struct. Messages are immutable. Subscribers call `delivery.ack!` or `delivery.nack!`; NACKed messages go to per-channel dead letter queues.

```
EmergencyCall → :calls → Intelligence ──→ :llm_requests → LLM handler
                                      ←── :llm_responses ←
                         Intelligence ──→ :dispatch → Operations → :field_reports
                                                                → :department_status
                                                                → :voice_out (TTS)
                                                                → :escalation (unknown dept)
                         :escalation → SelfAgencyBridge → self_agency._() → new method installed
                         :method_missing → ChaosBridge → Robot → :method_gen → Governance → class_eval
```

### Channels

| Channel | Message Type | Purpose |
|---------|-------------|---------|
| `:calls` | `EmergencyCall` | Incoming 911 calls |
| `:dispatch` | `DispatchOrder` | Routing decisions from Intelligence |
| `:department_status` | `DeptStatus` | Department capacity and active units |
| `:field_reports` | `FieldReport` | Updates from responding units |
| `:escalation` | `Escalation` | Emergencies no department can handle |
| `:llm_requests` | `LLMRequest` | Outbound LLM classification prompts |
| `:llm_responses` | `LLMResponse` | Inbound LLM results |
| `:method_gen` | `MethodGen` | Generated code awaiting governance review |
| `:governance` | `PolicyEvent` | Approval or rejection of generated methods |
| `:voice_in` | `VoiceIn` | Audio transcriptions |
| `:voice_out` | `VoiceOut` | Text to be spoken aloud |
| `:display` | `DisplayEvent` | All events forwarded to the dashboard |

### VSM Mapping

| VSM System | Implementation | Role |
|------------|---------------|------|
| **Intelligence** (System 4) | `lib/vsm/intelligence.rb` | Classifies calls via LLM, publishes dispatch orders |
| **Operations** (System 1) | `lib/vsm/operations.rb` + `lib/departments/` | Routes dispatches to departments, manages unit allocation |
| **Governance** (System 5) | `lib/autonomy/governance.rb` | Validates LLM-generated code against allowlists and dangerous-pattern blocklist |
| **Autonomy** (System 3/4) | `lib/autonomy/chaos_bridge.rb`, `self_agency_bridge.rb` | Reactive (`method_missing`) and proactive (escalation) code generation |

### Departments

Five departments inherit from `BaseDepartment`, each with a unit pool, type handles, and capacity tracking:

| Department | Prefix | Units | Handles |
|------------|--------|-------|---------|
| Fire | E- | 5 | `:fire`, `:structure_fire`, `:wildfire` |
| Police | U- | 4 | `:police`, `:robbery`, `:assault`, ... |
| EMS | M- | 3 | `:ems`, `:cardiac`, `:trauma`, ... |
| Utilities | UT- | 2 | `:utilities`, `:gas_leak`, `:water_main`, ... |
| CityCouncil | CC- | 1 | (none — receives escalations) |

All department classes include `SelfAgency`, `SelfAgencyReplay`, and `SelfAgencyLearner`, enabling runtime method generation through the `_()` interface.

### Autonomy Pipeline

When a call arrives that no department can handle:

1. **Operations** escalates to the `:escalation` channel
2. **SelfAgencyBridge** receives the escalation, calls `CityCouncil.new._(description)` to generate a `coordinate_*` method
3. **SelfAgencyReplay** routes the generation through `ReplayRobot` (pattern-matched YAML responses) instead of a live LLM
4. **SelfAgencyLearner** publishes `:method_installed` and `:governance` events to the bus
5. The bridge retries the escalated call using the newly installed method

When a department receives a call for a method it doesn't have:

1. **ChaosBridge** intercepts `method_missing`, asks a robot to generate the method
2. **CodeExtractor** extracts `def...end` from the response
3. The generated code is published to `:method_gen`
4. **Governance** validates: class on allowlist? No dangerous patterns (`system`, `eval`, `File`, etc.)?
5. If approved, the method is installed via `class_eval`; if rejected, it goes to the dead letter queue

### Web Dashboard

A Sinatra app served by Puma on port 4567. `DisplayBridge` aggregates events from six bus channels into a thread-safe event buffer. The browser connects via Server-Sent Events (`GET /events`) for real-time updates.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Dashboard HTML |
| `/events` | GET | SSE stream of all bus events |
| `/calls` | POST | Submit a live emergency call (JSON body: `caller`, `location`, `description`, `severity`) |
| `/stats` | GET | Per-channel published/delivered/nacked/DLQ counts |

### Voice

Each role has a distinct macOS voice assigned in `lib/voice/speaker.rb`:

| Role | Voice |
|------|-------|
| Dispatch | Samantha |
| Fire | Daniel |
| Police | Karen |
| EMS | Moira |
| Utilities | Fred |
| City Council | Flo |
| System | Zarvox |

Callers cycle through: Rishi, Tessa, Kathy, Ralph, Junior, Tara, Aman, Reed, Albert.

### Scenario Files

| File | Format | Purpose |
|------|--------|---------|
| `scenarios/demo_calls.yml` | YAML | Phased emergency call sequence (4 phases, 9 calls) |
| `scenarios/demo.jsonl` | JSONL | Pre-recorded LLM responses keyed by `correlation_id` |
| `scenarios/demo_robot.yml` | YAML | Pattern-matched code generation responses for `ReplayRobot` |

## Main Classes

### Bus and Setup

**`BusSetup`** (`lib/bus_setup.rb`) — Module that creates and configures the `TypedBus::MessageBus`. Defines all 12 channels in a `CHANNELS` hash mapping channel names to their message type and options (e.g., `max_pending: 5` for `:llm_requests`, `timeout: 10` for `:voice_out`). The `create_bus` class method instantiates the bus, registers every channel, and wires a dead letter queue callback on each that logs timeouts and NACKs. This is the first thing `bin/demo` loads; every other component receives the bus it creates.

**`LLMMode`** (`lib/llm_mode.rb`) — Module that selects and attaches the correct LLM handler to the bus based on the `LLM_MODE` environment variable. Its `setup` class method accepts a mode string (`"live"`, `"record"`, or `"replay"`) and returns the attached handler. This is the switchboard that makes the demo work identically whether hitting a real API or playing back recorded responses.

### Message Types (`lib/messages/`)

All message types are immutable `Data.define` structs, auto-loaded by `lib/messages.rb` via `Dir.glob`. They serve as the typed contracts enforced by each bus channel.

**`EmergencyCall`** — Represents an incoming 911 call. Fields: `call_id`, `caller`, `location`, `description`, `severity` (symbol: `:low`, `:medium`, `:high`, `:critical`), `timestamp`. Published to `:calls` by the ScenarioPlayer (replay mode) or the dashboard (live input). Consumed by Intelligence for classification and by DisplayBridge for the dashboard.

**`DispatchOrder`** — A routing decision from Intelligence to Operations. Fields: `call_id`, `department` (string like `"fire"` or `"unknown"`), `units_requested` (integer), `priority`, `eta`, `description` (optional, defaults to `nil`). Published to `:dispatch` after the LLM classifies a call. Consumed by Operations to find and dispatch the matching department.

**`DeptStatus`** — A snapshot of a department's current capacity. Fields: `department` (name string), `available_units`, `active_calls`, `capacity_pct` (float 0.0–1.0). Published to `:department_status` by Operations after every dispatch and resolve. Consumed by DisplayBridge to update the dashboard's department status bars.

**`FieldReport`** — Confirmation that a unit has been dispatched. Fields: `call_id`, `department`, `unit_id` (e.g., `"E-1"`), `status` (symbol: `:dispatched`), `notes`, `timestamp`. Published to `:field_reports` by Operations on successful dispatch. Consumed by DisplayBridge and by ScenarioPlayer (to know when to send the next call).

**`Escalation`** — An emergency that no department can handle. Fields: `call_id`, `reason` (e.g., `"No department available for 'unknown'"`), `original_call` (description text), `attempted_departments` (array of name strings), `timestamp`. Published to `:escalation` by Operations. Consumed by SelfAgencyBridge to trigger runtime capability generation, by ScenarioPlayer to track completion, and by DisplayBridge.

**`LLMRequest`** — An outbound prompt to the LLM layer. Fields: `prompt` (string), `tools` (nil or array), `model` (string or nil), `correlation_id` (string like `"intel-C-001"` that links the response back to the originating call). Published to `:llm_requests` by Intelligence. Consumed by whichever LLM handler is active (LiveHandler, ScenarioDriver, or ScenarioRecorder).

**`LLMResponse`** — The LLM's answer. Fields: `content` (JSON string with classification data), `tool_calls` (nil or array), `tokens` (integer), `correlation_id`. Published to `:llm_responses` by the active LLM handler. Consumed by Intelligence, which parses the JSON and publishes a DispatchOrder.

**`MethodGen`** — A request to install a generated method. Fields: `target_class` (string like `"FireDepartment"`), `method_name` (string), `source_code` (string containing `def...end`), `status` (symbol: `:pending`). Published to `:method_gen` by ChaosBridge after code generation. Consumed by Governance for approval/rejection and method installation.

**`PolicyEvent`** — A governance decision. Fields: `action` (string: `"install_method"`), `decision` (symbol: `:approved` or `:rejected`), `reason` (string), `timestamp`. Published to `:governance` by Governance after evaluating a MethodGen, and by SelfAgencyLearner when self_agency installs a method. Consumed by DisplayBridge.

**`VoiceIn`** — An audio transcription from speech-to-text. Fields: `audio_path`, `transcription`, `caller_id`, `timestamp`. Published to `:voice_in` when audio is captured. Consumed by Listener, which transcribes the audio and publishes an EmergencyCall.

**`VoiceOut`** — Text to be spoken aloud. Fields: `text`, `voice` (macOS voice name or nil for auto-resolve), `department` (string used to look up the default voice), `priority` (integer). Published to `:voice_out` by Operations, SelfAgencyBridge, Governance, and ScenarioPlayer. Consumed by Speaker, which serializes speech through a semaphore to prevent overlapping audio.

**`DisplayEvent`** — A generic event envelope for the dashboard. Fields: `type` (symbol like `:dispatch`, `:method_installed`, `:phase_change`, `:escalation`, etc.), `data` (hash with event-specific payload), `timestamp`. Published to `:display` by nearly every component. Consumed by DisplayBridge, which buffers events for the SSE stream.

### VSM Layer — Intelligence and Operations

**`Intelligence`** (`lib/vsm/intelligence.rb`) — VSM System 4. Subscribes to `:calls` and `:llm_responses`. When an EmergencyCall arrives, it builds a classification prompt containing the caller, location, description, and severity, stores the call in a `@pending_calls` hash keyed by a deterministic correlation ID (`"intel-#{call_id}"`), and publishes an LLMRequest. When the matching LLMResponse comes back, it parses the JSON to extract `department`, `priority`, `units_requested`, and `eta`, then publishes a DispatchOrder. If JSON parsing fails, it defaults to `department: "unknown"`, which will trigger escalation downstream.

**`Operations`** (`lib/vsm/operations.rb`) — VSM System 1. Subscribes to `:dispatch` and `:display`. When a DispatchOrder arrives, it looks up the target department by name (falling back to `can_handle?` across all registered departments). Three outcomes: (1) if a department has available units, it dispatches — publishing a FieldReport, DeptStatus update, DisplayEvent, and a VoiceOut for the dispatch announcement; (2) if the department exists but all units are busy, it publishes a budget request to City Council (`:display` with `:budget_request` and `:budget_tabled` types, plus VoiceOut announcements); (3) if no department matches, it publishes an Escalation. After dispatch, it listens for `:voice_spoken` display events from the Speaker to trigger unit resolution — an async task that sleeps 5–10 seconds, then frees the unit and publishes an updated DeptStatus.

### Departments (`lib/departments/`)

**`BaseDepartment`** (`lib/departments/base_department.rb`) — Abstract base class for all city departments. Initialized with `name`, `unit_prefix`, `total_units`, and `handles` (array of symbols). Maintains an `@active` hash mapping `call_id` to `unit_id`. Provides: `can_handle?(dispatch_order)` — checks if the order's department symbol is in `@handles`; `handle(dispatch_order)` — checks unit availability, assigns the next unit ID (e.g., `"E-1"`, `"E-2"`), returns a result hash with `:status`, `:unit_id`, and `:notes`; `resolve(call_id)` — frees a unit; `available_units` / `capacity_pct` — capacity queries; `to_dept_status` — builds a DeptStatus message. Subclasses only need to call `super` with their configuration.

**`FireDepartment`** (`lib/departments/fire_department.rb`) — 5 units (prefix `E-`), handles `:fire`, `:structure_fire`, `:wildfire`. Includes SelfAgency, SelfAgencyReplay, SelfAgencyLearner.

**`PoliceDepartment`** (`lib/departments/police_department.rb`) — 4 units (prefix `U-`), handles `:police`, `:crime`, `:crime_violent`, `:robbery`, `:assault`, `:burglary`. Includes SelfAgency, SelfAgencyReplay, SelfAgencyLearner.

**`EMS`** (`lib/departments/ems.rb`) — 3 units (prefix `M-`), handles `:ems`, `:medical`, `:cardiac`, `:chest_pains`, `:injury`, `:accident`. Includes SelfAgency, SelfAgencyReplay, SelfAgencyLearner.

**`Utilities`** (`lib/departments/utilities.rb`) — 2 units (prefix `UT-`), handles `:utilities`, `:water_main`, `:gas_leak`, `:power_outage`, `:infrastructure`. Includes SelfAgency, SelfAgencyReplay, SelfAgencyLearner.

**`CityCouncil`** (`lib/departments/city_council.rb`) — 1 unit (prefix `CC-`), handles nothing (`handles: []`). Overrides `can_handle?` to strictly check `@handles` (always returns false for normal dispatch). Exists as the escalation target — SelfAgencyBridge generates `coordinate_*` methods on this class when novel emergencies arise. After a method is installed, CityCouncil gains the ability to coordinate multi-department responses.

### Autonomy Layer (`lib/autonomy/`)

**`Governance`** (`lib/autonomy/governance.rb`) — The safety gate for all runtime code generation. Subscribes to `:method_gen`. Evaluates each MethodGen against three checks: (1) is the target class on the `DEFAULT_ALLOWLIST` (FireDepartment, PoliceDepartment, EMS, Utilities, CityCouncil, DroneDepartment)? (2) does the source code contain a `def` keyword? (3) does it match any of `DANGEROUS_PATTERNS` — regexes for `system`, `exec`, `eval`, `send`, `File`, `IO`, `require`, `Kernel`, `Process`, `ObjectSpace`, backticks, etc.? If approved, it installs the method via `class_eval` on the target class and publishes `:method_installed` to `:display` plus a VoiceOut announcement. If rejected, it publishes `:method_rejected` to `:display` and NACKs the delivery (sending it to the dead letter queue). The `evaluate` method is public for direct unit testing without the bus.

**`ChaosBridge`** (`lib/autonomy/chaos_bridge.rb`) — The reactive autonomy path. Hooks into department classes by overriding `method_missing` via `watch(klass)`. When a missing method is called on a watched class, ChaosBridge publishes a `:method_missing` DisplayEvent, then spawns an `Async` task that asks the robot (ReplayRobot) to generate a method body. The response is passed to CodeExtractor, and if a valid `def...end` block is found, a MethodGen message is published to `:method_gen` for Governance to evaluate. The original `method_missing` call still raises `NoMethodError` via `super` — the generation happens in the background, so the method will be available on the *next* call.

**`SelfAgencyBridge`** (`lib/autonomy/self_agency_bridge.rb`) — The proactive autonomy path. Subscribes to `:escalation`. When an escalation arrives (a call no department can handle), it determines a method name using `method_name_for(reason)` (e.g., `"No department available"` becomes `"coordinate_no_department_available"`). If a `coordinate_*` method already exists on the target class (default: CityCouncil), it reuses it. Otherwise, it calls `CityCouncil.new._(description)` — the SelfAgency `_()` interface — which shapes the prompt, sends it through the robot, validates the generated code, and installs it. After installation, the bridge retries the escalated call by calling the new method with `call_id:`, publishes adaptation success events to `:display` and `:voice_out`, and dispatches to individual departments if the result includes a `:departments` array. Also generates capabilities on other department classes via `generate_department_capabilities`. Tracks handled escalations in `@handled` to prevent duplicate processing.

**`CodeExtractor`** (`lib/autonomy/code_extractor.rb`) — A stateless module that extracts `def...end` method bodies from LLM output. Tries three strategies in order: (1) Ruby-fenced code block (`` ```ruby ... ``` ``), (2) plain-fenced code block (`` ``` ... ``` ``), (3) bare `def...end` anywhere in the text. Returns the extracted source string or `nil` if no valid method definition is found. Used by ChaosBridge to parse robot responses.

**`SelfAgencyReplay`** (`lib/autonomy/self_agency_replay.rb`) — A module included in all department classes that overrides SelfAgency's LLM communication. Instead of making real API calls during the `_()` flow, it routes the `:shape` stage to a simple prompt builder and the `:generate` stage through the class-level `code_robot` (a ReplayRobot). This makes the autonomy pipeline work without network access.

**`SelfAgencyLearner`** (`lib/autonomy/self_agency_learner.rb`) — A module included in all department classes that hooks into SelfAgency's `on_method_generated` callback. When SelfAgency installs a new method, this callback publishes three events to the bus: a `:method_installed` DisplayEvent, a `:governance` PolicyEvent (approved), and a VoiceOut announcement. Provides class-level accessors `code_robot` and `event_bus`, which are set at boot in `bin/demo`.

### LLM Handlers (`lib/llm/`)

**`LiveHandler`** (`lib/llm/live_handler.rb`) — Used in `live` mode. Subscribes to `:llm_requests`, calls `RubyLLM.chat(model:).ask(prompt)` for each request, and publishes the response to `:llm_responses`. If the API call fails (network error, auth failure, etc.), it falls back to a keyword-based classifier (`KEYWORDS` hash mapping department names to arrays of trigger words) so the demo never stalls. Default model: `claude-haiku-4-5-20251001`.

**`ScenarioRecorder`** (`lib/llm/scenario_recorder.rb`) — Used in `record` mode. Subscribes to `:llm_requests`, makes real API calls via `RubyLLM.chat`, and writes each request/response pair to a JSONL file with sequence number, timestamp, correlation ID, full request/response, and elapsed time. Also publishes the real response to `:llm_responses` so the demo runs normally while recording. Call `close` to flush and close the file.

**`ScenarioDriver`** (`lib/llm/scenario_driver.rb`) — Used in `replay` mode (default). Loads a JSONL scenario file at initialization, indexing all records by `correlation_id` into a hash. Subscribes to `:llm_requests` and matches each request's correlation ID to a recorded response. If found, it sleeps for half the original elapsed time (for realistic pacing) and publishes the recorded content. If no match is found, it falls back to the same keyword classifier as LiveHandler. This is what makes the demo work with zero network access.

**`ReplayRobot`** (`lib/llm/replay_robot.rb`) — A fake LLM robot for the autonomy pipeline (used regardless of LLM mode). Loads pattern-matched responses from a YAML file (`scenarios/demo_robot.yml`). When `run(message:)` is called, it searches entries for one whose `patterns` array includes a substring match against the prompt. Returns a `Result` struct with `last_text_content` matching the `robot_lab` gem's interface. Falls back to a default entry or a hardcoded `handle_unknown` method. This is what ChaosBridge and SelfAgencyBridge use for code generation.

### Voice I/O (`lib/voice/`)

**`Speaker`** (`lib/voice/speaker.rb`) — Text-to-speech output using macOS `say`. Subscribes to `:voice_out`. Resolves the voice name from the message's `voice` field or looks it up by `department` in a `VOICES` hash (e.g., Fire → Daniel, Police → Karen, System → Zarvox). Uses an `Async::Semaphore` with limit 1 to serialize speech — only one voice speaks at a time. Spawns `say -v <voice> <text>` and waits for it to finish. After speaking, publishes a `:voice_spoken` DisplayEvent to `:display`, which Operations listens for to trigger unit resolution. Can be disabled at initialization (`enabled: false`) to skip TTS while still publishing display events.

**`Listener`** (`lib/voice/listener.rb`) — Speech-to-text input using `whispercpp`. Subscribes to `:voice_in`. When a VoiceIn message arrives with an audio file path, it transcribes the audio using a Whisper model (default: `base.en`), concatenates all segments, and publishes an EmergencyCall to `:calls` with the transcription as the description. Not used in the current demo scenario (calls come from ScenarioPlayer), but available for live mic input.

### Scenario Player

**`ScenarioPlayer`** (`lib/scenario/player.rb`) — Drives the demo's scripted call sequence. Loads a YAML file containing phases, each with a name, delay, and list of calls. The `play` method iterates phases in order, publishing a `:phase_change` DisplayEvent at the start of each, then iterating calls with configurable delays. For each call, it publishes a VoiceOut (so the audience hears the caller) and an EmergencyCall to `:calls`, then waits up to 10 seconds for the call to be dispatched (tracked by subscribing to `:field_reports` and `:escalation`). Cycles through `CALLER_VOICES` (Rishi, Tessa, Kathy, etc.) to give each caller a distinct voice. The `skip_delays: true` option (used in tests) bypasses all timing. Tracks `calls_played` count. Attaches to the bus for two-way communication: publishes calls, subscribes for dispatch confirmation.

### Web Layer

**`DisplayBridge`** (`lib/web/display_bridge.rb`) — The thread-safe bridge between the main-thread bus and the web-thread dashboard. Subscribes to six bus channels (`:display`, `:calls`, `:field_reports`, `:department_status`, `:escalation`, `:governance`), normalizing each message into a uniform `{id, type, data, source, timestamp}` hash stored in a Mutex-protected array. Assigns sequential IDs. Caps the buffer at 500 events (oldest dropped). The `events_since(last_id)` method is called by the SSE endpoint to fetch new events. Also provides `event_count` and `last_id` for stats.

**`DashboardApp`** (`web/app.rb`) — A Sinatra application served by Puma. Serves the static dashboard HTML/CSS/JS from `web/public/`. Exposes three API endpoints: `GET /events` — an SSE (Server-Sent Events) stream that polls `DisplayBridge.events_since` every 150ms and pushes JSON events to the browser; `POST /calls` — accepts a JSON body with `caller`, `location`, `description`, and `severity`, builds an EmergencyCall, and pushes it onto a `Thread::Queue` that the main thread drains into the bus; `GET /stats` — returns per-channel published/delivered/nacked/DLQ counts from `bus.stats`. Configured at boot in `bin/demo` with references to the bridge, bus, call queue, and port.

## Gem Dependencies

### typed_bus

The communication backbone of the entire demo. `BusSetup.create_bus` instantiates a `TypedBus::MessageBus` and registers all 12 channels, each constrained to a specific `Data.define` message type. Every component in the system calls `attach(bus)` to subscribe to channels and publish messages. The bus enforces type safety at publish time — publishing the wrong type raises `ArgumentError`. Subscribers receive `delivery` objects and must call `delivery.ack!` (success) or `delivery.nack!` (failure). NACKed deliveries are routed to per-channel dead letter queues that BusSetup wires with logging callbacks. Channel options like `max_pending: 5` (for `:llm_requests`) and `timeout: 10` (for `:voice_out`) provide backpressure and timeout handling. The `bus.stats` method provides per-channel published/delivered/nacked counters that the dashboard's `/stats` endpoint exposes.

### self_agency

Provides the runtime method generation that powers the demo's "free will" moment. Included as a mixin in all five department classes (`include SelfAgency`). When an object calls `_("description of what I need")`, SelfAgency shapes the prompt, sends it to an LLM, validates the generated code against security checks (no `system`, `eval`, etc.), and installs the result as a real instance method via `class_eval`. In this demo, SelfAgencyBridge calls `CityCouncil.new._(description)` when an escalation arrives that no existing department can handle, generating `coordinate_*` methods at runtime. After installation, the `on_method_generated` callback (provided by SelfAgencyLearner) publishes events to the bus. SelfAgency is configured at boot in `bin/demo` with `SelfAgency.configure` — set to `:ollama` provider with `"replay"` model in replay mode so it never makes real API calls.

### robot_lab

A local gem (at `../../robot_lab`) that provides the `RobotLab` interface used by ReplayRobot. In the demo, `ReplayRobot` wraps a YAML file of pattern-matched responses and exposes `run(message:)` returning a `Result` struct with `last_text_content` — the same interface that a real `robot_lab` robot would have. ChaosBridge and SelfAgencyBridge both use this robot for code generation. Unlike the LLM mode (which controls call classification), the autonomy layer always uses ReplayRobot regardless of mode, ensuring code generation is deterministic during the demo.

### ruby_llm

Multi-provider LLM client used in `live` and `record` modes for emergency call classification. `LiveHandler` calls `RubyLLM.chat(model: "claude-haiku-4-5-20251001").ask(prompt)` to classify incoming 911 calls, receiving JSON with department, priority, units, and ETA. `ScenarioRecorder` uses the same `RubyLLM.chat` interface while simultaneously logging every request/response pair to JSONL. Not used in `replay` mode (the default) — `ScenarioDriver` plays back pre-recorded responses instead. When API calls fail in live mode, `LiveHandler` falls back to keyword-based classification using a `KEYWORDS` hash so the demo never stalls.

### ruby_llm-mcp

Listed in the Gemfile for future MCP (Model Context Protocol) tool integration but not yet used in the current demo code.

### async

Provides the fiber-based concurrency model that the entire main thread runs on. `bin/demo` wraps the main loop in an `Async do` block, which creates a fiber reactor. Within this reactor: the scenario player publishes calls with timed delays; Operations spawns `Async do` tasks that sleep 5–10 seconds before resolving dispatched units; ChaosBridge spawns `Async do` tasks for background code generation so `method_missing` doesn't block; Speaker uses `Async::Semaphore.new(1)` to serialize TTS output so voices don't overlap; and the call queue drainer polls `Thread::Queue` every 100ms for dashboard-submitted calls. All tests also wrap their bus interactions in `Async do` blocks.

### sinatra

The web framework for the dashboard. `DashboardApp` inherits from `Sinatra::Base` and runs in the web thread. Serves static files (HTML, CSS, JS) from `web/public/`. Defines three routes: `GET /events` (SSE stream polling DisplayBridge every 150ms), `POST /calls` (accepts JSON, builds an EmergencyCall, pushes to the Thread::Queue), and `GET /stats` (returns per-channel bus statistics as JSON). Configured with `set :server, :puma` and `set :logging, false` (suppresses Sinatra request logs to keep demo output clean).

### puma

The HTTP server backing Sinatra. Configured via `set :server, :puma` and `set :server_settings, { Silent: true }` in DashboardApp to suppress startup banners. Runs in the web thread, handling concurrent SSE connections from the browser dashboard. Started by `DashboardApp.run!` inside `Thread.new` in `bin/demo`.

### rackup

Required as a dependency for Sinatra to boot Puma via `DashboardApp.run!`. Not used directly in application code.

### lumberjack

Structured logging throughout the demo. `bin/demo` creates a global `$logger = Lumberjack::Logger.new("log/demo.log")` with `:info` level and `buffer_size: 0` (immediate flush). Passed as a `logger:` keyword argument to nearly every component (Intelligence, Operations, Governance, ChaosBridge, SelfAgencyBridge, Speaker, ScenarioPlayer, ReplayRobot). All logging goes to `log/demo.log`; the demo produces no STDOUT output, so `tail -f log/demo.log` is the primary debugging view.

### whispercpp

Offline speech-to-text for live microphone input. Used by `Listener` (`lib/voice/listener.rb`), which creates a `Whisper::Context` with a language model (default: `base.en`) and transcribes audio files by calling `@whisper.transcribe(audio_path, params)`. The transcription is published as an EmergencyCall to the `:calls` channel. Runs entirely on-device using Apple Silicon acceleration — no network required. Not exercised in the current replay demo scenario (calls come from ScenarioPlayer as text), but available for live mic input mode.

### minitest

The test framework. All tests in `test/` use `Minitest::Test` with `Minitest::Autorun`. Test files are organized by VSM layer (layer1 through layer5) plus integration, scenario, dashboard, replay_robot, and autonomy tests. Rake tasks in the Rakefile provide `rake test` (all tests) and `rake test:<name>` for individual suites. Tests create temporary classes with `Object.const_set` and clean them up in `ensure` blocks.

### rake

Task runner providing the demo lifecycle (`rake start`, `rake stop`, `rake restart`, `rake status`) and all test suites. The Rakefile defines `Rake::TestTask` entries for each test file and wraps the demo process management — spawning `bin/demo` as a background process, tracking its PID in `tmp/demo.pid`, and handling graceful shutdown with `TERM`/`KILL` signals.

### json

Ruby's standard JSON library. Used by Intelligence to parse LLM classification responses (`JSON.parse(content, symbolize_names: true)`), by ScenarioDriver and ScenarioRecorder to read/write JSONL scenario files, by DisplayBridge for SSE event serialization, and by DashboardApp for request/response JSON handling.

### logger

Ruby's standard logging library. Listed as an explicit dependency in the Gemfile. Provides the base logging interface that Lumberjack extends.

### amazing_print

Pretty-printing library for development debugging. Listed in the Gemfile for interactive use (e.g., `ap object` in a REPL or debug session). Not required by any application code.

### debug_me

Debugging gem (from the project author). Listed in the Gemfile for development use. Provides `debug_me` as a replacement for `puts` debugging — supports inspecting variables with blocks (`debug_me { variable }`) and simple string output (`debug_me "message"`). Not required by application code but available for debugging sessions.

## Conference Reliability

The demo uses a tiered fallback strategy:

| Tier | Mode | When to Use |
|------|------|-------------|
| 1 | **Live** | Full API calls, best case with good WiFi |
| 2 | **Replay** | Pre-recorded LLM responses, everything else runs live — no network needed |
| 3 | **Video** | Pre-recorded screen capture as ultimate safety net |

In replay mode, the only pre-recorded element is what the LLM said. The message bus, departments, governance, voice, dashboard, and autonomy pipeline all run live.

## License

This demo was built for the RubyConf 2026 talk "Giving Robots Free Will" by Dewayne VanHoozer.
