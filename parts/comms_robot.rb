# frozen_string_literal: true

require "async"
require "json"
require "listen"
require "robot_lab"
require_relative "bus_setup"

# An LLM-powered message router that receives free-text descriptions
# and publishes the appropriate typed messages on the correct bus channels.
# All message schemas are discovered dynamically — no a priori knowledge
# of any message format is hardcoded.
#
# Uses a JSON-response approach rather than tool/function calling,
# so it works with any LLM model regardless of tool support.
# Type coercion and defaults are handled by Dry::Struct.
#
# Watches the messages/ directory for changes. When a message file
# is added or modified, the catalog and robot are rebuilt automatically.
class CommsRobot
  attr_reader :catalog, :robot, :bus

  def initialize(bus:)
    @bus = bus
    @catalog = {}
    @listener = nil
    @messages_dir = File.join(__dir__, "messages")
    build_catalog!
    @robot = build_robot
  end

  # Accept a free-text string describing a situation. The LLM returns
  # JSON describing which message(s) to publish. We parse, construct,
  # and publish them on the bus. Dry::Struct handles coercion and defaults.
  # Returns an array of hashes describing what was published.
  def relay(info_string)
    result = @robot.run(message: info_string)
    @last_raw_response = result.last_text_content.to_s

    messages_json = extract_json(@last_raw_response)
    return [] if messages_json.empty?

    published = []
    messages_json.each do |msg_spec|
      channel_name = msg_spec["channel"]&.to_sym
      entry = @catalog[channel_name]

      unless entry
        puts "  WARNING: LLM returned unknown channel :#{channel_name} " \
             "(known: #{@catalog.keys.join(', ')})"
        next
      end

      fields = msg_spec["fields"] || {}
      kwargs = clean_fields(entry, fields)

      message = entry[:klass].new(**kwargs)
      Async do
        @bus.publish(channel_name, message)
      end
      published << { channel: channel_name, type: entry[:klass].name, message: message }
    end

    published
  end

  # The raw text the LLM returned on the last relay call.
  attr_reader :last_raw_response

  # Start watching the messages/ directory for file changes.
  # When files are added or modified, reload them and rebuild
  # the catalog and robot automatically.
  def watch!
    @listener&.stop
    @listener = Listen.to(@messages_dir, only: /\.rb$/) do |modified, added, _removed|
      (modified + added).each do |f|
        load f
      rescue Dry::Struct::RepeatedAttributeError
        # Class already loaded with these attributes — skip
      end
      register_new_channels!
      refresh_catalog!
    end
    @listener.start
  end

  # Stop watching the messages/ directory.
  def unwatch!
    @listener&.stop
    @listener = nil
  end

  # Rebuild the schema catalog and robot from current Message subclasses.
  def refresh_catalog!
    @catalog = {}
    build_catalog!
    @robot = build_robot
  end

  private

  # -------------------------------------------------------------------
  # Catalog Discovery — scans all Message subclasses
  # -------------------------------------------------------------------

  def build_catalog!
    discover_message_classes.each do |klass|
      channel_name = klass.channel
      comments = parse_source_comments(klass)

      @catalog[channel_name] = {
        klass:             klass,
        members:           klass.attribute_names,
        class_description: comments[:header],
        field_info:        comments[:fields]
      }
    end
  end

  # Find all concrete Message subclasses (those with a name).
  def discover_message_classes
    ObjectSpace.each_object(Class).select do |klass|
      klass < Message && klass.name
    end
  end

  # Register bus channels for any Message subclasses not yet on the bus.
  def register_new_channels!
    discover_message_classes.each do |klass|
      channel_name = klass.channel
      @bus.add_channel(channel_name, type: klass) unless @bus.channel?(channel_name)
    end
  end

  # -------------------------------------------------------------------
  # Source Comment Parsing
  # -------------------------------------------------------------------

  def parse_source_comments(klass)
    path = source_path_for(klass)
    return { header: "", fields: {} } unless path && File.exist?(path)

    lines = File.readlines(path)
    header_lines = []
    field_descriptions = {}
    in_class = false

    lines.each do |line|
      stripped = line.strip

      next if stripped == "# frozen_string_literal: true"
      next if stripped.empty? && !in_class

      if stripped.start_with?("#") && !in_class
        header_lines << stripped.sub(/^#\s?/, "")
      end

      in_class = true if stripped.match?(/^class\s+\w+/)

      if in_class && stripped =~ /attribute\s+:(\w+),\s*.+#\s*(.+)$/
        field_descriptions[Regexp.last_match(1).to_sym] = Regexp.last_match(2).strip
      end
    end

    {
      header: header_lines.join(" ").strip,
      fields: field_descriptions
    }
  end

  def source_path_for(klass)
    filename = klass.name
                    .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                    .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                    .downcase + ".rb"
    File.join(@messages_dir, filename)
  end

  # -------------------------------------------------------------------
  # Robot Construction
  # -------------------------------------------------------------------

  def build_robot
    RobotLab.build(
      name: "comms_robot",
      system_prompt: build_system_prompt
    )
  end

  def build_system_prompt
    channel_docs = @catalog.map do |channel_name, entry|
      fields = entry[:members].map do |m|
        desc = entry[:field_info][m] || m.to_s.tr("_", " ")
        "      #{m}: #{desc}"
      end.join("\n")

      <<~DOC
        Channel: #{channel_name}
          Message type: #{entry[:klass].name}
          When to use: #{entry[:class_description]}
          Fields:
        #{fields}
      DOC
    end.join("\n")

    <<~PROMPT
      You are the CommsRobot for a City 911 Emergency Dispatch system.

      Your job is to interpret free-text descriptions and determine which typed
      message(s) to publish on the city's message bus. You MUST choose the
      correct channel based on the content — do NOT default to "incidents".

      CHANNEL ROUTING RULES (use these to pick the right channel):

      - "incident_report" — ONLY for new 911 calls or emergencies being reported.
        Keywords: fire, accident, crime, medical emergency, hazmat, etc.

      - "dispatch_result" — ONLY for reports about a COMPLETED dispatch.
        Keywords: finished handling, completed, took N seconds, elapsed, result.

      - "mutual_aid_request" — ONLY for requests where a department needs help from others.
        Keywords: overwhelmed, needs help, requesting assistance, all available units.

      - "resource_update" — ONLY for status updates about department capacity/availability.
        Keywords: N available, N total, on duty, units available, resource count.

      - "method_generated" — ONLY for reports about new code methods being created.
        Keywords: learned, generated method, new capability, source lines.

      - "admin" — ONLY for directives, memos, or announcements from leadership.
        Keywords: directive, memo, announcement, policy, budget, compliance, notice.

      Available message schemas:

      #{channel_docs}

      RESPONSE FORMAT: You MUST respond with ONLY a JSON array. No other text.
      Each element has "channel" (string) and "fields" (object) keys.

      EXAMPLES:

      Input: "There is a fire at 123 Main St, call ID 7"
      Response: [{"channel": "incident_report", "fields": {"call_id": 7, "department": "Fire Department", "incident": "structure_fire", "details": "Fire at 123 Main St", "severity": "normal", "timestamp": ""}}]

      Input: "Police department has 15 officers available out of 20 total"
      Response: [{"channel": "resource_update", "fields": {"department": "Police Department", "resource_type": "officers", "available": 15, "total": 20}}]

      Input: "EMS finished call 42, method handle_cardiac_arrest took 3.5 seconds, was newly generated"
      Response: [{"channel": "dispatch_result", "fields": {"call_id": 42, "department": "EMS Department", "handler": "handle_cardiac_arrest", "result": "completed", "was_new": true, "elapsed": 3.5}}]

      Input: "Fire department is overwhelmed and needs help from all departments"
      Response: [{"channel": "mutual_aid_request", "fields": {"from_department": "Fire Department", "description": "Needs help from all departments", "priority": "critical", "call_id": 0}}]

      RULES:
      - CAREFULLY match the input to the correct channel using the routing rules above.
      - You may return multiple messages if the situation spans multiple channels.
      - Fill in all fields from the text. Use these defaults for missing values:
        * severity/priority: "normal" unless urgency is indicated
        * timestamp: "" (auto-filled)
        * department: infer from context or "Unknown"
        * call_id: 0 if not specified
      - Use snake_case for enum-like values (e.g., "structure_fire", "critical").
      - Respond with ONLY the JSON array. No explanation, no markdown fences.
    PROMPT
  end

  # -------------------------------------------------------------------
  # JSON Extraction
  # -------------------------------------------------------------------

  def extract_json(text)
    # Try parsing the entire text as JSON first
    return Array(JSON.parse(text)) if valid_json_array?(text)

    # Strip markdown code fences if present
    cleaned = text.gsub(/```(?:json)?\s*/, "").strip
    return Array(JSON.parse(cleaned)) if valid_json_array?(cleaned)

    # Try to find a JSON array in the text
    if text =~ /(\[[\s\S]*\])/
      candidate = Regexp.last_match(1)
      return Array(JSON.parse(candidate)) if valid_json_array?(candidate)
    end

    []
  rescue JSON::ParserError
    []
  end

  def valid_json_array?(text)
    parsed = JSON.parse(text)
    parsed.is_a?(Array)
  rescue JSON::ParserError
    false
  end

  # -------------------------------------------------------------------
  # Field Construction
  # -------------------------------------------------------------------

  # Strip empty/nil values so Dry::Struct defaults kick in.
  def clean_fields(entry, fields)
    kwargs = {}
    entry[:members].each do |member|
      raw = fields[member.to_s]
      kwargs[member] = raw unless raw.nil? || raw.to_s.strip.empty?
    end
    kwargs
  end
end
