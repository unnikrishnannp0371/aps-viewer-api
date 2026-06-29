class Api::V1::ClashesController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/clashes/summary?hub_id=...
  def summary
    container_id = ApplicationService.acc_project_id(params.require(:project_id))
    data         = clashes_service.summary(container_id)
    render json: data
  rescue RestClient::NotFound, RestClient::Forbidden
    render json: { total: 0, by_status: { new: 0, assigned: 0, closed: 0 }, modelsets: [] }
  rescue StandardError => e
    Rails.logger.error("ClashesController#summary: #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def clashes_service
    @clashes_service ||= Acc::ClashesService.new(token: current_access_token)
  end
end
