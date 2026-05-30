require "cgi"
require_relative "../concerns/aps_http"

module Acc
  class SubmittalsService < ApplicationService
    include ApsHttp

    PAGE_LIMIT = 20
    FETCH_LIMIT = 50

    SUBMITTALS_PATH =->(project_id) { "/construction/submittals/v2/projects/#{project_id}/items" }
    # 1 - (Required), 2 - (Open), 3 - (Closed), 4 - (Void), 5 - (Empty), 6 - (Draft).

    ACTIVE_STATUS_IDS = %w[1 2 6].freeze   # required + open + draft

    STATUS_MAP = {
      "1" => "required",
      "2" => "open",
      "3" => "closed",
      "4" => "void",
      "5" => "empty",
      "6" => "draft"
  }.freeze

    def initialize(token:)
      @token = token
    end

    # ---Health Contract (class-method shim) -----------------
    # called by HealthController.
    # Returns only the fields HealthService needs — not the full panel shape.

    def self.get_all_for_health(project_id, token)
      new(token:).send(:fetch_all_for_health, project_id)
    rescue StandardError => e
      Rails.logger.warn("SubmittalsService.get_all_health failed: #{e}")
      []  # non-fatal — HealthService falls back to neutral Submittal score
    end

    # ── Instance methods (panel API) ──────────────────────────────────────────

    # Returns paginated submittals + attention + status counts.
    #
    # @param project_id [String]  bare ACC project GUID
    # @param offset     [Integer] zero-based offset
    # @param limit      [Integer] page size
    # @param filters    [Hash]    optional: { status_id:, spec_id: }
    #
    # @return [Hash] { submittals:, total:, offset:, limit:, by_status:, attention: }

    def list(project_id:, offset: 0, limit: PAGE_LIMIT, filters: {})
      all_submittals = fetch_all(project_id)
      page_submittals = fetch_page(project_id, offset:, limit:, filters:)

      {
        submittals: enrich_with_risk((page_submittals["results"] || []).map { |s| normalize_submittal(s) }),
        total: page_submittals.dig("pagination", "totalResults").to_i,
        offset: page_submittals.dig("pagination", "offset").to_i,
        limit: page_submittals.dig("pagination", "limit").to_i,
        by_status: compute_status_counts(all_submittals),
        attention: compute_attention(all_submittals)
      }
    end

    private

    # fetchers
    def fetch_all(project_id)
      Rails.logger.debug "SubmittalsService fetching: #{SUBMITTALS_PATH[project_id]}"
      paginate(SUBMITTALS_PATH[project_id], @token, page_size: FETCH_LIMIT)
    rescue => e
      Rails.logger.error "fetch_all error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      raise
    end

    def fetch_all_for_health(project_id)
      fetch_all(project_id).map do |s|
        {
          status_id: s["statusId"],
          status: STATUS_MAP[s["statusId"]] || "unknown",
          priority: s["priority"],
          due_date: s["dueDate"],
          required_on_job: s["requiredOnJobDate"],
          received_from_submitter: s["receivedFromSubmitter"],
          sent_to_review: s["sentToReview"],
          updated_at: s["updatedAt"]
        }
      end
    end

    def fetch_page(project_id, offset:, limit:, filters:)
      params = { offset:, limit: [ limit, PAGE_LIMIT ].min }
      params["filter[statusId]"] = filters[:status_id] if filters[:status_id].present?
      params["filter[specId]"]   = filters[:spec_id]   if filters[:spec_id].present?
      get("#{SubmittalsService::SUBMITTALS_PATH[project_id]}?#{build_params(params)}", @token)
    end

    # ── Attention KPIs ────────────────────────────────────────────────────────
    #
    # overdue          — active + submitterDueDate passed
    # awaiting_review  — sent to review but not yet received back
    # high_priority    — active + priority = High
    # avg_review_days  — avg days sentToReview → receivedFromReview for closed items

    def compute_attention(all_raw)
      today  = Date.today
      active = all_raw.select { |s| ACTIVE_STATUS_IDS.include?(s["statusId"]) }

      overdue = active.select do |s|
        due = s["dueDate"] || s["submitterDueDate"] || s["requiredOnJobDate"]
        due.present? && Date.parse(due) < today
      end

      awaiting_review = active.select do |s|
        s["sentToReview"].present? && s["receivedFromReview"].blank?
      end

      high_priority = active.select { |s| s["priority"] == "High" }

      avg_review = average_review_days(all_raw)

      {
        overdue: overdue.count,
        awaiting_review: awaiting_review.count,
        high_priority: high_priority.count,
        avg_review_days: avg_review
      }
    end

    def average_review_days(all_raw)
      closed = all_raw.select do |s|
        s["statusId"] == "3" &&
          s["sentToReview"].present? &&
          s["receivedFromReview"].present?
      end
      return nil if closed.empty?

      total = closed.sum do |s|
        sent     = Date.parse(s["sentToReview"])
        received = Date.parse(s["receivedFromReview"])
        (received - sent).to_i.abs
      end
      (total.to_f / closed.count).round(1)
    end

    # ── Status counts ─────────────────────────────────────────────────────────
    def compute_status_counts(all_raw)
      grouped = all_raw.group_by { |s| STATUS_MAP[s["statusId"]] || "unknown" }
      %w[required open closed void empty draft].each_with_object({}) do |status, h|
        h[status] = (grouped[status] || []).count
      end.merge(total: all_raw.count)
    end

    # ── Risk per submittal ────────────────────────────────────────────────────
    #
    # high   — overdue OR high priority + awaiting review
    # medium — due within 7 days OR awaiting review
    # low    — everything else or closed/void

    def enrich_with_risk(submittals)
      today = Date.today
      submittals.map { |s| s.merge(risk_level: risk_level(s, today)) }
    end

    def risk_level(submittal, today)
      return "low" if %w[closed void empty].include?(submittal[:status])

      due_str    = submittal[:effective_due_date]
      due_date   = due_str.present? ? Date.parse(due_str.to_s) : nil
      overdue    = due_date && due_date < today
      due_soon   = due_date && due_date <= (today + 7)
      high_prio  = submittal[:priority] == "High"
      in_review  = submittal[:sent_to_review].present? && submittal[:received_from_review].blank?

      if overdue || (high_prio && in_review)
        "high"
      elsif due_soon || in_review
        "medium"
      else
        "low"
      end
    end

    def normalize_submittal(s)
      {
        id:                         s["id"],
        submittal_number:           s["customIdentifierHumanReadable"] || s["identifier"]&.to_s,
        title:                      s["title"],
        description:                s["description"],
        status:                     STATUS_MAP[s["statusId"]] || "unknown",
        status_id:                  s["statusId"],
        state_id:                   s["stateId"],
        priority:                   s["priority"],
        revision:                   s["revision"],
        spec_id:                    s["specId"],
        spec_title:                 s["specTitle"],
        spec_identifier:            s["specIdentifier"],
        subsection:                 s["subsection"],
        package_id:                 s["packageId"],
        package_title:              s["packageTitle"],
        ball_in_court:              s["ballInCourtUsers"] || [],
        manager:                    s["manager"],
        subcontractor:              s["subcontractor"],
        # Dates — effective_due_date picks the most relevant date for overdue calculation
        effective_due_date:         s["dueDate"] || s["submitterDueDate"] || s["requiredOnJobDate"],
        due_date:                   s["dueDate"],
        submitter_due_date:         s["submitterDueDate"],
        required_on_job:            s["requiredOnJobDate"],
        required_approval_date:     s["requiredApprovalDate"],
        sent_to_submitter:          s["sentToSubmitter"],
        received_from_submitter:    s["receivedFromSubmitter"],
        sent_to_review:             s["sentToReview"],
        received_from_review:       s["receivedFromReview"],
        published_date:             s["publishedDate"],
        responded_at:               s["respondedAt"],
        created_at:                 s["createdAt"],
        updated_at:                 s["updatedAt"],
        created_by:                 s["createdBy"]
      }
    end
  end
end
