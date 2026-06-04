class Api::V1::HealthController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/health?hub_id=...
  def index
    hub_id     = params.require(:hub_id)
    project_id = params[:project_id]

    details      = dm_service.get_project_details(hub_id, project_id)
    container_id = details[:issue_container_id]

    unless container_id
      render json: { error: "Issues not enabled for this project" }, status: :unprocessable_entity
      return
    end

    project_id = ApplicationService.acc_project_id(project_id)

    issues     = issues_service.get_all_for_health(container_id)
    rfis       = Acc::RfisService.get_all_for_health(project_id, current_access_token)
    submittals = Acc::SubmittalsService.get_all_for_health(project_id, current_access_token)

    render json: Acc::HealthService.calculate(issues, rfis: rfis, submittals: submittals)
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end

  def issues_service
    @issues_service ||= Acc::IssuesService.new(token: current_access_token)
  end
end
