# app/services/acc/rfis_service.rb

require "cgi"
require_relative "../concerns/aps_http"

module Acc
  class RfisService
    include ApsHttp

    PAGE_LIMIT      = 20
    FETCH_LIMIT     = 50
    ACTIVE_STATUSES = %w[open submitted answered].freeze
    STATUSES        = %w[open submitted answered closed].freeze
    RFIS_PATH       = ->(project_id) { "/construction/rfis/v2/projects/#{project_id}/rfis" }

    def initialize(token:)
      @token = token
    end

    # ── Health contract (class-method shim) ───────────────────────────────
    #
    # Called by HealthController alongside IssuesService.get_all_issues_for_health.
    # Returns only the fields HealthService needs — not the full panel shape.

    def self.get_all_for_health(project_id, token)
      new(token: token).send(:fetch_all_for_health, project_id)
    rescue StandardError => e
      Rails.logger.warn("RfisService.get_all_for_health failed: #{e.message}")
      []  # non-fatal — HealthService falls back to neutral RFI score
    end

    # ── Panel API ─────────────────────────────────────────────────────────

    def list(project_id:, offset: 0, limit: PAGE_LIMIT, filters: {})
      all_rfis  = fetch_all(project_id)
      page_rfis = fetch_page(project_id, offset: offset, limit: limit, filters: filters)

      {
        rfis:      enrich_with_risk(normalize_rfis(page_rfis["results"] || [])),
        total:     page_rfis.dig("pagination", "totalResults").to_i,
        offset:    page_rfis.dig("pagination", "offset").to_i,
        limit:     page_rfis.dig("pagination", "limit").to_i,
        by_status: compute_status_counts(all_rfis),
        attention: compute_attention(all_rfis)
      }
    end

    private

    # ── Fetchers ──────────────────────────────────────────────────────────

    def fetch_all(project_id)
      paginate(RFIS_PATH[project_id], @token, page_size: FETCH_LIMIT)
    end

    # Minimal projection used by HealthService — avoids sending unnecessary
    # fields across the wire.
    def fetch_all_for_health(project_id)
      fetch_all(project_id).map do |r|
        {
          status:          r["status"],
          due_date:        r["dueDate"],
          updated_at:      r["updatedAt"],
          priority:        r["priority"],
          cost_impact:     r["costImpact"],
          schedule_impact: r["scheduleImpact"]
        }
      end
    end

    def fetch_page(project_id, offset:, limit:, filters:)
      params = { offset: offset, limit: [ limit, PAGE_LIMIT ].min }
      params["filter[status]"] = filters[:status] if filters[:status].present?
      params["filter[title]"]  = filters[:title]  if filters[:title].present?
      get("#{RFIS_PATH[project_id]}?#{build_params(params)}", @token)
    end

    # ── Attention KPIs ─────────────────────────────────────────────────────

    def compute_attention(all_rfis)
      today  = Date.today
      active = all_rfis.select { |r| ACTIVE_STATUSES.include?(r["status"]) }

      overdue          = active.select { |r| r["dueDate"].present? && Date.parse(r["dueDate"]) < today }
      high_priority    = active.select { |r| r["priority"] == "High" }
      cost_or_schedule = active.select { |r| r["costImpact"] == "Yes" || r["scheduleImpact"] == "Yes" }

      {
        overdue:           overdue.count,
        high_priority:     high_priority.count,
        cost_or_schedule:  cost_or_schedule.count,
        avg_response_days: average_response_days(all_rfis)
      }
    end

    def average_response_days(all_rfis)
      closed = all_rfis.select { |r| r["status"] == "closed" && r["createdAt"].present? && r["updatedAt"].present? }
      return nil if closed.empty?

      total = closed.sum { |r| (Date.parse(r["updatedAt"]) - Date.parse(r["createdAt"])).to_i.abs }
      (total.to_f / closed.count).round(1)
    end

    # ── Status counts ──────────────────────────────────────────────────────

    def compute_status_counts(all_rfis)
      grouped = all_rfis.group_by { |r| r["status"] }
      STATUSES.each_with_object({ total: all_rfis.count }) do |status, h|
        h[status] = (grouped[status] || []).count
      end
    end

    # ── Risk enrichment ────────────────────────────────────────────────────

    def enrich_with_risk(rfis)
      today = Date.today
      rfis.map { |r| r.merge(risk_level: risk_level(r, today)) }
    end

    def risk_level(rfi, today)
      return "low" if rfi[:status] == "closed"

      due_date      = rfi[:due_date].present? ? Date.parse(rfi[:due_date].to_s) : nil
      overdue       = due_date && due_date < today
      due_soon      = due_date && due_date <= (today + 7)
      high_priority = rfi[:priority] == "High"
      impactful     = rfi[:cost_impact] == "Yes" || rfi[:schedule_impact] == "Yes"

      if overdue || (high_priority && impactful) then "high"
      elsif due_soon || high_priority || impactful then "medium"
      else "low"
      end
    end

    # ── Normalization ──────────────────────────────────────────────────────

    def normalize_rfis(raw_list)
      raw_list.map { |r| normalize_rfi(r) }
    end

    def normalize_rfi(r)
      {
        id:                r["id"],
        rfi_number:        r["customIdentifier"],
        subject:           r["title"],
        status:            r["status"],
        due_date:          r["dueDate"],
        created_at:        r["createdAt"],
        updated_at:        r["updatedAt"],
        assigned_to:       r["assignedTo"],
        created_by:        r["createdBy"],
        official_response: r["officialResponse"],
        question:          r["question"],
        priority:          r["priority"],
        cost_impact:       r["costImpact"],
        schedule_impact:   r["scheduleImpact"],
        discipline:        r["discipline"] || [],
        category:          r["category"]   || []
      }
    end
  end
end
