require "self_agency"
require_relative "../autonomy/self_agency_replay"
require_relative "../autonomy/self_agency_learner"

class CityCouncil < BaseDepartment
  include SelfAgency
  include SelfAgencyReplay
  include SelfAgencyLearner

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
