class Api::V1::SharesController < ApplicationController
  before_action :validate_token, only: [ :create ]

  def create
    urn = params[:urn]
    file_name = params[:file_name]
    expiry_days = params[:expires_in_days].to_i
    unless SharedLink.expiry_days.values.include?(expiry_days)
      return render json: { error: "Invalid expiry" }, status: :unprocessable_entity
    end

    enum_key = SharedLink.expiry_days.key(expiry_days)

    shared_link = SharedLink.find_or_initialize_by(
      urn: urn,
      file_name: file_name,
      expiry_days: enum_key
    )

    if shared_link.new_record? || shared_link.expired?
      shared_link.token = generate_token
      shared_link.expires_at = expiry_days.days.from_now
      shared_link.save!
    end

    render json: format_response(shared_link), status: :created

  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def frontend_url
    ENV.fetch("FRONTEND_URL", request.base_url)
  end

  def format_response(link)
    {
      url: "#{frontend_url}/view/#{link.token}",
      token: link.token,
      expires_at: link.expires_at,
      file_name: link.file_name
    }
  end

  def generate_token
    loop do
      token = SecureRandom.urlsafe_base64(16)
      break token unless SharedLink.exists?(token: token)
    end
  end

  def validate_token
    return if current_access_token

    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def current_access_token
    Auth::AuthService.valid_access_token(session)
  end
end
