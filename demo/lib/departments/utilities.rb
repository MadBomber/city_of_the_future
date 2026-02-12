class Utilities < BaseDepartment
  def initialize
    super(
      name:        "Utilities",
      unit_prefix: "UT",
      total_units: 2,
      handles:     %i[utilities water_main gas_leak power_outage infrastructure]
    )
  end
end
