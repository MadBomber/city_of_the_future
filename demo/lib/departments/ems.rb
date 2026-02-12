class EMS < BaseDepartment
  def initialize
    super(
      name:        "EMS",
      unit_prefix: "M",
      total_units: 3,
      handles:     %i[ems medical cardiac chest_pains injury accident]
    )
  end
end
