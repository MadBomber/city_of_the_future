# Override SelfAgency's LLM communication for replay mode.
# Routes the shape and generate stages through ReplayRobot
# instead of making real LLM API calls.
module SelfAgencyReplay
  private

  def self_agency_ask_with_template(template_name, **variables)
    robot = self.class.code_robot
    raise SelfAgency::GenerationError.new("No robot configured", stage: template_name) unless robot

    case template_name
    when :shape
      # Build a prompt that ReplayRobot can pattern-match against.
      # Return the shaped spec directly — no LLM needed.
      prompt = "Generate a Ruby method for class `#{variables[:class_name]}`.\n"
      prompt += "#{variables[:raw_prompt]}\n"
      prompt += "Return ONLY a def...end block. No class wrapper."
      prompt
    when :generate
      result = robot.run(message: variables[:shaped_spec])
      content = result.last_text_content
      raise SelfAgency::GenerationError.new("Generation returned nil", stage: :generate) unless content
      content
    end
  end
end
