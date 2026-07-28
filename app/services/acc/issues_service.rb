require "cgi"
require_relative "../concerns/aps_http"

module Acc
  class IssuesService < ApplicationService
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

      type_map = get_issue_type_map(container_id)
      user_map = get_user_map(container_id)

      all_raw       = paginate(ISSUES_PATH[container_id], @token)
      p all_raw.first(3)
      all_formatted = enrich_with_risk(all_raw.map { |i| format_issue(i, type_map, user_map) })

      filtered = filter_issues(all_formatted, filters)

      {
        total:       filtered.size,
        offset:      offset,
        limit:       limit,
        by_status:   group_by_status(all_formatted),
        by_type:     group_by_type(all_formatted),
        by_assignee: group_by_assignee(all_formatted),
        attention:   compute_attention(all_formatted),
        recent_open: recent_open(filtered),
        issues:      filtered
      }
    end

    def get_issue(container_id, issue_id)
      data = get("/construction/issues/v1/projects/#{container_id}/issues/#{issue_id}", @token)
      format_issue(data)
    end

    def get_issue_type_map(container_id)
      Rails.cache.fetch("issues:type_map:#{container_id}", expires_in: 15.minutes) do
        data = get("/construction/issues/v1/projects/#{container_id}/issue-types?include=subtypes&limit=100", @token)
        map = {}
        (data["results"] || []).each do |type|
          map[type["id"]] = type["title"]
          (type["subtypes"] || []).each do |subtype|
            map[subtype["id"]] = subtype["title"]
          end
        end
        map
      end
    end

    def get_user_map(container_id)
      Rails.cache.fetch("issues:user_map:#{container_id}", expires_in: 15.minutes) do
        paginate("/construction/admin/v1/projects/#{container_id}/users", @token, page_size: 100).each_with_object({}) do |user, map|
          map[user["autodeskId"]] = user["name"]
        end
      end
    end

    # Lightweight interface for HealthService — returns all formatted issues.
    def get_all_for_health(container_id)
      type_map = get_issue_type_map(container_id)
      user_map = get_user_map(container_id)
      fetch_all_formatted(container_id, type_map, user_map)
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

    def fetch_all_formatted(container_id, type_map = {}, user_map = {})
      paginate(ISSUES_PATH[container_id], @token).map { |i| format_issue(i, type_map, user_map) }
    end

    def filter_issues(issues, filters)
      issues = issues.select { |i| i[:status] == filters["status"] }             if filters["status"].present?
      issues = issues.select { |i| i[:issue_sub_type] == filters["type"] }       if filters["type"].present?
      issues = issues.select { |i| i[:assigned_to] == filters["assigned_to"] }   if filters["assigned_to"].present?
      issues
    end

    # ── Attention KPIs ────────────────────────────────────────────────────

    # Each issue gets AT MOST ONE reason (overdue > stale > unassigned),
    # so the three counts below always sum to the number of active issues
    # that need attention — same waterfall as HealthService#issue_reason.
    def compute_attention(all_issues)
      today = Date.today
      reasons = all_issues.map { |i| attention_reason(i, today) }.tally

      {
        overdue:        reasons[:overdue] || 0,
        unassigned:     reasons[:unassigned] || 0,
        stale:          reasons[:stale] || 0,
        avg_resolution: average_resolution_days(all_issues)
      }
    end

    def attention_reason(i, today)
      return nil unless ACTIVE_STATUSES.include?(i[:status])
      return :overdue    if i[:due_date].present? && Date.parse(i[:due_date].to_s) < today
      return :stale      if i[:status] == "open" && i[:created_at].present? && Date.parse(i[:created_at].to_s) < (today - 30)
      return :unassigned if i[:assigned_to].blank?
      nil
    end

    def average_resolution_days(all_issues)
      closed = all_issues.select { |i| i[:status] == "closed" && i[:created_at].present? && i[:closed_at].present? }
      return nil if closed.empty?

      total_days = closed.sum { |i| (Date.parse(i[:closed_at].to_s) - Date.parse(i[:created_at].to_s)).to_i.abs }
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
      issues.select { |i| i[:status] == "open" }
            .sort_by { |i| i[:created_at] || "" }
            .last(5).reverse
    end

    # ── Formatting ────────────────────────────────────────────────────────

    def format_issue(issue, type_map = {}, user_map = {})
      linked  = issue.dig("linkedDocuments", 0)
      details = linked&.dig("details")

      assigned_to = if issue["assignedToType"] == "user"
        user_map[issue["assignedTo"]]&.titleize || "User #{issue["assignedTo"]&.first(8)}"
      elsif issue["assignedToType"] == "company"
        "Company"
      end

      {
        id:             issue["id"],
        title:          issue["title"],
        status:         issue["status"],
        issue_type:     type_map[issue["issueTypeId"]]    || issue["issueTypeId"],
        issue_sub_type: type_map[issue["issueSubtypeId"]] || issue["issueSubtypeId"],
        assigned_to:    assigned_to,
        due_date:       issue["dueDate"],
        created_at:     issue["createdAt"],
        updated_at:     issue["updatedAt"],
        created_by:     user_map[issue["createdBy"]] || issue["createdBy"],
        location:       issue["locationDetails"],
        description:    issue["description"],
        viewable_id:    linked&.dig("urn"),
        external_id:    issue["displayId"],
        closed_at:      issue["closedAt"],
        pushpin: details ? {
          location:      details.dig("position"),
          objectId:      details.dig("objectId"),
          viewable_guid: details.dig("viewable", "guid"),
          seed_urn:      details.dig("viewerState", "seedURN")
        } : nil
      }
    end
  end
end
