# frozen_string_literal: true

require "self_agency"
require "robot_lab"
require "chaos_to_the_rescue"
require "typed_bus"
require "lumberjack"
require_relative "messages"

class Department
  include SelfAgency
  include ChaosToTheRescue::ChaosRescue

  chaos_rescue_enabled!

  @shared_bus    = TypedBus::MessageBus.new
  @shared_logger = Lumberjack::Logger.new($stdout)

  class << self
    attr_accessor :shared_bus, :shared_logger

    def attach(bus)
      require_relative "bus_setup"
      BusSetup.configure(bus)
      self.shared_bus = bus
      bus
    end

    def inherited(subclass)
      super
      subclass.instance_variable_set(:@shared_bus,    @shared_bus)
      subclass.instance_variable_set(:@shared_logger,  @shared_logger)
    end

    def initialize_dup(original)
      super
      @department_name = nil
      @shared_bus      = original.shared_bus
      @shared_logger   = original.shared_logger
    end

    def department_name
      @department_name ||= name || "Department"
    end

    def department_name=(value)
      @department_name = value
    end

    def save_source!(path: nil)
      const = name || department_name.gsub(/\s+/, "")
      filename = to_snake_case(const) + ".rb"
      path ||= filename

      methods_code = @chaos_class_sources&.map do |method_name, code|
        indent_block(code, 2)
      end&.join("\n\n") || ""

      File.write(path, <<~RUBY)
        # frozen_string_literal: true

        # Auto-generated: #{department_name}
        # Generated at: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}

        require_relative "department"

        class #{const} < Department
        #{methods_code}
        end
      RUBY

      path
    end

    private

    def to_snake_case(str)
      str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
    end

    def indent_block(code, spaces)
      code.lines.map { |line| line.chomp.empty? ? "\n" : (" " * spaces) + line }.join
    end
  end

  attr_reader :name, :robots, :networks, :bus

  def initialize(name: nil)
    @name     = name || self.class.department_name
    @robots   = {}
    @networks = {}
    @bus      = TypedBus::MessageBus.new
  end

  def logger
    self.class.shared_logger
  end

  # -- Source introspection --

  def generated_source(method_name)
    sources = self.class.instance_variable_get(:@chaos_class_sources)
    sources&.[](method_name.to_sym)
  end

  def generated_methods
    sources = self.class.instance_variable_get(:@chaos_class_sources)
    sources&.keys || []
  end

  # -- Chaos method tracking --
  # Override to strip markdown fences and store generated source

  def define_generated_method(method_name, code)
    cleaned = code.gsub(/```\w*\n?/, "").strip
    body    = extract_def_blocks(cleaned)

    self.class.instance_variable_set(:@chaos_class_sources, {}) unless self.class.instance_variable_get(:@chaos_class_sources)
    self.class.instance_variable_get(:@chaos_class_sources)[method_name.to_sym] = body

    super(method_name, cleaned)
  end

  # -- Save --

  def save_source!(path: nil)
    self.class.save_source!(path: path)
  end

  # -- Shared inter-department bus --

  def shared_bus
    self.class.shared_bus
  end

  def broadcast(channel_name, message)
    shared_bus.publish(channel_name, message)
  end

  def listen(channel_name, &block)
    shared_bus.subscribe(channel_name, &block)
  end

  def broadcast_incident(call_id:, incident:, details:, severity: :normal)
    broadcast(:incident_report, IncidentReport.new(
      call_id:   call_id,
      department: @name,
      incident:  incident,
      details:   details,
      severity:  severity,
      timestamp: Time.now
    ))
  end

  def broadcast_dispatch_result(call_id:, handler:, result:, was_new:, elapsed:)
    broadcast(:dispatch_result, DispatchResult.new(
      call_id:    call_id,
      department: @name,
      handler:    handler,
      result:     result,
      was_new:    was_new,
      elapsed:    elapsed
    ))
  end

  def broadcast_method_generated(method_name:, scope:, source_lines:)
    broadcast(:method_generated, MethodGenerated.new(
      department:   @name,
      method_name:  method_name,
      scope:        scope,
      source_lines: source_lines
    ))
  end

  # -- Admin channel subscription --

  def subscribe_to_admin!
    shared_bus.subscribe(:admin) do |delivery|
      msg = delivery.message
      if msg.to.downcase == "all" || msg.to.downcase == @name.downcase
        logger.info "#{@name} received admin directive from #{msg.from}: #{msg.body[0, 100]}"
        handle_admin(msg)
      end
      delivery.ack!
    end
  end

  def handle_admin(admin_msg)
    coordinator = robot(:coordinator)
    unless coordinator
      logger.warn "#{@name} has no coordinator robot to handle admin directive"
      return
    end

    result = coordinator.run(message: <<~PROMPT)
      You have received an administrative directive from #{admin_msg.from}.

      Directive: #{admin_msg.body}

      As the #{@name} coordinator, determine what actions are needed to comply
      with this directive. Describe what you will do, then do it.
      Be concise — respond in 2-3 sentences.
    PROMPT

    response = result.last_text_content.to_s
    puts "  [#{@name}] Admin response: #{response}"
    logger.info "#{@name} admin response: #{response[0, 200]}"
    response
  end

  # -- Internal department bus --

  def add_channel(channel_name, **options)
    @bus.add_channel(channel_name, **options)
  end

  def publish(channel_name, message)
    @bus.publish(channel_name, message)
  end

  def subscribe(channel_name, &block)
    @bus.subscribe(channel_name, &block)
  end

  def unsubscribe(channel_name, id_or_block)
    @bus.unsubscribe(channel_name, id_or_block)
  end

  def dead_letters(channel_name)
    @bus.dead_letters(channel_name)
  end

  # -- Robot Lab --

  def create_robot(robot_name, **options)
    robot = RobotLab.build(name: "#{@name}:#{robot_name}", **options)
    @robots[robot_name.to_sym] = robot
  end

  def create_network(network_name, **options, &block)
    network = RobotLab.create_network(name: "#{@name}:#{network_name}", **options, &block)
    @networks[network_name.to_sym] = network
  end

  def robot(robot_name)
    @robots[robot_name.to_sym]
  end

  def network(network_name)
    @networks[network_name.to_sym]
  end

  def memory
    @memory ||= RobotLab.create_memory
  end

  # -- Self Agency lifecycle --

  def on_method_generated(method_name, scope, code)
    cleaned = code.gsub(/```\w*\n?/, "").strip
    body    = extract_def_blocks(cleaned)

    self.class.instance_variable_set(:@chaos_class_sources, {}) unless self.class.instance_variable_get(:@chaos_class_sources)
    self.class.instance_variable_get(:@chaos_class_sources)[method_name.to_sym] = body

    logger.info "#{@name} learned: #{method_name} (#{scope})"
  end

  private

  def extract_def_blocks(code)
    # Split at each top-level def boundary (lookahead keeps def in each chunk)
    chunks = code.split(/(?=^[ \t]*def\s+\w+)/m)
    methods = chunks.select { |c| c.strip.match?(/\Adef\s+\w+/) }
    return code if methods.empty?

    methods.map { |chunk| close_method_block(chunk.rstrip) }.join("\n\n")
  end

  def close_method_block(code)
    depth = 0
    code.each_line do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      # Block openers only at start of (stripped) line
      depth += 1 if stripped.match?(/\A(def|if|unless|case|while|until|for|begin|class|module)\b/)
      # do..end blocks at end of line
      depth += 1 if stripped.match?(/\bdo\s*(\|.*?\|)?\s*\z/)
      # Block closers
      depth -= 1 if stripped.match?(/\Aend\b/)
    end

    depth > 0 ? "#{code}\n#{"  end\n" * depth}".rstrip : code
  end
end
