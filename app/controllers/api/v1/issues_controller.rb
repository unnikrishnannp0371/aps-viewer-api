class Api::V1::IssuesController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/issues?hub_id=...
  def index
    container_id = project_container_id
    return unless container_id

    filters  = params.permit(:status, :type, :assigned_to, :limit, :offset).to_h
    summary  = issues_service.get_issues_summary(container_id, filters)
    render json: summary
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /api/v1/projects/:project_id/issues/:id
  def show
    container_id = params.require(:container_id)
    render json: issues_service.get_issue(container_id, params[:id])
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def project_container_id
    details = dm_service.get_project_details(params.require(:hub_id), params[:project_id])
    container_id = details[:issue_container_id]
    unless container_id
      render json: { error: "Issues not enabled for this project" }, status: :unprocessable_entity
    end
    container_id
  end

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end

  def issues_service
    @issues_service ||= Acc::IssuesService.new(token: current_access_token)
  end
end
