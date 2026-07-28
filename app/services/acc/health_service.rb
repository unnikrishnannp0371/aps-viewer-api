# Calculates project health from live ACC data, expressed as
# resolved/total counts per domain (not a raw point score).
#
# app/services/acc/health_service.rb
#
# "needs_attention" per domain is a UNION of flags (open OR overdue OR
# unassigned OR stale, etc.) via a single distinct count — NOT a sum of
# per-flag counts, since an item can match more than one flag at once.
# resolved = total - needs_attention, so the two are always consistent.
#
# Weights (used only for the overall 0-100 score/grade):
#   Issues      40%
#   RFIs        25%
#   Submittals  20%
#   Clashes     15%

module Acc
  class HealthService < ApplicationService
    WEIGHTS = { issues: 0.40, rfis: 0.25, submittals: 0.20, clashes: 0.15 }.freeze

    class << self
      def calculate(issues, rfis: [], submittals: [], clashes: nil)
        today = Date.today

        domains = {
          issues:     issues_domain(issues, today),
          rfis:       rfi_domain(rfis, today),
          submittals: submittal_domain(submittals, today),
          clashes:    clash_domain(clashes)
        }
        domains.each { |key, d| d[:weight] = WEIGHTS.fetch(key) }

        overall = calculate_overall(domains)

        {
          overall:        overall,
          grade:          grade(overall),
          label:          label(overall),
          domains:        domains,
          signals:        build_signals(issues, rfis, submittals, clashes, today),
          calculated_at:  Time.current.iso8601,
          data_available: issues.any? || rfis.any? || submittals.any?
        }
      end

      private

      # ── Shared domain shape ─────────────────────────────────────────────────
      # Every domain returns: total, needs_attention, resolved, score (0-100),
      # neutral (true when there's no data yet), avg_days_to_close.
      def domain_result(total:, needs_attention:, neutral: false)
        na    = neutral ? 0 : [ needs_attention, total ].min
        score = (neutral || total.zero?) ? 50 : (100 - (na.to_f / total * 100)).round
        {
          total:           total,
          needs_attention: na,
          resolved:        total - na,
          score:           score,
          neutral:         neutral
        }
      end

      # ── Issues ──────────────────────────────────────────────────────────────
      ACTIVE_ISSUE_STATUSES = %w[open pending in_review].freeze

      def issues_domain(issues, today)
        return domain_result(total: 0, needs_attention: 0, neutral: true).merge(avg_days_to_close: nil) if issues.blank?

        na = issues.count { |i| issue_reason(i, today) }
        domain_result(total: issues.count, needs_attention: na)
          .merge(avg_days_to_close: avg_days_to_close(issues))
      end

      # Each issue gets AT MOST ONE reason, so overdue+stale+unassigned always
      # sums to exactly needs_attention — no double counting to explain away.
      # Priority: overdue > stale > unassigned.
      def issue_reason(i, today)
        return nil unless ACTIVE_ISSUE_STATUSES.include?(i[:status])
        return :overdue    if overdue(i[:due_date], today)
        return :stale      if i[:status] == "open" && stale_since?(i[:created_at], today)
        return :unassigned if i[:assigned_to].blank?
        nil
      end

      # ── RFIs ──────────────────────────────────────────────────────────────
      RFI_ACTIVE_STATUSES = %w[open submitted answered].freeze

      def rfi_domain(rfis, today)
        return domain_result(total: 0, needs_attention: 0, neutral: true).merge(avg_days_to_close: nil) if rfis.blank?

        na = rfis.count { |r| rfi_reason(r, today) }
        domain_result(total: rfis.count, needs_attention: na)
          .merge(avg_days_to_close: avg_days_to_close(rfis))
      end

      # Priority: overdue > high_priority > cost_or_schedule.
      def rfi_reason(r, today)
        return nil unless RFI_ACTIVE_STATUSES.include?(r[:status].to_s)
        return :overdue          if overdue(r[:due_date], today)
        return :high_priority    if r[:priority] == "High"
        return :cost_or_schedule if r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes"
        nil
      end

      # ── Submittals ──────────────────────────────────────────────────────────
      SUB_ACTIVE_STATUSES = %w[required open draft].freeze

      def submittal_domain(submittals, today)
        return domain_result(total: 0, needs_attention: 0, neutral: true).merge(avg_days_to_close: nil) if submittals.blank?

        na = submittals.count { |s| submittal_reason(s, today) }
        domain_result(total: submittals.count, needs_attention: na)
          .merge(avg_days_to_close: avg_days_to_close(submittals))
      end

      # Priority: overdue > awaiting_review > high_priority.
      def submittal_reason(s, today)
        return nil unless SUB_ACTIVE_STATUSES.include?(s[:status].to_s)
        due = s[:due_date] || s[:submitter_due_date] || s[:required_on_job]
        return :overdue         if overdue(due, today)
        return :awaiting_review if s[:sent_to_review].present? && s[:received_from_review].blank? &&
                                    Date.parse(s[:sent_to_review].to_s) < (today - 7)
        return :high_priority   if s[:priority] == "High"
        nil
      end

      # ── Clashes ─────────────────────────────────────────────────────────────
      def clash_domain(clashes)
        if clashes.nil? || clashes[:total].to_i.zero?
          return domain_result(total: 0, needs_attention: 0, neutral: true).merge(avg_days_to_close: nil)
        end
        total  = clashes[:total].to_i
        closed = clashes.dig(:by_status, :closed).to_i
        domain_result(total: total, needs_attention: total - closed).merge(avg_days_to_close: nil)
      end

      # ── Shared date helpers ───────────────────────────────────────────────
      def overdue(due_date, today)
        due_date.present? && Date.parse(due_date.to_s) < today
      end

      def stale_since?(created_at, today, days: 30)
        created_at.present? && Date.parse(created_at.to_s) < (today - days)
      end

      # avg days created_at -> updated_at, for items whose status is "closed".
      # Used for Issues and RFIs. Not used for Clashes (no lifecycle dates).
      def avg_days_to_close(items)
        closed = items.select { |i| i[:status].to_s == "closed" && i[:created_at].present? && i[:closed_at].present? }
        return nil if closed.empty?
        total = closed.sum { |i| (Date.parse(i[:closed_at].to_s) - Date.parse(i[:created_at].to_s)).to_i.abs }
        (total.to_f / closed.count).round(1)
      end

      # ── Overall / grade / label ─────────────────────────────────────────────
      def calculate_overall(domains)
        domains.reject { |_, d| d[:neutral] }
               .sum { |_, d| d[:score] * d[:weight] }
               .round
      end

      def grade(score)
        case score
        when 85..100 then "A"
        when 70..84  then "B"
        when 55..69  then "C"
        when 40..54  then "D"
        else              "F"
        end
      end

      def label(score)
        case score
        when 85..100 then "Healthy"
        when 70..84  then "Good"
        when 55..69  then "At Risk"
        when 40..54  then "Critical"
        else              "In Crisis"
        end
      end

      # ── Signals (Needs Attention panel) ──────────────────────────────────
      # Rows tagged group: "reason" are mutually exclusive by construction
      # (each item counted under exactly one reason via issue_reason/
      # rfi_reason/submittal_reason), so they sum exactly to needs_attention —
      # no double counting to explain away. Rows tagged group: "info" are
      # context only (e.g. total active count) and are never implied to sum
      # with anything.

      def build_signals(issues, rfis, submittals, clashes, today)
        active_issues = issues.select { |i| ACTIVE_ISSUE_STATUSES.include?(i[:status]) }
        issue_reasons = issues.map { |i| issue_reason(i, today) }.tally
        closed_week   = closed_recently(issues, today, days: 7)

        rfi_reasons = rfis.map { |r| rfi_reason(r, today) }.tally

        sub_reasons = submittals.map { |s| submittal_reason(s, today) }.tally

        [
          { key: "active_issues",     label: "Active Issues",        value: active_issues.count,             severity: "good",                                       domain: "issues",     group: "info"   },
          { key: "overdue_issues",    label: "Overdue Issues",       value: issue_reasons[:overdue] || 0,    severity: severity(issue_reasons[:overdue] || 0, 3, 1),  domain: "issues",     group: "reason" },
          { key: "stale_issues",      label: "Stale (not overdue)",  value: issue_reasons[:stale] || 0,      severity: severity(issue_reasons[:stale] || 0, 5, 2),    domain: "issues",     group: "reason" },
          { key: "unassigned_issues", label: "Unassigned (other)",   value: issue_reasons[:unassigned] || 0, severity: (issue_reasons[:unassigned] || 0) > 0 ? "warning" : "good", domain: "issues", group: "reason" },
          { key: "closed_this_week",  label: "Issues Closed (7d)",   value: closed_week.count,               severity: closed_week.count > 0 ? "good" : "warning",   domain: "issues",     group: "info"   },

          { key: "overdue_rfis",      label: "Overdue RFIs",              value: rfi_reasons[:overdue] || 0,          severity: severity(rfi_reasons[:overdue] || 0, 2, 1),       domain: "rfis", group: "reason" },
          { key: "high_priority_rfis", label: "High Priority (not overdue)", value: rfi_reasons[:high_priority] || 0, severity: severity(rfi_reasons[:high_priority] || 0, 3, 1), domain: "rfis", group: "reason" },
          { key: "impactful_rfis",    label: "Cost/Schedule Impact (other)", value: rfi_reasons[:cost_or_schedule] || 0, severity: severity(rfi_reasons[:cost_or_schedule] || 0, 3, 1), domain: "rfis", group: "reason" },

          { key: "overdue_subs",      label: "Overdue Submittals",             value: sub_reasons[:overdue] || 0,         severity: severity(sub_reasons[:overdue] || 0, 3, 1),         domain: "submittals", group: "reason" },
          { key: "awaiting_review",   label: "Awaiting Review (not overdue)",  value: sub_reasons[:awaiting_review] || 0, severity: severity(sub_reasons[:awaiting_review] || 0, 5, 2), domain: "submittals", group: "reason" },
          { key: "high_priority_subs", label: "High Priority (other)",        value: sub_reasons[:high_priority] || 0,   severity: severity(sub_reasons[:high_priority] || 0, 3, 1),   domain: "submittals", group: "reason" },

          { key: "total_clashes",   label: "Total Clashes",    value: clashes&.dig(:total).to_i,               severity: severity(clashes&.dig(:total).to_i, 100, 20),                 domain: "clashes", group: "info"   },
          { key: "new_clashes",     label: "New",              value: clashes&.dig(:by_status, :new).to_i,     severity: clashes&.dig(:by_status, :new).to_i.positive? ? "critical" : "good", domain: "clashes", group: "reason" },
          { key: "assigned_clashes", label: "Assigned",        value: clashes&.dig(:by_status, :assigned).to_i, severity: severity(clashes&.dig(:by_status, :assigned).to_i, 20, 5),   domain: "clashes", group: "reason" }
        ]
      end

      def severity(value, critical_threshold, warning_threshold)
        if value >= critical_threshold    then "critical"
        elsif value >= warning_threshold  then "warning"
        else                                   "good"
        end
      end

      def closed_recently(issues, today, days:)
        issues.select do |i|
          i[:status] == "closed" &&
            i[:updated_at].present? &&
            Date.parse(i[:updated_at].to_s) >= (today - days)
        end
      end
    end
  end
end
