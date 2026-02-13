# frozen_string_literal: true

DispatchResult = Data.define(:call_id, :department, :method, :result, :was_new, :elapsed)
