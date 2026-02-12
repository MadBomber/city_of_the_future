class Governance
  DANGEROUS_PATTERNS = [
    /\bsystem\b/, /\bexec\b/, /\bspawn\b/, /\bfork\b/,
    /`[^`]*`/,
    /\beval\b/, /\bsend\b/, /\b__send__\b/, /\bpublic_send\b/,
    /\binstance_eval\b/, /\bclass_eval\b/, /\bmodule_eval\b/,
    /\brequire\b/, /\bload\b/,
    /\bFile\b/, /\bIO\b/, /\bDir\b/, /\bSocket\b/,
    /\bOpen3\b/, /\bKernel\b/, /\bProcess\b/, /\bObjectSpace\b/,
  ].freeze

  DEFAULT_ALLOWLIST = %w[
    FireDepartment PoliceDepartment EMS Utilities
    CityCouncil DroneDepartment
  ].freeze

  def initialize(allowlist: DEFAULT_ALLOWLIST, logger: nil)
    @allowlist = allowlist
    @logger    = logger
  end

  def attach(bus)
    bus.subscribe(:method_gen) do |delivery|
      gen = delivery.message
      decision, reason = evaluate(gen)

      bus.publish(:governance, PolicyEvent.new(
        action:    "install_method",
        decision:  decision,
        reason:    reason,
        timestamp: Time.now
      ))

      if decision == :approved
        install_method(gen)
        bus.publish(:display, DisplayEvent.new(
          type: :method_installed,
          data: { class: gen.target_class, method: gen.method_name,
                  source: gen.source_code },
          timestamp: Time.now
        ))
        bus.publish(:voice_out, VoiceOut.new(
          text:       "Governance approved. Method #{gen.method_name} installed on #{gen.target_class}.",
          voice:      nil,
          department: "System",
          priority:   1
        ))
        delivery.ack!
      else
        bus.publish(:display, DisplayEvent.new(
          type: :method_rejected,
          data: { class: gen.target_class, method: gen.method_name, reason: reason },
          timestamp: Time.now
        ))
        bus.publish(:voice_out, VoiceOut.new(
          text:       "Governance rejected method #{gen.method_name}. Reason: #{reason}.",
          voice:      nil,
          department: "System",
          priority:   1
        ))
        delivery.nack!
      end
    end
  end

  # Public for unit testing without a bus
  def evaluate(gen)
    unless @allowlist.include?(gen.target_class)
      return [:rejected, "Class '#{gen.target_class}' not on allowlist"]
    end

    unless gen.source_code.match?(/\bdef\s+\w+/)
      return [:rejected, "No method definition found"]
    end

    DANGEROUS_PATTERNS.each do |pattern|
      if gen.source_code.match?(pattern)
        return [:rejected, "Dangerous pattern: #{pattern.source}"]
      end
    end

    [:approved, "Passed all governance checks"]
  end

  private

  def install_method(gen)
    klass = Object.const_get(gen.target_class)
    klass.class_eval(gen.source_code)
    @logger&.info "Installed #{gen.target_class}##{gen.method_name}"
  end
end
