#!/usr/bin/env ruby
# frozen_string_literal: true

#
# City 911 Emergency Dispatch Center
# A self-adapting system that dynamically creates departments
# and teaches them to handle emergencies they've never seen.
#
# Uses:
#   self_agency          - deliberate method generation via LLM
#   chaos_to_the_rescue  - reactive method generation for unknown calls
#   robot_lab            - LLM-powered robots and workflows
#   typed_bus            - inter-department messaging with typed channels
#   vsm                  - Viable System Model capsule for structured dispatch
#
require "async"
require "bundler/setup"
require_relative "../department"
require_relative "../bus_setup"
require_relative "../tools/dispatch_tool"
require_relative "../tools/resource_query_tool"
require "vsm"
require "amazing_print"
require "lumberjack"
require_relative "../comms_robot"

LOG = Lumberjack::Logger.new("city_911.log", level: :info)

SEPARATOR    = "=" * 60
THIN_SEP     = "-" * 60

# ---------------------------------------------------------------
# LLM Configuration
# Adjust provider/model to match your setup.
# Defaults to Ollama running locally.
# ---------------------------------------------------------------

LLM_PROVIDER = (ENV["LLM_PROVIDER"] || "ollama").to_sym
LLM_MODEL    = ENV["LLM_MODEL"]    || "qwen3-coder:30b"
LLM_API_BASE = ENV["LLM_API_BASE"] || "http://localhost:11434/v1"

# Patch: Ollama models are local and not in RubyLLM's registry.
# Both self_agency and chaos_to_the_rescue call RubyLLM.chat without
# assume_model_exists, so we inject it here.
module OllamaAssumeExists
  def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
    provider            ||= LLM_PROVIDER
    assume_model_exists ||= (provider == :ollama)
    super
  end
end
RubyLLM::Chat.prepend(OllamaAssumeExists)

# Patch: ChaosToTheRescue::Logger lacks .instance but the gem calls it
unless ChaosToTheRescue::Logger.respond_to?(:instance)
  ChaosToTheRescue::Logger.define_singleton_method(:instance) do
    @instance ||= new
  end
end

SelfAgency.configure do |config|
  config.provider        = LLM_PROVIDER
  config.model           = LLM_MODEL
  config.api_base        = LLM_API_BASE
  config.request_timeout = 300
  config.logger          = ->(stage, msg) { Department.shared_logger.debug "[SelfAgency:#{stage}] #{msg}" }
end

ChaosToTheRescue.configure do |config|
  config.enabled             = true
  config.auto_define_methods = true
  config.allow_everything!
  config.model               = LLM_MODEL
  config.log_level           = :info
end

RobotLab.configure do |config|
  config.default_provider = LLM_PROVIDER
  config.default_model    = LLM_MODEL
end

Department.shared_logger.level = :info

# ---------------------------------------------------------------
# Setup: Configure shared bus with typed channels
# ---------------------------------------------------------------

Department.attach(Department.shared_bus)

# ---------------------------------------------------------------
# City-wide reactive memory via RobotLab
# ---------------------------------------------------------------

CITY_MEMORY = RobotLab.create_memory(data: {
  active_incidents: 0,
  departments:      {},
  total_dispatches: 0
})

# ---------------------------------------------------------------
# 911 Emergencies
# Each has a department type and a specific incident.
# The system has never seen any of these before.
# ---------------------------------------------------------------

