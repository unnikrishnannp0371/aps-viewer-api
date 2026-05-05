class Api::V1::ViewerController < ApplicationController
  def show
    token = params[:token]
    shared_link = SharedLink.find_by(token: token)

    if shared_link.nil?
      render json: { error: "Link not found" }, status: :not_found
      return
    end

    if shared_link.expired?
      render json: { error: "Link has expired" }, status: :gone
      return
    end

    # Get a 2-legged token for the viewer
    viewer_token = Auth::AuthService.two_legged_token

    # Increment view count
    shared_link.increment!(:view_count)

    render json: {
      urn: shared_link.urn,
      token: viewer_token,
      file_name: shared_link.file_name,
      expires_at: shared_link.expires_at
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :internal_server_error
  end
end
