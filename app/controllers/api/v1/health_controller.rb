# app/controllers/api/v1/health_controller.rb
#
# Returns a project health score calculated from live ACC data.
# Currently uses Issues + RFIs — other domains return neutral
# scores until their APIs are connected.

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

    # Decode project_id to bare ACC GUID for RFI API
    acc_project_id = ApplicationService.acc_project_id(project_id)

    # Fetch all issues and RFIs for health calculation
    # RFI fetch is non-fatal — falls back to neutral score if it fails
    issues = issues_service.get_all_for_health(container_id)
    rfis   = Acc::RfisService.get_all_for_health(acc_project_id, current_access_token)

    render json: Acc::HealthService.calculate(issues, rfis)

  rescue StandardError => e
    Rails.logger.error("HealthController#index — #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end

  def issues_service
    @issues_service ||= Acc::IssuesService.new(token: current_access_token)
  end
end