EMERGENCIES = [
  { dept: :fire,             incident: :structure_fire,    details: "2-story residential fully engulfed at 123 Main St" },
  { dept: :police,           incident: :burglary,          details: "Break-in in progress at 456 Oak Ave, suspect still on scene" },
  { dept: :ems,              incident: :cardiac_arrest,    details: "Male age 65, unresponsive at 789 Pine Rd" },
  { dept: :fire,             incident: :hazmat_spill,      details: "Chemical tanker overturned on Highway 101, fumes reported" },
  { dept: :animal_control,   incident: :aggressive_animal, details: "Loose aggressive dog near playground in Riverside Park" },
  { dept: :public_works,     incident: :sinkhole,          details: "Large sinkhole opened on 5th Street, road impassable" },
  { dept: :police,           incident: :traffic_accident,  details: "Multi-vehicle pileup with injuries on I-95 southbound" },
  { dept: :ems,              incident: :allergic_reaction,  details: "Child age 8, severe allergic reaction at Elm Elementary" },
  { dept: :code_enforcement, incident: :illegal_dumping,   details: "Hazardous waste dumped behind 321 Warehouse Blvd" },
  { dept: :fire,             incident: :wildfire,          details: "Brush fire approaching homes on Ridge Road, winds 30mph" },
  { dept: :police,           incident: :domestic_dispute,  details: "Neighbor reports screaming at 555 Birch Lane apt 3B" },
  { dept: :public_works,     incident: :water_main_break,  details: "Major water main break flooding intersection at 2nd and Elm" },
].freeze

# ---------------------------------------------------------------
# City 911 Dispatch Center
# ---------------------------------------------------------------

