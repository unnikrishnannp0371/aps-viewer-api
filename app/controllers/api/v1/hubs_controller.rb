class Api::V1::HubsController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/hubs
  def index
    render json: dm_service.get_hubs
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /api/v1/hubs/:hub_id/projects
  def projects
    render json: dm_service.get_projects(params[:hub_id])
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end
end
