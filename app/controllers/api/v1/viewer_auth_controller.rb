# app/controllers/api/v1/viewer_auth_controller.rb
class Api::V1::ViewerAuthController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  def show
    urn       = params[:urn]
    file_name = params[:file_name]

    render json: {
      urn:       urn,
      token:     current_access_token,
      file_name: file_name,
      is_shared: false
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end
end
