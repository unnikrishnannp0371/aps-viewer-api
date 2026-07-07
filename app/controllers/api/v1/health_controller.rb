class Api::V1::HealthController < ApplicationController
  include Authenticatable
  before_action :require_3_legged_token

  # GET /api/v1/projects/:project_id/health?hub_id=...
  def index
    hub_id     = params.require(:hub_id)
    project_id = params[:project_id]

    details      = dm_service.get_project_details(hub_id, project_id)
    container_id = details[:issue_container_id]

    unless container_id
      render json: { error: "Issues not enabled for this project" }, status: :unprocessable_entity
      return
    end

    acc_id = ApplicationService.acc_project_id(project_id)
    token  = current_access_token

    issues_thread = Thread.new do
      t0 = Time.now
      result = Acc::IssuesService.new(token: token).get_all_for_health(container_id)
      Rails.logger.info("[health timing] issues: #{((Time.now - t0) * 1000).round}ms")
      result
    end
    rfis_thread = Thread.new do
      t0 = Time.now
      result = Acc::RfisService.get_all_for_health(acc_id, token)
      Rails.logger.info("[health timing] rfis: #{((Time.now - t0) * 1000).round}ms")
      result
    end
    submittals_thread = Thread.new do
      t0 = Time.now
      result = Acc::SubmittalsService.get_all_for_health(acc_id, token)
      Rails.logger.info("[health timing] submittals: #{((Time.now - t0) * 1000).round}ms")
      result
    end
    clashes_thread = Thread.new do
      t0 = Time.now
      result = Acc::ClashesService.new(token: token).summary(acc_id)
      Rails.logger.info("[health timing] clashes: #{((Time.now - t0) * 1000).round}ms")
      result
    end

    issues, rfis, submittals, clashes =
      [ issues_thread, rfis_thread, submittals_thread, clashes_thread ].map(&:value)

    render json: Acc::HealthService.calculate(issues, rfis: rfis, submittals: submittals, clashes: clashes)

  rescue StandardError => e
    Rails.logger.error("HealthController#index — #{e.message}")
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def dm_service
    @dm_service ||= Aps::DataManagementService.new(token: current_access_token)
  end
end
