# Demo Plan: Giving Robots Free Will

## Architecture Overview

Single Ruby process, single message bus, web-based visualization,
voice input and output.

```
┌─────────────────────────────────────────────────────────────┐
│  Ruby Process (Async reactor)                               │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  typed_bus (unified message bus)                      │  │
│  │  Typed channels, ACK/NACK, DLQ, stats, backpressure  │  │
│  └──┬───────┬──────────┬──────────┬──────────┬───────┬──┘  │
│     │       │          │          │          │       │       │
│     ▼       ▼          ▼          ▼          ▼       ▼       │
│  ┌─────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌─────┐ ┌─────┐ │
│  │Ident│ │Govern- │ │Coordin-│ │Intelli-│ │Oper-│ │Voice│ │
│  │ity  │ │ance    │ │ation   │ │gence   │ │atio-│ │ I/O │ │
│  │     │ │        │ │        │ │        │ │ns   │ │     │ │
│  │purp-│ │rules   │ │floor   │ │LLM     │ │tools│ │STT  │ │
│  │ose  │ │& caps  │ │& turn  │ │calls   │ │& run│ │TTS  │ │
│  └─────┘ └────────┘ └────────┘ └────────┘ └─────┘ └─────┘ │
│       VSM capsule (reimplemented on typed_bus)               │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Autonomy Layer                                      │  │
│  │  ┌─────────────────┐  ┌────────────────────────────┐ │  │
│  │  │  self_agency     │  │  chaos_to_the_rescue       │ │  │
│  │  │  (proactive)     │  │  (reactive safety net)     │ │  │
│  │  │  "I need this    │  │  "That method doesn't      │ │  │
│  │  │   method"        │  │   exist? Let me help."     │ │  │
│  │  └─────────────────┘  └────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  prompt_objects                                       │  │
│  │  Autonomous markdown entities with LLM behavior      │  │
│  │  Inter-object communication via typed_bus channels    │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  ruby_llm                                            │  │
│  │  Unified LLM interface (tool use, streaming, async)  │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Voice I/O                                           │  │
│  │  STT: whispercpp (offline, M2-native)                │  │
│  │  TTS: macOS say / pre-generated OpenAI TTS           │  │
│  │  Publishes transcriptions to :calls channel          │  │
│  │  Subscribes to :voice_out for spoken responses       │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Sinatra + WebSocket server                          │  │
│  │  Subscribes to typed_bus :display channel             │  │
│  │  Broadcasts events to browser via WebSocket          │  │
│  └──────────────────────────┬────────────────────────────┘  │
└─────────────────────────────┼───────────────────────────────┘
                              │ WebSocket
                       ┌──────┴──────┐
                       │   Browser   │
                       │  Dashboard  │
                       │  (D3.js /   │
                       │   SVG)      │
                       └─────────────┘
             🎤 Mic        🔊 Speakers
```

## Bottom-Up Build Order

Build each layer independently, test it, then compose upward.

### Layer 1: typed_bus channels

Define the message types and channels for the 911 simulation.

```ruby
# Message types (Ruby Data classes for immutability + typed_bus typing)
EmergencyCall  = Data.define(:call_id, :caller, :location, :description,
                             :severity, :timestamp)
DispatchOrder  = Data.define(:call_id, :department, :units_requested,
                             :priority, :eta)
DeptStatus     = Data.define(:department, :available_units, :active_calls,
                             :capacity_pct)
FieldReport    = Data.define(:call_id, :department, :unit_id, :status,
                             :notes, :timestamp)
Escalation     = Data.define(:call_id, :reason, :original_call,
                             :attempted_departments, :timestamp)
LLMRequest     = Data.define(:prompt, :tools, :model, :correlation_id)
LLMResponse    = Data.define(:content, :tool_calls, :tokens, :correlation_id)
MethodGen      = Data.define(:target_class, :method_name, :source_code, :status)
PolicyEvent    = Data.define(:action, :decision, :reason, :timestamp)
VoiceIn        = Data.define(:audio_path, :transcription, :caller_id, :timestamp)
VoiceOut       = Data.define(:text, :voice, :department, :priority)
DisplayEvent   = Data.define(:type, :data, :timestamp)
```

Channels:

| Channel | Type | Purpose |
|---------|------|---------|
| `:calls` | `EmergencyCall` | Incoming 911 calls (from voice or script) |
| `:dispatch` | `DispatchOrder` | Routing decisions from Intelligence |
| `:department_status` | `DeptStatus` | Department capacity, active units |
| `:field_reports` | `FieldReport` | Updates from responding units |
| `:escalation` | `Escalation` | Unhandled emergencies → city council |
| `:llm_requests` | `LLMRequest` | Outbound LLM calls |
| `:llm_responses` | `LLMResponse` | Inbound LLM results |
| `:method_gen` | `MethodGen` | self_agency / chaos method generation events |
| `:governance` | `PolicyEvent` | Approval/rejection of actions & new methods |
| `:voice_in` | `VoiceIn` | Raw audio transcribed to text |
| `:voice_out` | `VoiceOut` | Text to be spoken aloud |
| `:display` | `DisplayEvent` | Everything forwarded to the dashboard |

### Layer 2: ruby_llm integration

Wrap ruby_llm in a typed_bus subscriber/publisher pattern.

```ruby
# Intelligence module subscribes to :llm_requests, publishes to :llm_responses
bus.subscribe(:llm_requests) do |delivery|
  req = delivery.message
  chat = RubyLLM.chat(model: req.model)
  response = chat.ask(req.prompt)

  bus.publish(:llm_responses, LLMResponse.new(
    content:        response.content,
    tool_calls:     response.tool_calls,
    tokens:         response.input_tokens + response.output_tokens,
    correlation_id: req.correlation_id
  ))

  delivery.ack!
end
```

### Layer 3: Voice I/O

Voice brings the 911 simulation to life. All voice runs offline for
conference reliability.

**Speech-to-Text (incoming calls):**

```ruby
# whispercpp — fully offline, fast on M2, no WiFi risk
require "whispercpp"

whisper = Whispercpp.build(model_type: :base)

# Voice-in subscriber: transcribes audio, publishes to :calls
bus.subscribe(:voice_in) do |delivery|
  vin = delivery.message
  result = whisper.transcribe(vin.audio_path)

  bus.publish(:calls, EmergencyCall.new(
    call_id:     SecureRandom.uuid,
    caller:      vin.caller_id,
    location:    nil,  # Intelligence will extract from transcription
    description: result.text,
    severity:    nil,  # Intelligence will classify
    timestamp:   Time.now
  ))

  delivery.ack!
end
```

Two input modes:
1. **Live mic** — speaker (or audience member) speaks into the mic,
   audio captured and transcribed in real-time
2. **Pre-recorded** — scripted caller audio files played in sequence
   for reliable pacing

**Text-to-Speech (dispatch & department responses):**

```ruby
# Voice assignments — each character has a distinct macOS voice
VOICES = {
  dispatch:    "Samantha",   # calm, professional
  caller:      "Alex",       # default caller
  fire:        "Daniel",     # authoritative
  police:      "Karen",      # firm
  ems:         "Moira",      # measured
  utilities:   "Fred",       # matter-of-fact
  council:     "Victoria",   # deliberate
  system:      "Zarvox"      # robotic — for system announcements
}

# Voice-out subscriber: speaks text aloud
bus.subscribe(:voice_out) do |delivery|
  vout = delivery.message
  voice = VOICES[vout.department&.to_sym] || VOICES[:system]

  # macOS say — instant, no network, no latency
  system("say", "-v", voice, vout.text)

  bus.publish(:display, DisplayEvent.new(
    type: :voice_spoken,
    data: { department: vout.department, text: vout.text, voice: voice },
    timestamp: Time.now
  ))

  delivery.ack!
end
```

**What the audience hears during the demo:**

| Moment | Voice | Says |
|--------|-------|------|
| Call arrives | Alex (caller) | "There's smoke pouring out of the building at 4th and Main!" |
| Dispatch acknowledges | Samantha (dispatch) | "Copy, structure fire reported at 4th and Main. Dispatching Engine 7." |
| Fire responds | Daniel (fire chief) | "Engine 7 en route, ETA 4 minutes." |
| Field report | Daniel (fire) | "Engine 7 on scene. Two-alarm fire, requesting additional units." |
| Drone swarm call | Alex (caller) | "There are drones everywhere downtown! Hundreds of them dropping papers!" |
| Dispatch confused | Samantha (dispatch) | "Unknown emergency type. Attempting classification." |
| System adapts | Zarvox (system) | "New capability generated: handle drone swarm. Governance approved." |
| Council creates dept | Victoria (council) | "Establishing Drone Response Department. Assigning resources." |

**Pre-generation option for higher quality:**

For maximum polish, pre-generate caller audio using OpenAI TTS
(which sounds more natural/emotional) and store locally. Department
and dispatch responses can still use macOS `say` for real-time
generation since they're procedural.

