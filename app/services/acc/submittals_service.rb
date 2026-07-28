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
    #
    # Returns the FULL filtered/enriched list (no server-side pagination) —
    # the frontend filters and paginates client-side.
    #
    # @param project_id [String]  bare ACC project GUID
    # @param filters    [Hash]    optional: { status_id:, spec_id: }
    #
    # @return [Hash] { submittals:, total:, offset:, limit:, by_status:, attention: }

    def list(project_id:, offset: 0, limit: PAGE_LIMIT, filters: {})
      user_map      = get_user_map(project_id)
      all_raw       = fetch_all(project_id)
      all_formatted = enrich_with_risk(all_raw.map { |s| normalize_submittal(s, user_map) })

      filtered = filter_submittals(all_formatted, filters)

      {
        submittals: filtered,
        total:      filtered.size,
        offset:     offset,
        limit:      limit,
        by_status:  compute_status_counts(all_formatted),
        by_spec:    group_by_spec(all_formatted),
        by_manager: group_by_manager(all_formatted),
        attention:  compute_attention(all_formatted)
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

    # autodeskId → display name. See Acc::RfisService#get_user_map for the
    # project_id-vs-container-id caveat — same applies here.
    def get_user_map(project_id)
      Rails.cache.fetch("submittals:user_map:#{project_id}", expires_in: 15.minutes) do
        paginate("/construction/admin/v1/projects/#{project_id}/users", @token, page_size: 100)
          .each_with_object({}) { |u, map| map[u["autodeskId"]] = u["name"] }
      end
    rescue StandardError => e
      Rails.logger.warn("SubmittalsService.get_user_map failed: #{e.message}")
      {}
    end

    # manager/subcontractor/ball-in-court aren't confirmed to always be user
    # ids (subcontractor in particular may be a company reference in ACC) —
    # this resolves what it can and falls back to the raw id otherwise, so a
    # miss just means "no name," not broken data.
    def resolve_user(id, user_map)
      return nil if id.blank?
      user_map[id] || id
    end

    def filter_submittals(submittals, filters)
      submittals = submittals.select { |s| s[:status_id] == filters[:status_id] }  if filters[:status_id].present?
      submittals = submittals.select { |s| s[:spec_id] == filters[:spec_id] }       if filters[:spec_id].present?
      submittals = submittals.select { |s| s[:spec_identifier] == filters[:spec] }  if filters[:spec].present?
      submittals = submittals.select { |s| s[:manager] == filters[:manager] }       if filters[:manager].present?
      submittals
    end

    # Minimal projection used by HealthService — was missing id/title/
    # created_at; added for item drill-down and to fix avg_days_to_close.
    def fetch_all_for_health(project_id)
      fetch_all(project_id).map do |s|
        {
          id:                       s["id"],
          submittal_number:         s["customIdentifierHumanReadable"] || s["identifier"]&.to_s,
          title:                    s["title"],
          status_id:                s["statusId"],
          status:                   STATUS_MAP[s["statusId"]] || "unknown",
          priority:                 s["priority"],
          due_date:                 s["dueDate"],
          required_on_job:          s["requiredOnJobDate"],
          received_from_submitter:  s["receivedFromSubmitter"],
          sent_to_review:           s["sentToReview"],
          received_from_review:     s["receivedFromReview"],
          created_at:               s["createdAt"],
          updated_at:               s["updatedAt"]
        }
      end
    end

    # ── Attention KPIs ────────────────────────────────────────────────────────
    #
    # overdue          — active + submitterDueDate passed
    # awaiting_review  — sent to review but not yet received back
    # high_priority    — active + priority = High
    # avg_review_days  — avg days sentToReview → receivedFromReview for closed items

    # Waterfall: overdue > awaiting_review > high_priority — mirrors
    # HealthService#submittal_reason so the three counts sum to the
    # active submittal count that needs attention, no overlap.
    def compute_attention(all_formatted)
      today = Date.today
      reasons = all_formatted.map { |s| attention_reason(s, today) }.tally

      {
        overdue:         reasons[:overdue] || 0,
        awaiting_review: reasons[:awaiting_review] || 0,
        high_priority:   reasons[:high_priority] || 0,
        avg_review_days: average_review_days(all_formatted)
      }
    end

    def attention_reason(s, today)
      return nil unless ACTIVE_STATUS_IDS.include?(s[:status_id])
      due = s[:effective_due_date]
      return :overdue         if due.present? && Date.parse(due) < today
      return :awaiting_review if s[:sent_to_review].present? && s[:received_from_review].blank?
      return :high_priority   if s[:priority] == "High"
      nil
    end

    def average_review_days(all_formatted)
      closed = all_formatted.select do |s|
        s[:status_id] == "3" &&
          s[:sent_to_review].present? &&
          s[:received_from_review].present?
      end
      return nil if closed.empty?

      total = closed.sum do |s|
        sent     = Date.parse(s[:sent_to_review])
        received = Date.parse(s[:received_from_review])
        (received - sent).to_i.abs
      end
      (total.to_f / closed.count).round(1)
    end

    # ── Status counts ─────────────────────────────────────────────────────────
    def compute_status_counts(all_formatted)
      grouped = all_formatted.group_by { |s| s[:status] }
      %w[required open closed void empty draft].each_with_object({}) do |status, h|
        h[status] = (grouped[status] || []).count
      end.merge(total: all_formatted.count)
    end

    # ── Facet counts ────────────────────────────────────────────────────────

    def group_by_spec(all_formatted)
      all_formatted.map { |s| s[:spec_identifier] }
             .reject(&:blank?)
             .tally
             .sort_by { |_, v| -v }.first(10).to_h
    end

    def group_by_manager(all_formatted)
      all_formatted.map { |s| s[:manager] }
             .reject(&:blank?)
             .tally
             .sort_by { |_, v| -v }.first(10).to_h
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

    def normalize_submittal(s, user_map = {})
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
        ball_in_court:              resolve_ball_in_court(s["ballInCourtUsers"], user_map),
        manager:                    resolve_user(s["manager"], user_map),
        subcontractor:              resolve_user(s["subcontractor"], user_map),
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
        created_by:                 resolve_user(s["createdBy"], user_map)
      }
    end

    # ballInCourtUsers' exact shape isn't confirmed (plain id strings vs.
    # {"autodeskId"/"id" => ...} objects) — handles both, falls back to the
    # raw entry so nothing breaks if it differs from either assumption.
    def resolve_ball_in_court(raw, user_map)
      (raw || []).map do |entry|
        id = entry.is_a?(Hash) ? (entry["autodeskId"] || entry["id"]) : entry
        resolve_user(id, user_map)
      end
    end
  end
end
