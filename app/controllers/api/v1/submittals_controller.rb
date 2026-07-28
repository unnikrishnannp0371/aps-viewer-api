class Api::V1::SubmittalsController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/submittals
  def index
    result = submittals_service.list(
      project_id: acc_project_id,
      offset:     params.fetch(:offset, 0).to_i,
      limit:      params.fetch(:limit, Acc::SubmittalsService::PAGE_LIMIT).to_i,
      filters:    extract_filters
    )
    render json: result
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def acc_project_id
    @acc_project_id ||= ApplicationService.acc_project_id(params[:project_id])
  end

  def submittals_service
    @submittals_service ||= Acc::SubmittalsService.new(token: current_access_token)
  end

  def extract_filters
    {}.tap do |f|
      f[:status_id] = params[:status_id] if params[:status_id].present?
      f[:spec_id]   = params[:spec_id]   if params[:spec_id].present?
      f[:spec]      = params[:spec]      if params[:spec].present?
      f[:manager]   = params[:manager]   if params[:manager].present?
    end
  end
end
