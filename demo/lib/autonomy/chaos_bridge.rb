require "async"
require_relative "code_extractor"

class ChaosBridge
  def initialize(robot:, logger: nil)
    @robot  = robot
    @logger = logger
  end

  def attach(bus)
    @bus = bus
  end

  def watch(klass)
    bridge = self

    klass.define_method(:method_missing) do |method_name, *args, **kwargs, &block|
      bridge.on_method_missing(self.class, method_name, args)
      super(method_name, *args, **kwargs, &block)
    end

    klass.define_method(:respond_to_missing?) do |method_name, include_private = false|
      super(method_name, include_private)
    end
  end

  def on_method_missing(klass, method_name, args)
    @logger&.info "ChaosBridge: #{klass.name}##{method_name} missing"

    @bus.publish(:display, DisplayEvent.new(
      type:      :method_missing,
      data:      { class: klass.name, method: method_name.to_s },
      timestamp: Time.now
    ))

    # Async generation — method_missing will raise NoMethodError via super,
    # but the generation runs in the background
    class_name  = klass.name
    method_str  = method_name.to_s
    args_str    = args.inspect

    Async do
      generate_method(class_name, method_str, args_str)
    rescue => e
      @logger&.error "ChaosBridge generation failed: #{e.message}"
    end
  end

  private

  def generate_method(class_name, method_name, args_str)
    prompt = <<~PROMPT
      Generate a Ruby instance method named `#{method_name}` for class `#{class_name}`.
      It was called with: #{args_str}
      Context: 911 emergency dispatch system.
      Return ONLY a def...end block. No class wrapper. No explanations.
      The method should return a Hash with status information.
      Do NOT use system, exec, eval, File, IO, or shell commands.
    PROMPT

    result = @robot.run(message: prompt)
    content = result.last_text_content
    source  = CodeExtractor.extract(content)

    if source
      @logger&.info "ChaosBridge: generated #{class_name}##{method_name}"
      @bus.publish(:method_gen, MethodGen.new(
        target_class: class_name,
        method_name:  method_name,
        source_code:  source,
        status:       :pending
      ))
    else
      @logger&.info "ChaosBridge: failed to extract method from response"
      @bus.publish(:display, DisplayEvent.new(
        type: :method_gen_failed,
        data: { class: class_name, method: method_name, reason: "extraction failed" },
        timestamp: Time.now
      ))
    end
  end
end
