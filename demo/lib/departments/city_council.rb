class CityCouncil < BaseDepartment
  def initialize
    super(
      name:        "CityCouncil",
      unit_prefix: "CC",
      total_units: 1,
      handles:     []
    )
  end

  def can_handle?(_dispatch_order)
    true
  end
end
