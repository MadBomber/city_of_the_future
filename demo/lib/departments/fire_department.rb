class FireDepartment < BaseDepartment
  def initialize
    super(
      name:        "Fire",
      unit_prefix: "E",
      total_units: 5,
      handles:     %i[fire structure_fire wildfire]
    )
  end
end
