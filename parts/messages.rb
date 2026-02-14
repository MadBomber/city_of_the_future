# frozen_string_literal: true

require_relative "messages/message"

Dir[File.join(__dir__, "messages", "*.rb")].each { |f| require f }