class City911Center
  attr_reader :departments, :dispatch_log

  def initialize
    @departments  = {}
    @dispatch_log = []
    @call_counter = 0
  end

  def dispatch(emergency)
    dept   = find_or_create_department(emergency[:dept])
    method = :"handle_#{emergency[:incident]}"
    @call_counter += 1
    call_id = @call_counter

    already_known = dept.class.method_defined?(method)

    puts <<~BANNER
      #{THIN_SEP}
        Dispatching to: #{dept.name}
        Method:         #{method}
        Known method:   #{already_known ? 'YES' : 'NO -- generating via chaos_to_the_rescue'}
        Details:        #{emergency[:details]}
      #{THIN_SEP}
    BANNER

    # Publish typed IncidentReport on the shared bus
    Async do
      dept.broadcast_incident(
        call_id:  call_id,
        incident: emergency[:incident],
        details:  emergency[:details],
        severity: :normal
      )
    end

    start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = dept.public_send(method, emergency[:details])
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)

    puts "  Completed in #{elapsed}s"

    # Publish typed DispatchResult on the shared bus
    Async do
      dept.broadcast_dispatch_result(
        call_id: call_id,
        handler: method,
        result:  result.to_s[0, 200],
        was_new: !already_known,
        elapsed: elapsed
      )
    end

    # Update city memory
    CITY_MEMORY.set(:active_incidents, CITY_MEMORY.get(:active_incidents).to_i + 1)
    CITY_MEMORY.set(:total_dispatches, CITY_MEMORY.get(:total_dispatches).to_i + 1)
    dept_data = CITY_MEMORY.get(:departments) || {}
    dept_data[emergency[:dept]] = { handlers: dept.generated_methods.size }
    CITY_MEMORY.set(:departments, dept_data)

    @dispatch_log << {
      call_number: call_id,
      emergency:   emergency,
      department:  dept.name,
      method:      method,
      was_new:     !already_known,
      result:      result,
      elapsed:     elapsed
    }

    result
  rescue => e
    LOG.error "Dispatching #{emergency[:incident]}: #{e.class} - #{e.message}"
    nil
  end

  def robot_analyze(emergency)
    dept = find_or_create_department(emergency[:dept])
    robot = dept.robot(:coordinator)
    unless robot
      LOG.warn "No coordinator robot for #{dept.name}"
      return
    end

    puts <<~BANNER
      #{THIN_SEP}
        ROBOT ANALYSIS: #{dept.name} coordinator analyzing incident
        Incident: #{emergency[:incident]}
        Details:  #{emergency[:details]}
      #{THIN_SEP}
    BANNER

    start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = robot.run(message: <<~PROMPT)
      Analyze this 911 incident and suggest a priority level (critical/high/normal).
      Also recommend the number of units to dispatch.

      Incident type: #{emergency[:incident]}
      Details: #{emergency[:details]}

      Respond with:
      PRIORITY: <level>
      UNITS: <number>
      REASONING: <brief explanation>
    PROMPT
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)

    text = result.last_text_content
    LOG.info "Robot analysis (#{elapsed}s): #{text}"
    text
  rescue => e
    LOG.error "Robot analysis: #{e.class} - #{e.message}"
    nil
  end

  def run_triage_network(emergency)
    dept = find_or_create_department(emergency[:dept])

    classifier = dept.robot(:coordinator)
    unless classifier
      LOG.warn "No coordinator robot for triage"
      return
    end

    # Build a triage network with classify -> recommend pipeline
    triage = dept.create_network(:triage) do
      task :classify, classifier, depends_on: :none
      task :recommend, classifier, depends_on: [:classify]
    end

    puts <<~BANNER
      #{THIN_SEP}
        TRIAGE NETWORK: #{dept.name} running multi-step analysis
        Network: #{dept.name}:triage
      #{THIN_SEP}
    BANNER

    start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = triage.run(
      message: "Classify this emergency and recommend a response plan: " \
               "#{emergency[:incident]} - #{emergency[:details]}"
    )
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)

    text = result.value&.last_text_content
    LOG.info "Triage result (#{elapsed}s): #{text}"
    text
  rescue => e
    LOG.error "Triage network: #{e.class} - #{e.message}"
    nil
  end

  def print_summary
    puts <<~HEADER

      #{SEPARATOR}
        DISPATCH SUMMARY
      #{SEPARATOR}

        Total 911 calls handled:  #{@dispatch_log.size}
        Departments created:      #{@departments.size}
        Methods generated:        #{@dispatch_log.count { |e| e[:was_new] }}

    HEADER

    @departments.each do |type, dept|
      entries = @dispatch_log.select { |e| e[:emergency][:dept] == type }
      handlers = entries.map { |e| e[:method] }.uniq.sort
      puts <<~DEPT
        #{dept.name} (#{handlers.size} handlers):
        #{handlers.map { |m| "    - #{m}" }.join("\n")}

      DEPT
    end
  end

  def demonstrate_self_agency(dept_type, description)
    dept = @departments[dept_type]
    unless dept
      LOG.warn "No #{dept_type} department exists yet"
      return
    end

    puts <<~BANNER
      #{THIN_SEP}
        SELF-AGENCY: #{dept.name} deliberately learning a new capability
        Description: #{description}
      #{THIN_SEP}
    BANNER

    start   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    methods = dept._(description)
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(2)

    puts "  Learned #{methods.inspect} in #{elapsed}s"

    # Publish MethodGenerated for each new method
    Array(methods).each do |m|
      source = dept.generated_source(m)
      Async do
        dept.broadcast_method_generated(
          method_name:  m,
          scope:        :instance,
          source_lines: source&.lines&.size || 0
        )
      end
    end

    methods
  rescue => e
    LOG.error "Self-agency: #{e.class} - #{e.message}"
    nil
  end

  private

  def find_or_create_department(type)
    return @departments[type] if @departments.key?(type)

    const_name = type.to_s.split("_").map(&:capitalize).join + "Department"
    dept_class = Department.dup
    Object.const_set(const_name, dept_class) unless Object.const_defined?(const_name)
    dept_class.department_name = format_name(type)

    dept = dept_class.new

    # Give it a coordinator robot
    dept.create_robot(:coordinator,
      system_prompt: "You are the coordinator for the #{dept.name}. " \
                     "You help manage resources, prioritize incidents, " \
                     "and coordinate with other departments."
    )

    # Subscribe to admin channel so the department acts on directives
    dept.subscribe_to_admin!

    puts <<~BANNER

      #{SEPARATOR}
        NEW DEPARTMENT CREATED: #{dept.name}
        Class:       #{const_name}
        Coordinator: #{dept.name}:coordinator
      #{SEPARATOR}

    BANNER

    @departments[type] = dept
  end

  def format_name(type)
    type.to_s.split("_").map(&:capitalize).join(" ") + " Department"
  end
end

