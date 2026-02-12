DispatchOrder = Data.define(
  :call_id,
  :department,
  :units_requested,
  :priority,
  :eta,
  :description
) do
  def initialize(call_id:, department:, units_requested:, priority:, eta:, description: nil)
    super
  end
end
