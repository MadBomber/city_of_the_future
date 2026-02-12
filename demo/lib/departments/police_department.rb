class PoliceDepartment < BaseDepartment
  def initialize
    super(
      name:        "Police",
      unit_prefix: "U",
      total_units: 4,
      handles:     %i[police crime crime_violent robbery assault burglary]
    )
  end
end
