module CodeExtractor
  def self.extract(content)
    return nil if content.nil? || content.strip.empty?

    # Strategy 1: Ruby-fenced code block
    if (match = content.match(/```ruby\s*\n(.*?)```/m))
      source = match[1].strip
      return source if valid_method?(source)
    end

    # Strategy 2: Plain-fenced code block
    if (match = content.match(/```\s*\n(.*?)```/m))
      source = match[1].strip
      return source if valid_method?(source)
    end

    # Strategy 3: Bare def...end anywhere in text
    if (match = content.match(/(def\s+\w+.*?^end)/m))
      return match[1].strip
    end

    nil
  end

  def self.valid_method?(source)
    source.match?(/\Adef\s+\w+/) && source.match?(/^end\z/)
  end
end