# ---------------------------------------------------------------
# Phase Selection
# Usage:
#   bin/city_911.rb              # all phases (1-6)
#   bin/city_911.rb 5            # just phase 5
#   bin/city_911.rb 1 3 5        # phases 1, 3, and 5
#   bin/city_911.rb 1-3          # phases 1 through 3
#   bin/city_911.rb 2-4 6        # phases 2, 3, 4, and 6
#
# NOTE: Phases 2-6 depend on phase 1 to create departments.
#       If you skip phase 1, those phases may have no departments
#       to work with.
# ---------------------------------------------------------------

ALL_PHASES = (1..6).to_a.freeze

def parse_phases(args)
  return ALL_PHASES if args.empty?

  if args.include?("--help") || args.include?("-h")
    puts <<~USAGE
      Usage: #{$PROGRAM_NAME} [PHASES...]

      Run one or more phases of the City 911 dispatch demo.

      Examples:
        #{$PROGRAM_NAME}           # all phases (1-6)
        #{$PROGRAM_NAME} 5         # just phase 5
        #{$PROGRAM_NAME} 1 3 5     # phases 1, 3, and 5
        #{$PROGRAM_NAME} 1-3       # phases 1 through 3
        #{$PROGRAM_NAME} 2-4 6     # phases 2, 3, 4, and 6

      Phases:
        1  Reactive Dispatch      (chaos_to_the_rescue)
        2  Robot Analysis         (robot_lab)
        3  Self-Agency Learning   (self_agency)
        4  VSM-Driven Dispatch    (vsm)
        5  CommsRobot             (natural language to typed messages)
        6  Save Department Files
    USAGE
    exit 0
  end

  phases = []
  args.each do |arg|
    if arg.include?("-")
      lo, hi = arg.split("-").map(&:to_i)
      phases.concat((lo..hi).to_a)
    else
      phases << arg.to_i
    end
  end
  phases.uniq.sort
end

ACTIVE_PHASES = parse_phases(ARGV)

def run_phase?(n)
  ACTIVE_PHASES.include?(n)
end

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

puts <<~HEADER
  #{SEPARATOR}
    CITY 911 EMERGENCY DISPATCH CENTER
    Self-Adapting Department System
  #{SEPARATOR}

    LLM Provider: #{LLM_PROVIDER}
    LLM Model:    #{LLM_MODEL}
    Emergencies:  #{EMERGENCIES.size}
    Phases:       #{ACTIVE_PHASES.join(", ")}

    Typed Bus Channels: #{BusSetup::CHANNELS.keys.join(", ")}

HEADER

center = City911Center.new

# Subscribe to typed channels for logging (always active)
Async do
  Department.shared_bus.subscribe(:incident_report) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] IncidentReport: #{msg.department} / #{msg.incident} (severity: #{msg.severity})"
    delivery.ack!
  end

  Department.shared_bus.subscribe(:dispatch_result) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] DispatchResult: #{msg.department} / #{msg.handler} (#{msg.elapsed}s, new: #{msg.was_new})"
    delivery.ack!
  end

  Department.shared_bus.subscribe(:method_generated) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] MethodGenerated: #{msg.department} learned #{msg.method_name} (#{msg.source_lines} lines)"
    delivery.ack!
  end

  Department.shared_bus.subscribe(:mutual_aid_request) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] MutualAidRequest: #{msg.from_department} requests help (priority: #{msg.priority}, call: #{msg.call_id})"
    delivery.ack!
  end

  Department.shared_bus.subscribe(:resource_update) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] ResourceUpdate: #{msg.department} #{msg.resource_type} #{msg.available}/#{msg.total}"
    delivery.ack!
  end

  Department.shared_bus.subscribe(:admin) do |delivery|
    msg = delivery.message
    LOG.info "[BUS] Admin: from=#{msg.from} to=#{msg.to} body=#{msg.body[0, 100]}"
    delivery.ack!
  end
end

# ---------------------------------------------------------------
# Phase 1: Reactive Dispatch via chaos_to_the_rescue
# ---------------------------------------------------------------

