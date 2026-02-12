require "self_agency"
require_relative "../autonomy/self_agency_replay"
require_relative "../autonomy/self_agency_learner"

class PoliceDepartment < BaseDepartment
  include SelfAgency
  include SelfAgencyReplay
  include SelfAgencyLearner

  def initialize
    super(
      name:        "Police",
      unit_prefix: "U",
      total_units: 4,
      handles:     %i[police crime crime_violent robbery assault burglary]
    )
  end
end
