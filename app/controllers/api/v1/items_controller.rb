class Api::V1::ItemsController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/items/:item_id/versions
  def versions
    render json: dm_service.get_item_versions(params[:project_id], params[:item_id])
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end
end
