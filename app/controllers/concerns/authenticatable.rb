module Authenticatable
  extend ActiveSupport::Concern
  included do
    # Make current_access_token available as a helper
    # so you never have to call AuthService directly in a controller.
    helper_method :current_access_token if respond_to?(:helper_method)
  end

  def current_access_token
    @current_access_token ||= Auth::AuthService.valid_access_token(session)
  end

  def require_3_legged_token
    unless current_access_token
      render json: {
        error: "Unauthorized",
        auth_url: "/api/v1/login"
      }, status: :unauthorized
    end
  end
end
