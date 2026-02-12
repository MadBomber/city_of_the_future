class CityCouncil < BaseDepartment
  def initialize
    super(
      name:        "CityCouncil",
      unit_prefix: "CC",
      total_units: 1,
      handles:     []
    )
  end

  def can_handle?(dispatch_order)
    @handles.include?(dispatch_order.department.to_sym)
  end
end
