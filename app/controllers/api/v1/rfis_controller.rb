class Api::V1::RfisController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/rfis?hub_id=...
  def index
    result = rfi_service.list(
      project_id: acc_project_id,
      offset:     params.fetch(:offset, 0).to_i,
      limit:      params.fetch(:limit, Acc::RfisService::PAGE_LIMIT).to_i,
      filters:    extract_filters
    )
    render json: result
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  # Decodes the base64 project_id and strips the b. prefix in one place.
  # RfisService (and all ACC construction APIs) expect a bare UUID — no "b." prefix.
  def acc_project_id
    @acc_project_id ||= ApplicationService.acc_project_id(params[:project_id])
  end

  def rfi_service
    @rfi_service ||= Acc::RfisService.new(token: current_access_token)
  end

  # Maps permitted controller params to the filter keys RfisService expects.
  # Note: RfisService uses :title for subject searches, not :subject.
  def extract_filters
    {}.tap do |f|
      f[:status]      = params[:status]      if params[:status].present?
      f[:title]       = params[:title]       if params[:title].present?
      f[:discipline]  = params[:discipline]  if params[:discipline].present?
      f[:assigned_to] = params[:assigned_to] if params[:assigned_to].present?
    end
  end
end
