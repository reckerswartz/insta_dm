class AiDashboardController < ApplicationController
  before_action :require_current_account!
  skip_forgery_protection only: [:test_service, :test_all_services]

  def index
    @service_status = AiDashboard::HealthChecker.new(force_refresh: refresh_requested?).call
    @ai_service_queue_metrics = Ops::AiServiceQueueMetrics.snapshot
    @runtime_audit = AiDashboard::RuntimeAudit.new(
      service_status: @service_status,
      queue_metrics: @ai_service_queue_metrics
    ).call
    @test_results = {}
  end

  def test_service
    @test_results = AiDashboard::ServiceTester.new(
      service_name: params[:service_name],
      test_type: params[:test_type]
    ).call

    respond_to do |format|
      format.json { render json: @test_results }
      format.html { 
        flash[:notice] = "Test completed for #{params[:service_name]}"
        redirect_to ai_dashboard_path 
      }
    end
  end

  def test_all_services
    @test_results = AiDashboard::ServiceTester.test_all_services

    respond_to do |format|
      format.json { render json: @test_results }
      format.html { 
        flash[:notice] = "All services tested"
        redirect_to ai_dashboard_path 
      }
    end
  end

  private

  def refresh_requested?
    ActiveModel::Type::Boolean.new.cast(params[:refresh])
  end
end
