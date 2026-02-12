require "self_agency"
require_relative "../autonomy/self_agency_replay"
require_relative "../autonomy/self_agency_learner"

class Utilities < BaseDepartment
  include SelfAgency
  include SelfAgencyReplay
  include SelfAgencyLearner

  def initialize
    super(
      name:        "Utilities",
      unit_prefix: "UT",
      total_units: 2,
      handles:     %i[utilities water_main gas_leak power_outage infrastructure]
    )
  end
end
