class BaseDepartment
  attr_reader :name, :unit_prefix, :total_units, :handles

  def initialize(name:, unit_prefix:, total_units:, handles:)
    @name        = name
    @unit_prefix = unit_prefix
    @total_units = total_units
    @handles     = handles.map(&:to_sym)
    @active      = {}  # call_id => unit_id
  end

  def can_handle?(dispatch_order)
    @handles.include?(dispatch_order.department.to_sym)
  end

  def handle(dispatch_order)
    return { status: :rejected, reason: "wrong type" } unless can_handle?(dispatch_order)

    needed = dispatch_order.units_requested.to_i
    needed = 1 if needed < 1

    if available_units < needed
      return { status: :rejected, reason: "insufficient units (#{available_units}/#{needed})" }
    end

    unit_id = next_unit_id
    @active[dispatch_order.call_id] = unit_id

    { status: :dispatched, unit_id: unit_id, notes: "#{@name} #{unit_id} en route" }
  end

  def resolve(call_id)
    @active.delete(call_id)
  end

  def available_units
    @total_units - @active.size
  end

  def capacity_pct
    return 1.0 if @total_units.zero?
    available_units.to_f / @total_units
  end

  def to_dept_status
    DeptStatus.new(
      department:      @name,
      available_units: available_units,
      active_calls:    @active.size,
      capacity_pct:    capacity_pct
    )
  end

  private

  def next_unit_id
    n = 1
    n += 1 while @active.values.include?("#{@unit_prefix}-#{n}")
    "#{@unit_prefix}-#{n}"
  end
end
