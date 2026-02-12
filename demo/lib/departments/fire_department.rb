require "self_agency"
require_relative "../autonomy/self_agency_replay"
require_relative "../autonomy/self_agency_learner"

class FireDepartment < BaseDepartment
  include SelfAgency
  include SelfAgencyReplay
  include SelfAgencyLearner

  def initialize
    super(
      name:        "Fire",
      unit_prefix: "E",
      total_units: 5,
      handles:     %i[fire structure_fire wildfire]
    )
  end
end
