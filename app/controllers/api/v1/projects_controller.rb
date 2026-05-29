class Api::V1::ProjectsController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/hubs/:hub_id/projects/:project_id/folders
  def top_folders
    render json: dm_service.get_top_folders(params[:hub_id], params[:project_id])
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end
end
