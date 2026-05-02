class Api::V1::SharesController < ApplicationController
  before_action :validate_token

  def create
    urn       = params[:urn]
    file_name = params[:file_name]
    expires_in_days = params[:expires_in_days]&.to_i || 30

    token = generate_token
    expires_at = expires_in_days.days.from_now

    shared_link = SharedLink.create!(
      token:      token,
      urn:        urn,
      file_name:  file_name,
      expires_at: expires_at
    )

    render json: {
      url:        "#{request.base_url}/viewer/#{token}",
      token:      token,
      expires_at: shared_link.expires_at,
      file_name:  file_name
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def generate_token
    loop do
      token = SecureRandom.urlsafe_base64(16)
      break token unless SharedLink.exists?(token: token)
    end
  end

  def validate_token
    unless current_access_token
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def current_access_token
    Auth::AuthService.valid_access_token(session)
  end
end
