class Api::V1::ItemsController < ApplicationController
  before_action :validate_token

  def versions
    versions = Aps::DataManagementService.get_item_versions(
      params[:project_id],
      params[:item_id],
      current_access_token
    )
    render json: versions
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
