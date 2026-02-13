# frozen_string_literal: true

Dir[File.join(__dir__, "messages", "*.rb")].each { |f| require f }
