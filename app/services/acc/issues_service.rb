require "cgi"
require_relative "../concerns/aps_http"

module Acc
  class IssuesService
    include ApsHttp

    MAX_PER_PAGE    = 20
    ACTIVE_STATUSES = %w[open pending in_review].freeze
    ISSUES_PATH     = ->(container_id) { "/construction/issues/v1/projects/#{container_id}/issues" }

    def initialize(token:)
      @token = token
    end

    # ── Public interface ──────────────────────────────────────────────────

    def get_issues_summary(container_id, filters = {})
      limit  = filters.delete("limit")&.to_i  || MAX_PER_PAGE
      offset = filters.delete("offset")&.to_i || 0

      page_data = fetch_issues_page(container_id, filters, limit, offset)
      issues    = page_data["results"] || []
      total     = page_data.dig("pagination", "totalResults").to_i

      # Fetch all issues once; share the result between counts, attention, and health.
      all_formatted = fetch_all_formatted(container_id)

      {
        total:       total,
        offset:      offset,
        limit:       limit,
        by_status:   group_by_status(all_formatted),
        by_type:     group_by_type(all_formatted),
        by_assignee: group_by_assignee(all_formatted),
        attention:   compute_attention(all_formatted),
        recent_open: recent_open(issues),
        issues:      enrich_with_risk(issues.map { |i| format_issue(i) })
      }
    end

    def get_issue(container_id, issue_id)
      data = get("/construction/issues/v1/projects/#{container_id}/issues/#{issue_id}", @token)
      format_issue(data)
    end

    # Lightweight interface for HealthService — returns all formatted issues.
    def get_all_for_health(container_id)
      fetch_all_formatted(container_id)
    end

    # ── Class-method shim (backwards compat) ──────────────────────────────
    #
    # Old call sites used IssuesService.get_issues_summary(container_id, token, filters).
    # These delegate to an instance so existing controllers don't need changes yet.

    def self.get_issues_summary(container_id, access_token, filters = {})
      new(token: access_token).get_issues_summary(container_id, filters)
    end

    def self.get_issue(container_id, issue_id, access_token)
      new(token: access_token).get_issue(container_id, issue_id)
    end

    def self.get_all_issues_for_health(container_id, access_token)
      new(token: access_token).get_all_for_health(container_id)
    end

    private

    # ── Fetchers ─────────────────────────────────────────────────────────

    def fetch_all_formatted(container_id)
      paginate(ISSUES_PATH[container_id], @token).map { |i| format_issue(i) }
    end

    def fetch_issues_page(container_id, filters, limit, offset)
      params = {}
      params["filter[status]"]     = filters["status"]      if filters["status"].present?
      params["filter[assignedTo]"] = filters["assigned_to"] if filters["assigned_to"].present?
      params = build_params(params.merge(offset: offset, limit: limit))
      get("#{ISSUES_PATH[container_id]}?#{params}", @token)
    end

    # ── Attention KPIs ────────────────────────────────────────────────────

    def compute_attention(all_issues)
      today  = Date.today
      active = all_issues.select { |i| ACTIVE_STATUSES.include?(i[:status]) }

      overdue    = active.select { |i| i[:due_date].present? && Date.parse(i[:due_date].to_s) < today }
      unassigned = active.select { |i| i[:assigned_to].blank? }
      stale      = active.select { |i| i[:created_at].present? && Date.parse(i[:created_at].to_s) < (today - 30) }

      {
        overdue:        overdue.count,
        unassigned:     unassigned.count,
        stale:          stale.count,
        avg_resolution: average_resolution_days(all_issues)
      }
    end

    def average_resolution_days(all_issues)
      closed = all_issues.select { |i| i[:status] == "closed" && i[:created_at].present? && i[:updated_at].present? }
      return nil if closed.empty?

      total_days = closed.sum { |i| (Date.parse(i[:updated_at].to_s) - Date.parse(i[:created_at].to_s)).to_i.abs }
      (total_days.to_f / closed.count).round(1)
    end

    # ── Risk enrichment ───────────────────────────────────────────────────

    def enrich_with_risk(issues)
      today = Date.today
      issues.map { |i| i.merge(risk_level: risk_level(i, today)) }
    end

    def risk_level(issue, today)
      return "low" if issue[:status] == "closed"

      due_date   = issue[:due_date].present?   ? Date.parse(issue[:due_date].to_s)   : nil
      created_at = issue[:created_at].present? ? Date.parse(issue[:created_at].to_s) : nil

      overdue    = due_date   && due_date < today
      due_soon   = due_date   && due_date <= (today + 7)
      stale      = created_at && created_at < (today - 30) && ACTIVE_STATUSES.include?(issue[:status])
      unassigned = issue[:assigned_to].blank? && ACTIVE_STATUSES.include?(issue[:status])

      if overdue || stale    then "high"
      elsif due_soon || unassigned then "medium"
      else "low"
      end
    end

    # ── Grouping ──────────────────────────────────────────────────────────

    def group_by_status(issues)
      counts = issues.group_by { |i| i[:status] || "unknown" }.transform_values(&:count)
      %w[draft open pending in_review closed].each_with_object({}) { |s, h| h[s] = counts[s] || 0 }
    end

    def group_by_type(issues)
      issues.group_by { |i| i[:issue_sub_type] || "Unspecified" }
            .transform_values(&:count)
            .sort_by { |_, v| -v }.first(10).to_h
    end

    def group_by_assignee(issues)
      issues.reject { |i| i[:assigned_to].blank? }
            .group_by { |i| i[:assigned_to] }
            .transform_values(&:count)
            .sort_by { |_, v| -v }.first(10).to_h
    end

    def recent_open(issues)
      issues.select { |i| i["status"] == "open" }
            .sort_by { |i| i["createdAt"] || "" }
            .last(5).reverse
            .map { |i| format_issue(i) }
    end

    # ── Formatting ────────────────────────────────────────────────────────

    def format_issue(issue)
      {
        id:             issue["id"],
        title:          issue["title"],
        status:         issue["status"],
        issue_type:     issue["issueTypeLabel"]    || issue["issueTypeId"],
        issue_sub_type: issue["issueSubtypeLabel"] || issue["issueSubtypeId"],
        assigned_to:    issue["assignedToName"]    || issue["assignedTo"],
        due_date:       issue["dueDate"],
        created_at:     issue["createdAt"],
        updated_at:     issue["updatedAt"],
        created_by:     issue["createdBy"],
        location:       issue["locationDetails"],
        description:    issue["description"],
        pushpin:        issue["placements"],
        viewable_id:    issue.dig("linkedDocuments", 0, "urn"),
        external_id:    issue["displayId"]
      }
    end
  end
end