if run_phase?(1)
  puts <<~PHASE
    PHASE 1: Incoming 911 Calls (Reactive Dispatch)
    Departments and methods will be created as needed.
    Typed messages (IncidentReport, DispatchResult) publish on the shared bus.

  PHASE

  EMERGENCIES.shuffle(random: Random.new(42)).each_with_index do |emergency, index|
    puts <<~CALL

      #{SEPARATOR}
        911 CALL ##{index + 1} of #{EMERGENCIES.size}
        Type: #{emergency[:incident].to_s.tr('_', ' ').upcase}
      #{SEPARATOR}
    CALL

    center.dispatch(emergency)
  end
end

# ---------------------------------------------------------------
# Phase 2: Robot Analysis
# ---------------------------------------------------------------

if run_phase?(2)
  puts <<~PHASE

    PHASE 2: Robot Analysis
    Using coordinator robots to analyze incidents.

  PHASE

  center.robot_analyze(
    { dept: :fire, incident: :structure_fire, details: "High-rise commercial building, 15 floors, smoke from 8th floor" }
  )

  center.run_triage_network(
    { dept: :police, incident: :hostage_situation, details: "Armed suspect barricaded in bank with 12 hostages" }
  )
end

# ---------------------------------------------------------------
# Phase 3: Self-Agency Learning
# ---------------------------------------------------------------

if run_phase?(3)
  puts <<~PHASE

    PHASE 3: Proactive Learning via Self-Agency
    Departments deliberately acquire new capabilities.

  PHASE

  center.demonstrate_self_agency(
    :fire,
    "a method called resource_status that returns a Hash " \
    "with keys :engines, :personnel, :water_supply each with an Integer value"
  )

  center.demonstrate_self_agency(
    :ems,
    "a method called triage_priority that accepts a description String " \
    "and returns one of these symbols: :critical, :urgent, or :stable " \
    "based on keywords in the description. " \
    "Use only pure string matching logic with no IO, no shell calls, and no metaprogramming"
  )
end

# ---------------------------------------------------------------
# Phase 4: VSM-Driven Dispatch
# ---------------------------------------------------------------

if run_phase?(4)
  puts <<~PHASE

    PHASE 4: VSM-Driven Dispatch
    Building a Viable System Model capsule for structured dispatch.

  PHASE

  driver = VSM::Drivers::OpenAI::AsyncDriver.new(
    api_key:  ENV["LLM_API_KEY"] || "ollama",
    model:    LLM_MODEL,
    base_url: LLM_API_BASE
  )

  dispatch_tool = DispatchTool.new
  dispatch_tool.center = center

  resource_tool = ResourceQueryTool.new
  resource_tool.city_memory = CITY_MEMORY

  vsm_capsule = VSM::DSL.define(:city_911) do
    identity    klass: VSM::Identity, args: {
      identity: "City 911 Emergency Dispatch",
      invariants: ["All emergencies must be dispatched", "Prioritize life-threatening incidents"]
    }
    governance   klass: VSM::Governance
    coordination klass: VSM::Coordination
    intelligence klass: VSM::Intelligence, args: {
      driver: driver,
      system_prompt: "You are the City 911 Emergency Dispatch coordinator. " \
                     "You have two tools: 'dispatch' to send emergencies to departments, " \
                     "and 'query_resources' to check department availability. " \
                     "When given an emergency, use the dispatch tool to handle it. " \
                     "Respond briefly after dispatching."
    }
    operations do
      capsule :dispatch,        klass: DispatchTool
      capsule :query_resources, klass: ResourceQueryTool
    end
  end

  vsm_capsule.children["dispatch"].center = center
  vsm_capsule.children["query_resources"].city_memory = CITY_MEMORY

  puts <<~VSM_INFO
    #{SEPARATOR}
      VSM CAPSULE BUILT: #{vsm_capsule.name}
      Roles:    #{vsm_capsule.roles.keys.join(", ")}
      Tools:    #{vsm_capsule.children.keys.join(", ")}
    #{SEPARATOR}

  VSM_INFO

  vsm_emergency = {
    dept: :ems,
    incident: :mass_casualty,
    details: "Bus accident on Highway 5, approximately 20 injured passengers"
  }

  puts "Feeding emergency through VSM capsule: #{vsm_emergency[:incident]}"

  session_id = SecureRandom.uuid
  collected_output = []

  vsm_capsule.bus.subscribe do |msg|
    case msg.kind
    when :assistant
      collected_output << msg.payload.to_s unless msg.payload.to_s.empty?
      LOG.info "[VSM] Assistant: #{msg.payload.to_s[0, 200]}"
    when :tool_call
      LOG.info "[VSM] Tool call: #{msg.payload[:tool]}(#{msg.payload[:args]})"
    when :tool_result
      LOG.info "[VSM] Tool result: #{msg.payload.to_s[0, 200]}"
    end
  end

  Async do |task|
    vsm_capsule.bus.emit(VSM::Message.new(
      kind: :user,
      payload: "Emergency: #{vsm_emergency[:incident].to_s.tr('_', ' ')}. " \
               "Department: #{vsm_emergency[:dept]}. " \
               "Details: #{vsm_emergency[:details]}. " \
               "Please dispatch this emergency.",
      meta: { session_id: session_id }
    ))

    capsule_task = vsm_capsule.run
    task.sleep(30)
    capsule_task.stop
  rescue => e
    LOG.error "VSM: #{e.class} - #{e.message}"
  end
