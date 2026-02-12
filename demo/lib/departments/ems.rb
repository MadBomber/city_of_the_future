require "self_agency"
require_relative "../autonomy/self_agency_replay"
require_relative "../autonomy/self_agency_learner"

class EMS < BaseDepartment
  include SelfAgency
  include SelfAgencyReplay
  include SelfAgencyLearner

  def initialize
    super(
      name:        "EMS",
      unit_prefix: "M",
      total_units: 3,
      handles:     %i[ems medical cardiac chest_pains injury accident]
    )
  end
end
