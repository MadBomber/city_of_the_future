require "yaml"

class ReplayRobot
  Result = Struct.new(:last_text_content)

  def initialize(responses_path, logger: nil)
    @responses = YAML.load_file(responses_path, permitted_classes: [Symbol])
    @logger    = logger
  end

  def run(message:, **_kwargs)
    response = find_response(message)
    @logger&.info "ReplayRobot: matched response (#{response.length} chars)"
    Result.new(response)
  end

  private

  def find_response(prompt)
    @responses.each do |entry|
      next if entry["default"]
      patterns = entry["patterns"] || []
      if patterns.any? { |p| prompt.downcase.include?(p.downcase) }
        return entry["response"]
      end
    end

    default = @responses.find { |e| e["default"] }
    return default["response"] if default

    fallback
  end

  def fallback
    <<~RUBY
      ```ruby
      def handle_unknown(*args)
        { status: :acknowledged, notes: "Acknowledged" }
      end
      ```
    RUBY
  end
end
