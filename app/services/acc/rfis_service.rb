require "cgi"
require_relative "../concerns/aps_http"

module Acc
  class RfisService < ApplicationService
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
    #
    # Returns the FULL filtered/enriched list (no server-side pagination) —
    # the frontend filters and paginates client-side.

    def list(project_id:, offset: 0, limit: PAGE_LIMIT, filters: {})
      user_map      = get_user_map(project_id)
      all_raw       = fetch_all(project_id)
      all_formatted = enrich_with_risk(normalize_rfis(all_raw, user_map))

      filtered = filter_rfis(all_formatted, filters)

      {
        rfis:          filtered,
        total:         filtered.size,
        offset:        offset,
        limit:         limit,
        by_status:     compute_status_counts(all_formatted),
        by_discipline: group_by_discipline(all_formatted),
        by_assignee:   group_by_assignee(all_formatted),
        attention:     compute_attention(all_formatted)
      }
    end

    private

    # ── Fetchers ──────────────────────────────────────────────────────────

    def fetch_all(project_id)
      paginate(RFIS_PATH[project_id], @token, page_size: FETCH_LIMIT)
    end

    # autodeskId → display name. Mirrors Acc::IssuesService#get_user_map.
    #
    # NOTE: uses project_id directly (same id RFIs/Submittals already call the
    # construction APIs with). Issues resolves a separate issue_container_id
    # via DataManagementService#get_project_details because ACC's Issues
    # container can differ from the project id. If that's also true for RFIs/
    # Submittals admin users, this will come back empty and names will fall
    # back to raw ids — flag it if that happens.
    def get_user_map(project_id)
      Rails.cache.fetch("rfis:user_map:#{project_id}", expires_in: 15.minutes) do
        paginate("/construction/admin/v1/projects/#{project_id}/users", @token, page_size: 100)
          .each_with_object({}) { |u, map| map[u["autodeskId"]] = u["name"] }
      end
    rescue StandardError => e
      Rails.logger.warn("RfisService.get_user_map failed: #{e.message}")
      {}
    end

    def filter_rfis(rfis, filters)
      rfis = rfis.select { |r| r[:status] == filters[:status] } if filters[:status].present?
      if filters[:title].present?
        needle = filters[:title].downcase
        rfis = rfis.select { |r| r[:subject]&.downcase&.include?(needle) }
      end
      rfis = rfis.select { |r| (r[:discipline] || []).include?(filters[:discipline]) } if filters[:discipline].present?
      rfis = rfis.select { |r| r[:assigned_to] == filters[:assigned_to] }               if filters[:assigned_to].present?
      rfis
    end

    # Minimal projection used by HealthService — was missing id/subject/
    # created_at, which broke avg_days_to_close (needs created_at) and made
    # per-item drill-down impossible. Added those three fields; still
    # excludes fields the health calc has no use for.
    def fetch_all_for_health(project_id)
      fetch_all(project_id).map do |r|
        {
          id:              r["id"],
          rfi_number:      r["customIdentifier"],
          subject:         r["title"],
          status:          r["status"],
          due_date:        r["dueDate"],
          created_at:      r["createdAt"],
          updated_at:      r["updatedAt"],
          priority:        r["priority"],
          cost_impact:     r["costImpact"],
          schedule_impact: r["scheduleImpact"]
        }
      end
    end

    # ── Attention KPIs ─────────────────────────────────────────────────────

    # Waterfall: overdue > high_priority > cost_or_schedule — mirrors
    # HealthService#rfi_reason so the three counts sum to the active
    # RFI count that needs attention, no overlap.
    def compute_attention(all_rfis)
      today = Date.today
      reasons = all_rfis.map { |r| attention_reason(r, today) }.tally

      {
        overdue:           reasons[:overdue] || 0,
        high_priority:     reasons[:high_priority] || 0,
        cost_or_schedule:  reasons[:cost_or_schedule] || 0,
        avg_response_days: average_response_days(all_rfis)
      }
    end

    def attention_reason(r, today)
      return nil unless ACTIVE_STATUSES.include?(r[:status])
      return :overdue          if r[:due_date].present? && Date.parse(r[:due_date]) < today
      return :high_priority    if r[:priority] == "High"
      return :cost_or_schedule if r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes"
      nil
    end

    def average_response_days(all_rfis)
      closed = all_rfis.select { |r| r[:status] == "closed" && r[:created_at].present? && r[:updated_at].present? }
      return nil if closed.empty?

      total = closed.sum { |r| (Date.parse(r[:updated_at]) - Date.parse(r[:created_at])).to_i.abs }
      (total.to_f / closed.count).round(1)
    end

    # ── Status counts ──────────────────────────────────────────────────────

    def compute_status_counts(all_rfis)
      grouped = all_rfis.group_by { |r| r[:status] }
      STATUSES.each_with_object({ total: all_rfis.count }) do |status, h|
        h[status] = (grouped[status] || []).count
      end
    end

    # ── Facet counts ────────────────────────────────────────────────────────

    def group_by_discipline(all_rfis)
      all_rfis.flat_map { |r| r[:discipline] || [] }
              .tally
              .sort_by { |_, v| -v }.first(10).to_h
    end

    def group_by_assignee(all_rfis)
      all_rfis.map { |r| r[:assigned_to] }
              .reject(&:blank?)
              .tally
              .sort_by { |_, v| -v }.first(10).to_h
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

    def normalize_rfis(raw_list, user_map = {})
      raw_list.map { |r| normalize_rfi(r, user_map) }
    end

    def normalize_rfi(r, user_map = {})
      {
        id:                r["id"],
        rfi_number:        r["customIdentifier"],
        subject:           r["title"],
        status:            r["status"],
        due_date:          r["dueDate"],
        created_at:        r["createdAt"],
        updated_at:        r["updatedAt"],
        assigned_to:       user_map[r["assignedTo"]] || r["assignedTo"],
        created_by:        user_map[r["createdBy"]]  || r["createdBy"],
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