```ruby
# Pre-demo script: generate caller audio with OpenAI TTS
# Run once, store in audio/ directory
callers = [
  { text: "There's smoke pouring out of the building!", voice: "nova" },
  { text: "Someone just robbed the corner store!",      voice: "echo" },
  { text: "My husband is having chest pains!",          voice: "shimmer" },
  { text: "Drones everywhere downtown!",                voice: "ash" },
]

callers.each_with_index do |c, i|
  chat = RubyLLM.chat  # uses OpenAI TTS
  # ... generate and save to audio/caller_#{i}.mp3
end
```

**Dependencies:**

```ruby
gem "whispercpp", "~> 1.3"    # offline STT
# macOS `say` command — no gem needed, built-in
# Optional: ruby_llm for pre-generating higher quality caller voices
```

### Layer 4: self_agency + chaos_to_the_rescue (was Layer 3)

Both publish to the `:method_gen` channel when they generate code.

- self_agency: proactive — agent decides it needs a method, requests generation
- chaos_to_the_rescue: reactive — method_missing triggers, LLM generates a suggestion

Governance subscribes to `:method_gen` and approves/rejects before installation.

```ruby
bus.subscribe(:method_gen) do |delivery|
  gen = delivery.message

  if governance.approve?(gen.target_class, gen.method_name, gen.source_code)
    # Install the method
    gen.target_class.class_eval(gen.source_code)
    bus.publish(:display, DisplayEvent.new(
      type: :method_installed,
      data: { class: gen.target_class.name, method: gen.method_name },
      timestamp: Time.now
    ))
    delivery.ack!
  else
    delivery.nack!  # Goes to DLQ
  end
end
```

### Layer 5: VSM capsule structure on typed_bus

Reimplement VSM's five systems as typed_bus subscribers rather than
using VSM's internal bus. Each system is a module that subscribes to
relevant channels and publishes its outputs.

| VSM System | Subscribes To | Publishes To | 911 Role |
|------------|---------------|--------------|----------|
| Identity | `:calls` | `:display` | "Protect and serve" — filters non-emergency noise |
| Governance | `:method_gen`, `:dispatch` | `:governance`, `:display` | SLA enforcement, budget caps, method approval |
| Coordination | `:calls`, `:department_status` | `:dispatch`, `:display` | Dispatch queue, priority scheduling, mutual aid |
| Intelligence | `:calls`, `:llm_requests` | `:dispatch`, `:llm_responses`, `:display` | Call classification, resource allocation via LLM |
| Operations | `:dispatch` | `:field_reports`, `:department_status`, `:display` | Department capsules execute responses |

### Layer 6: prompt_objects integration

prompt_objects become typed_bus participants. Each autonomous markdown
entity subscribes to channels relevant to its role and communicates
with other entities via typed_bus rather than prompt_objects' built-in
messaging.

### Layer 7: Web dashboard (Sinatra + WebSocket + SVG)

Single Sinatra app running inside the same Async reactor.

```ruby
# In the same process
Async do
  # Start the agent system
  agent = build_agent(bus)

  # Start Sinatra with WebSocket support
  # Subscribe to :display channel, broadcast to all connected browsers
  bus.subscribe(:display) do |delivery|
    broadcast_to_websockets(delivery.message)
    delivery.ack!
  end

  # Sinatra serves the dashboard HTML/JS/CSS
  Rack::Handler.run(DashboardApp, Port: 4567)
end
```

Dashboard layout is defined in the Demo Scenario section below.

## Demo Scenario: City 911 Emergency Dispatch

A simulation of a city's 911 system. Emergency calls arrive, the
dispatch system classifies and routes them to city departments, each
department is its own recursive VSM capsule, and when no department
exists to handle a novel emergency the system must adapt — generating
new capabilities or escalating to city council.

This mirrors the VRSIL work: a multi-agent simulation of a complex
system under stress, but now the agents can extend themselves.

### The City as a Viable System