end

# ---------------------------------------------------------------
# Phase 5: CommsRobot -- Natural Language to Typed Messages
# ---------------------------------------------------------------

if run_phase?(5)
  puts <<~PHASE

    PHASE 5: CommsRobot -- Natural Language to Typed Messages
    The CommsRobot interprets free-text and publishes typed messages.
    Message schemas discovered dynamically: #{BusSetup::CHANNELS.keys.join(", ")}

  PHASE

  comms = CommsRobot.new(bus: Department.shared_bus)
  comms.watch!

  # Ensure departments exist so they can receive admin directives
  if center.departments.empty?
    [:fire, :police, :ems].each { |type| center.send(:find_or_create_department, type) }
  end

  # --- 5a: City Council sends admin directive about budget review ---

  puts <<~ADMIN_HEADER
    #{THIN_SEP}
      City Council Admin Directive: Annual Budget Review
    #{THIN_SEP}
  ADMIN_HEADER

  directive = Admin.new(
    from: "City Council",
    to:   "all",
    body: "The annual budget review is approaching. All departments " \
          "must submit their budget requests for the upcoming fiscal year. " \
          "Requests are due by end of month."
  )

  puts "  Publishing Admin on :admin (to: all)"
  ap directive.to_h
  puts

  puts "  Waiting for department responses..."
  Async do
    Department.shared_bus.publish(:admin, directive)
  end
  puts

  # --- 5b: City Council designs the BudgetRequest message ---

  puts <<~DESIGN_HEADER
    #{THIN_SEP}
      City Council: Designing BudgetRequest message format
      The LLM will decide which fields a budget request needs.
    #{THIN_SEP}
  DESIGN_HEADER

  budget_msg_path = File.join(__dir__, "..", "messages", "budget_request.rb")
  File.delete(budget_msg_path) if File.exist?(budget_msg_path)
  Object.send(:remove_const, :BudgetRequest) if Object.const_defined?(:BudgetRequest)

  council = RobotLab.build(
    name: "city_council",
    system_prompt: <<~PROMPT
      You are the City Council budget committee. You design message formats
      for city departments to use when submitting budget requests.

      You must output ONLY a Ruby class definition — no explanation, no markdown fences.

      Follow this exact pattern:

      # frozen_string_literal: true

      # One or two lines describing when this message is published.
      class BudgetRequest < Message
        attribute :field_name, Types::Coercible::String.default("") # description
      end

      RULES:
      - The class MUST be named BudgetRequest and inherit from Message.
      - Use Dry::Struct attribute syntax exactly as shown.
      - Available types: Types::Coercible::String, Types::Coercible::Integer,
        Types::Coercible::Float, Types::Coercible::Symbol, Types::Params::Bool.
      - Use .default(...) for sensible defaults on every field.
      - Add an inline # comment describing each field.
      - Include fields appropriate for a department budget request:
        think about what a budget submission needs (department name,
        fiscal year, amounts, justification, categories, etc.)
      - Output ONLY the Ruby code. No markdown, no explanation.
    PROMPT
  )

  result = council.run(
    message: "Design a BudgetRequest message class for city departments " \
             "to submit their annual budget requests. Include fields that " \
             "capture everything the council needs to review a budget submission."
  )

  generated_code = result.last_text_content.to_s
                        .gsub(/```\w*\n?/, "").strip

  puts "  LLM generated BudgetRequest class:"
  puts generated_code.lines.map { |l| "    #{l}" }.join
  puts

  File.write(budget_msg_path, generated_code + "\n")
  puts "  Wrote #{budget_msg_path}"

  # Load the new class, register its channel, and refresh CommsRobot
  load budget_msg_path
  if Object.const_defined?(:BudgetRequest)
    channel_name = BudgetRequest.channel
    unless Department.shared_bus.channel?(channel_name)
      Department.shared_bus.add_channel(channel_name, type: BudgetRequest)
    end

    Async do
      Department.shared_bus.subscribe(channel_name) do |delivery|
        msg = delivery.message
        LOG.info "[BUS] BudgetRequest: #{msg.to_h}"
        delivery.ack!
      end
    end

    comms.refresh_catalog!
    puts "  Registered channel :#{channel_name} and refreshed CommsRobot"
    puts "  CommsRobot now knows: #{comms.catalog.keys.join(', ')}"
  else
    puts "  WARNING: BudgetRequest class not defined after loading generated code"
  end
  puts

  # --- 5c: CommsRobot relays scenarios (including a budget request) ---

  comms_scenarios = [
    "There's a massive structure fire at the old warehouse on 7th and Broadway. " \
    "Multiple floors involved, civilians may be trapped. Call ID is 50. " \
    "Fire department is responding but overwhelmed and needs immediate help " \
    "from all available units. This is critical priority.",

    "Police department currently has 15 officers available out of 20 total on duty.",

    "EMS department just finished handling cardiac arrest, call number 42. " \
    "The handler method was handle_cardiac_arrest and it took 3.5 seconds. " \
    "The method was newly generated on the fly.",

    "The Fire Department is submitting their budget request for fiscal year 2027. " \
    "They are requesting $4,500,000 for operations, citing the need for two new " \
    "engine companies and upgraded protective equipment for all personnel.",
  ]

  comms_scenarios.each_with_index do |scenario, index|
    puts <<~RELAY
      #{THIN_SEP}
        CommsRobot Relay ##{index + 1}
        Input: #{scenario[0, 100]}...
      #{THIN_SEP}
    RELAY

    published = comms.relay(scenario)
    if published.empty?
      puts "  No messages published."
      puts "  LLM raw response: #{comms.last_raw_response[0, 300]}"
    else
      published.each do |pub|
        puts "  Published #{pub[:type]} on :#{pub[:channel]}"
        ap pub[:message].to_h
      end
    end
    puts
  rescue => e
    LOG.error "CommsRobot relay ##{index + 1}: #{e.class} - #{e.message}"
    puts "  Error: #{e.class} - #{e.message}"
  end

  comms.unwatch!
end

# ---------------------------------------------------------------
# Summary (only when there's dispatch data to report)
# ---------------------------------------------------------------

if center.dispatch_log.any? || center.departments.any?
  center.print_summary

  puts <<~MEMORY

    City Memory State:
      Active incidents: #{CITY_MEMORY.get(:active_incidents)}
      Total dispatches: #{CITY_MEMORY.get(:total_dispatches)}
  MEMORY

  dept_data = CITY_MEMORY.get(:departments) || {}
  dept_data.each do |type, info|
    puts "    #{type}: #{info[:handlers]} handlers"
  end
end

# ---------------------------------------------------------------
# Phase 6: Save Department Source Files
# ---------------------------------------------------------------

if run_phase?(6)
  puts <<~PHASE

    PHASE 6: Saving Department Source Files
    Each department saves itself as a Ruby class file.

  PHASE

  center.departments.each do |type, dept|
    path = dept.save_source!
    puts "  Saved #{dept.name} -> #{path}"
  end
end
