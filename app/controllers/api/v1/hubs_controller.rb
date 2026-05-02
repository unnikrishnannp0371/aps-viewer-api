class Api::V1::HubsController < ApplicationController
  before_action :validate_token

  # GET /api/v1/hubs
  def index
    data = Aps::DataManagementService.get_hubs(current_access_token)
    render json: data
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  # GET /api/v1/hubs/:hub_id/projects
  def projects
    hub_id = params[:hub_id]
    data = Aps::DataManagementService.get_projects(hub_id, current_access_token)
    render json: data
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def validate_token
    unless current_access_token
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def current_access_token
    Auth::AuthService.valid_access_token(session)
  end
end