```
┌─────────────────────────────────────────────────────────────┐
│  City 911 System (top-level VSM capsule)                    │
│                                                             │
│  Identity:      "Protect and serve the citizens"            │
│  Governance:    Response time SLAs, budget caps, escalation │
│  Coordination:  Dispatch queue, priority scheduling         │
│  Intelligence:  Call classification, resource allocation    │
│  Operations:    Department capsules (below)                 │
│                                                             │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐  │
│  │ Fire Dept │ │ Police    │ │ EMS       │ │ Utilities │  │
│  │ (capsule) │ │ (capsule) │ │ (capsule) │ │ (capsule) │  │
│  │           │ │           │ │           │ │           │  │
│  │ Identity  │ │ Identity  │ │ Identity  │ │ Identity  │  │
│  │ Govern.   │ │ Govern.   │ │ Govern.   │ │ Govern.   │  │
│  │ Coord.    │ │ Coord.    │ │ Coord.    │ │ Coord.    │  │
│  │ Intel.    │ │ Intel.    │ │ Intel.    │ │ Intel.    │  │
│  │ Ops.      │ │ Ops.      │ │ Ops.      │ │ Ops.      │  │
│  └───────────┘ └───────────┘ └───────────┘ └───────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ City Council (escalation target)                     │  │
│  │ Receives emergencies no department can handle        │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

Each department is a recursive VSM capsule with its own identity,
governance rules, coordination, intelligence, and operations —
all communicating over typed_bus channels.

### typed_bus Channels for 911

| Channel | Type | Purpose |
|---------|------|---------|
| `:calls` | `EmergencyCall` | Incoming 911 calls |
| `:dispatch` | `DispatchOrder` | Routing decisions from Intelligence |
| `:department_status` | `DeptStatus` | Department capacity, active units |
| `:field_reports` | `FieldReport` | Updates from responding units |
| `:escalation` | `Escalation` | Unhandled emergencies → city council |
| `:method_gen` | `MethodGen` | New capability generation events |
| `:governance` | `PolicyEvent` | Approval/rejection of actions & new methods |
| `:display` | `DisplayEvent` | Everything forwarded to the dashboard |

### Message Types

```ruby
EmergencyCall = Data.define(
  :call_id, :caller, :location, :description,
  :severity, :timestamp
)

DispatchOrder = Data.define(
  :call_id, :department, :units_requested,
  :priority, :eta
)

DeptStatus = Data.define(
  :department, :available_units, :active_calls,
  :capacity_pct
)

FieldReport = Data.define(
  :call_id, :department, :unit_id, :status,
  :notes, :timestamp
)

