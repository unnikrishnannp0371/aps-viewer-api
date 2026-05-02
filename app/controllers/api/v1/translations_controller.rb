class Api::V1::TranslationsController < ApplicationController
  before_action :validate_token

  def create
    urn = params[:urn]
    result = Aps::TranslationService.translate(urn, current_access_token)
    render json: result

  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  def status
    urn = params[:urn]
    result = Aps::TranslationService.translation_status(urn, current_access_token)
    render json: result
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
