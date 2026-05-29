class Api::V1::FoldersController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/folders/:folder_id/contents
  def contents
    render json: dm_service.get_folder_contents(params[:project_id], params[:folder_id])
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end
end
