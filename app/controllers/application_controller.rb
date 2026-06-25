class ApplicationController < ActionController::API
  include ActionController::Cookies

  rescue_from ApsErrors::Forbidden,    with: :aps_forbidden
  rescue_from ApsErrors::NotFound,     with: :aps_not_found
  rescue_from ApsErrors::RateLimited,  with: :aps_rate_limited
  rescue_from ApsErrors::Unauthorized, with: :aps_unauthorized
  rescue_from ApsErrors::ServerError,  with: :aps_server_error

  private

  def aps_forbidden
    render json: { error: "You don't have access to this resource" }, status: :forbidden
  end

  def aps_not_found
    render json: { error: "Resource not found" }, status: :not_found
  end

  def aps_rate_limited
    render json: { error: "Too many requests, try again shortly" }, status: :too_many_requests
  end

  def aps_unauthorized
    render json: { error: "Session expired, please log in again" }, status: :unauthorized
  end

  def aps_server_error
    render json: { error: "Autodesk API unavailable" }, status: :bad_gateway
  end
end