Escalation = Data.define(
  :call_id, :reason, :original_call,
  :attempted_departments, :timestamp
)
```

### prompt_objects as Department Personalities

Each department is a prompt_object (markdown entity) with its own
LLM-backed behavior defining how it triages, responds, and reports:

```
prompts/
├── dispatch_operator.md    # Classifies calls, decides routing
├── fire_department.md      # Fire response protocols & priorities
├── police_department.md    # Law enforcement response logic
├── ems.md                  # Medical emergency triage
├── utilities.md            # Power/water/gas emergency handling
└── city_council.md         # Escalation handler, policy maker
```

### Live Demo Sequence

**Phase 1: Normal operations (show the system working)**

1. Simulation starts. Pre-recorded caller audio plays through
   speakers. The audience *hears* the 911 call:
   🔊 "911, there's smoke pouring out of a building at 4th and Main!"
2. whispercpp transcribes the audio offline, publishes to `:voice_in`,
   which flows into `:calls`.
3. Dispatch (Intelligence) classifies via ruby_llm. The dispatch
   operator *speaks back*:
   🔊 "Copy, structure fire at 4th and Main. Dispatching Engine 7."
4. Fire department acknowledges in its own voice:
   🔊 "Engine 7 en route, ETA 4 minutes."
5. More calls arrive — armed robbery (Police voice responds),
   chest pains (EMS voice responds), water main break (Utilities).
6. Dashboard shows calls flowing, departments handling, units
   deploying. The audience hears and sees the system working.

**Phase 2: Stress (show coordination and governance)**

7. Multiple simultaneous emergencies arrive. Fire department hits
   capacity (all units deployed).
8. Coordination kicks in — mutual aid protocol. Dispatch voice:
   🔊 "All fire units committed. Requesting EMS assist for medical
   at the fire scene on 4th."
9. Governance enforces response time SLAs, flags a call approaching
   its deadline. System voice:
   🔊 "Warning: Call 7 approaching SLA threshold."

**Phase 3: The unknown (show "free will")**

10. A panicked caller — either pre-recorded or the speaker live at
    the mic:
    🔊 "There are drones everywhere downtown! Hundreds of them
    dropping papers! No one knows who's operating them!"
11. whispercpp transcribes. Intelligence tries to route it — no
    department has a `handle_drone_swarm` capability. Dispatch:
    🔊 "Unknown emergency type. Attempting classification."
12. **chaos_to_the_rescue** catches the missing method, generates a
    response procedure, publishes to `:method_gen`.
13. **Governance** evaluates: is this within city authority? Does it
    require new resources? It approves a basic assessment method but
    flags for escalation. System voice:
    🔊 "New capability generated: handle drone swarm. Governance
    approved. Escalating to City Council."
14. **self_agency** proactively generates
    `coordinate_multi_department_response` — recognizing this needs
    police (airspace), fire (public safety), and a capability the
    city doesn't have yet.
15. The call **escalates to City Council**. Council voice:
    🔊 "Emergency session convened. Assessing drone threat.
    Establishing Drone Response Department."
16. A `DroneDepartment` capsule is instantiated at runtime with its
    own VSM structure.

**Phase 4: Adaptation (show the system has grown)**

17. Another drone call comes in (or the speaker says one live).
18. This time, it routes directly to the new Drone Department.
    A new voice responds:
    🔊 "Drone Response Unit 1 dispatched to investigate."
19. The system has evolved. It gave itself new capabilities to handle
    a situation it was never designed for.

**Optional crowd moment:** Invite an audience member to call in a
completely novel emergency. The system classifies, attempts to handle,
and adapts — all with voice — live and unscripted.

### What the Audience Sees

```
┌─────────────────────────────────────────────────────────────────┐
│  GIVING ROBOTS FREE WILL — City 911 Simulation                  │
├────────────────────────────┬────────────────────────────────────┤
│                            │                                    │
│  City Map (SVG)            │  Active Calls                     │
│                            │                                    │
│   🔴 Structure fire       │  #1 Structure fire    [FIRE]  ✓   │
│      4th & Main            │  #2 Armed robbery     [PD]   ...  │
│   🔵 Armed robbery        │  #3 Chest pains       [EMS]  ...  │
│      Oak & 12th            │  #4 Water main break  [UTIL] ✓   │
│   🟢 Chest pains          │  #5 Drone swarm       [???]  ⚠   │
│      200 Elm St            │     → ESCALATED TO COUNCIL        │
│   🟡 Water main           │                                    │
│      Industrial Blvd       │                                    │
│   ⚪ Drone swarm          │                                    │
│      Downtown              │                                    │
│                            │                                    │
├────────────────────────────┼────────────────────────────────────┤
│  Department Status         │  Event Stream                     │
│                            │                                    │
│  🟥 Fire    3/5 units     │  12:03 [DISPATCH] Call #5 rcvd    │
│  🟦 Police  2/4 units     │  12:03 [INTEL] Classification:    │
│  🟩 EMS     1/3 units     │        unknown emergency type     │
│  🟨 Util    0/2 units     │  12:03 [CHAOS] method_missing:    │
│  ⬜ Drone   NEW            │        handle_drone_swarm         │
│                            │  12:04 [MGEN] Generated method    │
│  Governance                │  12:04 [GOV] Approved (temporary) │
│  SLA violations: 0         │  12:04 [GOV] Escalating to        │
│  Methods generated: 2      │        City Council               │
│  Methods approved: 2       │  12:05 [COUNCIL] Creating         │
│  Methods denied: 0         │        DroneDepartment capsule    │
│  DLQ depth: 0              │  12:05 [SYSTEM] New department    │
│                            │        registered: Drone Response │
├────────────────────────────┴────────────────────────────────────┤
│  typed_bus: published 247 | delivered 243 | nacked 2 | DLQ 2   │
│  channels: calls(23) dispatch(21) field(45) method_gen(2)      │
│  throughput: ████████████████░░░░ 1,247 msg/s                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Scenario Works for the Talk

1. **Relatable** — everyone understands 911. No domain knowledge
   needed.
2. **VSM is natural** — a city emergency system is a textbook viable
   system with recursive departments.
3. **The "free will" moment is dramatic** — a swarm of drones nobody
   planned for. The system adapts live on stage.
4. **Multiple gems shine** — chaos catches the missing method,
   self_agency proactively builds coordination, prompt_objects give
   departments personality, vsm provides structure, typed_bus makes
   it all observable.
5. **Echoes the VRSIL** — this is a simulation of a complex system
   under stress, just like the missile defense war games. Same
   instinct, 20 years later, with AI agents that can grow.
6. **Scales naturally** — start simple (4 departments), end with 5.
   The audience watches the system become more than it was.

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Message bus | typed_bus (replaces VSM internal bus) | Single observable event stream, unified stats, DLQ for failed governance |
| LLM interface | ruby_llm | Multi-provider, tool use, streaming, async-native |
| Concurrency | Async gem (fibers) | Single process, non-blocking, typed_bus is already async-native |
| Web server | Sinatra + faye-websocket | Lightweight, runs inside the Async reactor, serves dashboard |
| Visualization | D3.js + SVG in browser | Dark theme SVG, real-time updates via WebSocket, VSM diagram as interactive SVG |
| Message types | Ruby Data classes | Immutable, typed, pattern-matchable, work with typed_bus type constraints |
| Speech-to-text | whispercpp | Fully offline on M2, no WiFi risk, fast transcription |
| Text-to-speech | macOS `say` command | Instant, offline, multiple distinct voices, zero dependencies |
| Caller audio | Pre-generated OpenAI TTS (stored locally) | More natural/emotional than macOS voices; pre-generated eliminates runtime risk |
| Demo reliability | Record/replay pattern (JSONL scenario files) | All external API traffic recorded ahead of time; internal system runs live at conference |
| Scenario format | JSONL (one record per LLM exchange) | Human-readable, appendable, easy to inspect and edit |

