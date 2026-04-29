class Api::V1::AuthController < ApplicationController
  before_action :validate_token, only: [ :status ]

  # Initiates the three-legged OAuth flow by redirecting the user to the authorization URL
  def login
    url = Auth::AuthService.auth_url(callback_url)
    redirect_to url, allow_other_host: true
  end

  # Handles the callback from the authorization server, exchanges the authorization code for an access token, and stores it in the session
  def callback
    code = params[:code]
    if code.nil?
      render json: { error: "Authorization code not provided" }, status: :bad_request
      return
    end
    token_response = Auth::AuthService.exchange_code_for_token(code, callback_url)
    session[:aps_access_token]  = token_response["access_token"]
    session[:aps_refresh_token] = token_response["refresh_token"]
    session[:aps_expires_at]    = Time.current.to_i + token_response["expires_in"].to_i

    redirect_to "http://localhost:4200/dashboard", allow_other_host: true
  end

  # Endpoint to check if the user is authenticated and return user information
  def status
    if session[:aps_access_token].present? && Time.current.to_i < session[:aps_expires_at].to_i
      user_info = Auth::AuthService.fetch_user_info(session[:aps_access_token])
      p user_info
      render json: {
        # TODO: Replace with actual user info retrieval logic
        authenticated: true,
        user: {
          name: user_info["name"],
          email: user_info["email"],
          job_title: user_info["job_title"]
        }
      }
    else
      render json: { authenticated: false }
    end
  end

  def logout
    reset_session
    render json: { message: "Logged out successfully" }
  end

  private

  # Helper method to construct the callback URL based on the request environment
  def callback_url
    uri = URI.parse(request.url)
    uri.path = "/api/v1/auth/callback"
    uri.query = nil
    uri.to_s
  end

  def validate_token
    Auth::AuthService.valid_access_token(session)
  end
end
