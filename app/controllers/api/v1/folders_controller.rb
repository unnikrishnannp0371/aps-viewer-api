class Api::V1::FoldersController < ApplicationController
  before_action :validate_token

  # GET folders/:folder_id/contents
  def contents
    project_id = params[:project_id]
    folder_id = params[:folder_id]
    data = Aps::DataManagementService.get_folder_contents(project_id, folder_id, current_access_token)
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