## Demo Reliability: Tiered Fallback Strategy

Conference demos fail. WiFi drops, APIs timeout, projectors glitch.
Plan for three tiers, build the cheapest insurance first.

```
Tier 1: LIVE         — full live with API calls (best case)
Tier 2: REPLAY       — recorded LLM traffic, everything else live
Tier 3: VIDEO        — pre-recorded screen capture of a full run
```

**Build order for insurance:** Tier 3 first (costs nothing — just
hit record), then Tier 2 (requires scenario infrastructure), then
aim for Tier 1 at the conference.

### Tier 3: Video Recording (build first, cheapest)

Record a screen capture of the full demo running in Tier 1 or
Tier 2 mode. This is the ultimate safety net.

**What to record:**
- Full screen: dashboard + terminal side by side
- System audio: all TTS voice output captured
- 1080p minimum, 30fps (conference projectors)

**How to record on macOS:**
- OBS Studio (free) or macOS screen recording (Cmd+Shift+5)
- Capture system audio via BlackHole or Loopback
- Record 2-3 takes, keep the best

**When to use:**
- Hardware failure (laptop won't connect to projector)
- Software crash during the talk
- Any situation where the live system is unrecoverable

**Presentation strategy:** If you must fall back to video, narrate
over it live. Point out what's happening, pause at key moments,
explain the architecture. A narrated video is far better than a
broken live demo. The audience came for the ideas, not the I/O.

**Cost:** ~30 minutes to set up and record. Zero code.

### Tier 2: Record/Replay (Scenario Creator & Driver)

Record a full live run ahead of time, then replay the external API
traffic at the conference. Everything internal still runs live —
typed_bus, VSM capsules, voice, dashboard — only the LLM responses
are canned.

### What Gets Recorded

The **boundary** is any message that crosses the process into an
external service:

| External Call | Direction | Example |
|---------------|-----------|---------|
| LLM request | outbound | "Classify this emergency: smoke at 4th and Main" |
| LLM response | inbound | "Category: structure_fire, severity: high, department: fire" |
| LLM tool calls | inbound | tool_call: dispatch_unit(department: "fire", units: 2) |
| Method generation (LLM) | inbound | Generated source code for `handle_drone_swarm` |

What does NOT get recorded (runs live at conference):
- typed_bus message routing and delivery
- VSM capsule logic (governance checks, coordination, etc.)
- Voice output (macOS `say` — local)
- Voice input transcription (whispercpp — local)
- Dashboard WebSocket updates
- Department state machines
- Method installation via self_agency / chaos_to_the_rescue

### Scenario Creator

Runs the full simulation with live LLM API access. Intercepts and
logs all external traffic to a scenario file.

```ruby
# bin/record_scenario
#
# Runs the simulation live, records all LLM traffic to a JSONL file.
# Run this at home/hotel with good internet before the conference.

class ScenarioRecorder
  def initialize(output_path)
    @log = File.open(output_path, "w")
    @sequence = 0
  end

  # Wraps the real LLM interface, recording request/response pairs
  def intercept_llm(bus)
    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Make the real API call
      chat = RubyLLM.chat(model: req.model)
      response = chat.ask(req.prompt)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      # Record the exchange
      record = {
        seq:            @sequence += 1,
        timestamp:      Time.now.iso8601(3),
        correlation_id: req.correlation_id,
        request:  {
          prompt: req.prompt,
          tools:  req.tools,
          model:  req.model
        },
        response: {
          content:    response.content,
          tool_calls: response.tool_calls,
          tokens:     response.input_tokens + response.output_tokens
        },
        elapsed_seconds: elapsed.round(3)
      }

      @log.puts(JSON.generate(record))
      @log.flush

      # Publish the real response
      bus.publish(:llm_responses, LLMResponse.new(
        content:        response.content,
        tool_calls:     response.tool_calls,
        tokens:         response.input_tokens + response.output_tokens,
        correlation_id: req.correlation_id
      ))

      delivery.ack!
    end
  end

  def close
    @log.close
  end
end
```

The scenario file is JSONL — one JSON object per line, each
representing a request/response pair with timing:

```jsonl
{"seq":1,"timestamp":"2026-07-10T14:23:01.123Z","correlation_id":"abc-123","request":{"prompt":"Classify: smoke at 4th and Main","model":"claude-sonnet-4-5"},"response":{"content":"{\"category\":\"structure_fire\",\"severity\":\"high\"}","tool_calls":null,"tokens":247},"elapsed_seconds":1.234}
{"seq":2,"timestamp":"2026-07-10T14:23:03.456Z","correlation_id":"def-456","request":{"prompt":"Classify: armed robbery in progress","model":"claude-sonnet-4-5"},"response":{"content":"{\"category\":\"crime_violent\",\"severity\":\"critical\"}","tool_calls":null,"tokens":189},"elapsed_seconds":0.987}
```

### Scenario Driver

Replaces the live LLM interface at the conference. Matches incoming
requests to recorded responses by correlation_id, replays them with
realistic timing.

```ruby
# lib/scenario/driver.rb

class ScenarioDriver
  def initialize(scenario_path)
    @responses = {}
    File.foreach(scenario_path) do |line|
      record = JSON.parse(line, symbolize_names: true)
      @responses[record[:correlation_id]] = record
    end
  end

  # Drop-in replacement for the live LLM subscriber
  def attach(bus)
    bus.subscribe(:llm_requests) do |delivery|
      req = delivery.message
      record = @responses[req.correlation_id]

      if record
        # Simulate realistic API latency
        sleep(record[:elapsed_seconds] * 0.5)  # slightly faster for demo pacing

        bus.publish(:llm_responses, LLMResponse.new(
          content:        record[:response][:content],
          tool_calls:     record[:response][:tool_calls],
          tokens:         record[:response][:tokens],
          correlation_id: req.correlation_id
        ))
      else
        # Unrecorded request — log warning, attempt fallback
        warn "SCENARIO: No recorded response for #{req.correlation_id}"
        bus.publish(:llm_responses, LLMResponse.new(
          content:        '{"error":"no recorded response"}',
          tool_calls:     nil,
          tokens:         0,
          correlation_id: req.correlation_id
        ))
      end

      delivery.ack!
    end
  end
end
```

### Demo Modes

The entry point selects the mode:

```ruby
# bin/demo

mode = ARGV[0] || "replay"

case mode
when "live"
  # Full live mode — requires internet + API keys
  # Use for development and recording
  setup_live_llm(bus)

when "record"
  # Live mode + recording all traffic
  # Run at hotel night before the talk
  recorder = ScenarioRecorder.new("scenarios/conference_demo.jsonl")
  recorder.intercept_llm(bus)

when "replay"
  # Conference mode — no external dependencies
  # All LLM responses come from the scenario file
  driver = ScenarioDriver.new("scenarios/conference_demo.jsonl")
  driver.attach(bus)
end
```

### Why This Works

1. **The audience sees a live system.** typed_bus routes messages in
   real-time, VSM capsules process them, the dashboard updates, voices
   speak. Nothing is a video — it's a running Ruby process.
2. **The only thing pre-recorded is what the LLM said.** And LLMs are
   deterministic enough that the same prompt would produce a similar
   response anyway.
3. **You can run it multiple times.** Record several scenarios, pick
   the best one. If you want to show the audience a second run, you
   can.
4. **Fallback chain.** Try live first → fall back to replay if API
   fails → worst case, you have a known-good recording.
5. **The recording is itself a demo artifact.** You can share the
   JSONL file with attendees as an example of the system's behavior.

### Pre-Conference Checklist

**At home (1-2 weeks before):**

- [ ] Record Tier 3 video of the full demo (OBS, 1080p, system audio)
- [ ] Watch the video — verify pacing, audio, all 4 phases visible
- [ ] Store video on laptop AND a USB drive (redundancy)

**Night before the talk (hotel):**

- [ ] Run `bin/demo record` with hotel WiFi
- [ ] Verify all 4 phases complete (normal → stress → unknown → adapt)
- [ ] Check scenario file has all expected correlation_ids
- [ ] Run `bin/demo replay` to verify playback works offline
- [ ] Run it twice — keep the better recording
- [ ] Re-record Tier 3 video of the replay run (freshest version)
- [ ] Test with speakers and dashboard on projector resolution

**At the venue (before the talk):**

- [ ] Test projector resolution and audio
- [ ] Try `bin/demo live` — does WiFi work?
- [ ] If yes: plan for Tier 1, keep Tier 2 ready
- [ ] If no: plan for Tier 2 (replay), keep Tier 3 ready
- [ ] Have video file open and ready to play at all times

## Open Questions

1. Should prompt_objects use typed_bus directly, or keep their own
   messaging with a bridge? (depends on how tightly coupled we want them)
2. How much of VSM's capsule DSL do we preserve vs. rewrite on
   typed_bus? (trade-off: audience familiarity with VSM gem vs. clean
   demo code)
3. Should governance approval be automatic (allowlist-based) or
   interactive (pause and ask the audience)?
4. How many departments at startup? Four (Fire, Police, EMS,
   Utilities) feels right — enough to show the pattern, few enough
   to track on screen.
5. Should the new DroneDepartment capsule be fully generated at
   runtime by the LLM, or should we have a skeleton ready and let
   the LLM fill in the response methods? (reliability vs. drama)
6. City map visualization: abstract grid, or a recognizable
   simplified city layout? Abstract is safer for a demo.
7. Should the scenario driver match by correlation_id (exact replay)
   or by prompt similarity (flexible replay that tolerates minor
   variations)? Correlation_id is simpler and more reliable.
8. Should we record multiple scenario variants (e.g., different
   drone emergencies) and let the speaker choose at runtime?

## Dependencies

```ruby
# Gemfile
gem "typed_bus"
gem "ruby_llm"
gem "self_agency"
gem "chaos_to_the_rescue"
gem "vsm"                    # for reference / partial reuse
gem "prompt_objects"
gem "sinatra"
gem "faye-websocket"
gem "async"
gem "falcon"                 # async-native web server (alternative to thin)
gem "whispercpp", "~> 1.3"   # offline speech-to-text
# macOS `say` — no gem needed (built-in)
# Optional: pre-generate caller audio with ruby_llm + OpenAI TTS
```

## File Structure (proposed)

```
demo/
├── Gemfile
├── Rakefile
├── config/
│   ├── bus_channels.rb       # typed_bus channel definitions
│   ├── governance_rules.rb   # allowlists, deny patterns
│   ├── llm_config.rb         # ruby_llm provider setup
│   └── voices.rb             # voice assignments per character
├── lib/
│   ├── agent.rb              # top-level agent assembly
│   ├── vsm/
│   │   ├── identity.rb       # purpose & name
│   │   ├── governance.rb     # policy enforcement
│   │   ├── coordination.rb   # scheduling & turn management
│   │   ├── intelligence.rb   # LLM integration
│   │   └── operations.rb     # tool execution
│   ├── messages/
│   │   ├── emergency_call.rb
│   │   ├── dispatch_order.rb
│   │   ├── dept_status.rb
│   │   ├── field_report.rb
│   │   ├── escalation.rb
│   │   ├── llm_request.rb
│   │   ├── llm_response.rb
│   │   ├── method_gen.rb
│   │   ├── policy_event.rb
│   │   ├── voice_in.rb
│   │   ├── voice_out.rb
│   │   └── display_event.rb
│   ├── departments/
│   │   ├── base_department.rb  # shared VSM capsule for departments
│   │   ├── fire.rb
│   │   ├── police.rb
│   │   ├── ems.rb
│   │   └── utilities.rb
│   ├── voice/
│   │   ├── listener.rb         # mic capture + whispercpp STT
│   │   ├── speaker.rb          # macOS say TTS output
│   │   └── pre_generate.rb     # script to pre-gen caller audio
│   ├── scenario/
│   │   ├── recorder.rb         # intercepts & logs LLM traffic
│   │   └── driver.rb           # replays recorded LLM responses
│   └── autonomy/
│       ├── self_agency_bridge.rb
│       └── chaos_bridge.rb
├── web/
│   ├── app.rb                # Sinatra dashboard
│   ├── public/
│   │   ├── dashboard.js      # D3.js + WebSocket client
│   │   ├── vsm_diagram.js    # SVG capsule rendering
│   │   └── style.css         # dark theme
│   └── views/
│       └── index.erb
├── audio/
│   ├── callers/              # pre-generated caller audio (OpenAI TTS)
│   │   ├── fire_caller.mp3
│   │   ├── robbery_caller.mp3
│   │   ├── medical_caller.mp3
│   │   ├── utility_caller.mp3
│   │   └── drone_caller.mp3
│   └── models/               # whispercpp model files
│       └── ggml-base.bin
├── prompts/                  # prompt_objects markdown entities
│   ├── dispatch_operator.md  # call classification & routing
│   ├── fire_department.md    # fire response protocols
│   ├── police_department.md  # law enforcement response
│   ├── ems.md                # medical emergency triage
│   ├── utilities.md          # power/water/gas emergencies
│   └── city_council.md       # escalation handler & policy maker
├── scenarios/
│   ├── demo_calls.yml            # scripted emergency call sequence
│   └── conference_demo.jsonl     # recorded LLM traffic for replay
└── bin/
    ├── demo                  # entry point: live | record | replay
    └── generate_audio        # pre-generate caller voice files
```
