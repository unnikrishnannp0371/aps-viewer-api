# Calculates a project health score (0–100) from live ACC data.
#
# Formula is intentionally extensible — each domain returns a sub-score
# and a weight.  Domains not yet connected return a neutral score (50)
# so the overall score is still meaningful with partial data.
#
# app/services/acc/health_service.rb
#
# Weights:
#   Issues      40%  ← live
#   RFIs        25%  ← live
#   Submittals  20%  ← live
#   Clashes     15%  ← neutral until Clash API connected

module Acc
  class HealthService
    class << self
      def calculate(issues, rfis: [], submittals: [])
        today = Date.today

        domain_scores = {
          issues:     { score: issues_score(issues, today),      weight: 0.40 },
          rfis:       { score: rfi_score(rfis, today),           weight: 0.25 },
          submittals: { score: submittal_score(submittals, today), weight: 0.20 },
          clashes:    { score: 50,                               weight: 0.15 }
        }

        overall = calculate_overall(domain_scores)

        {
          overall:       overall,
          grade:         grade(overall),
          label:         label(overall),
          domain_scores: domain_scores,
          signals:       build_signals(issues, rfis, submittals, today),
          calculated_at: Time.current.iso8601,
          data_available: issues.any? || rfis.any? || submittals.any?
        }
      end

      private

      # ── Issues Score ────────────────────────────────────────────────────────

      def issues_score(issues, today)
        return 50 if issues.nil? || issues.empty?

        score = 100.0
        score -= [ overdue_open(issues, today).count    * 10, 50 ].min
        score -= [ stale_open(issues, today).count      * 5,  30 ].min
        score -= [ unassigned_open(issues).count        * 3,  15 ].min
        score += [ closed_recently(issues, today, days: 7).count * 5, 20 ].min
        score.clamp(0, 100).round
      end

      # ── RFI Score ───────────────────────────────────────────────────────────

      def rfi_score(rfis, today)
        return 50 if rfis.nil? || rfis.empty?

        active = rfis.select { |r| %w[open submitted answered].include?(r[:status].to_s) }
        score  = 100.0

        overdue = active.select do |r|
          r[:due_date].present? && Date.parse(r[:due_date].to_s) < today
        end
        score -= [ overdue.count * 10, 50 ].min
        score -= [ active.select { |r| r[:priority] == "High" }.count * 5, 20 ].min
        score -= [ active.select { |r| r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes" }.count * 5, 20 ].min
        score += [ rfis.select { |r|
          r[:status].to_s == "closed" &&
            r[:updated_at].present? &&
            Date.parse(r[:updated_at].to_s) >= (today - 30)
        }.count * 3, 15 ].min

        score.clamp(0, 100).round
      end

      # ── Submittal Score ─────────────────────────────────────────────────────
      #
      # Starts at 100, deducts for:
      #   - Overdue active submittals    (up to −50)
      #   - High priority active         (up to −20)
      #   - Awaiting review > 7 days     (up to −20)
      # Awards for:
      #   - Closed this month            (up to +15)

      def submittal_score(submittals, today)
        return 50 if submittals.nil? || submittals.empty?

        active = submittals.select { |s| %w[required open draft].include?(s[:status].to_s) }
        score  = 100.0

        overdue = active.select do |s|
          due = s[:due_date] || s[:submitter_due_date] || s[:required_on_job]
          due.present? && Date.parse(due.to_s) < today
        end
        score -= [ overdue.count * 10, 50 ].min
        score -= [ active.select { |s| s[:priority] == "High" }.count * 5, 20 ].min

        stale_review = active.select do |s|
          s[:sent_to_review].present? &&
            s[:received_from_review].blank? &&
            Date.parse(s[:sent_to_review].to_s) < (today - 7)
        end
        score -= [ stale_review.count * 5, 20 ].min

        closed_month = submittals.select do |s|
          s[:status].to_s == "closed" &&
            s[:updated_at].present? &&
            Date.parse(s[:updated_at].to_s) >= (today - 30)
        end
        score += [ closed_month.count * 3, 15 ].min

        score.clamp(0, 100).round
      end

      # ── Overall ─────────────────────────────────────────────────────────────

      def calculate_overall(domain_scores)
        domain_scores.sum { |_, ds| ds[:score] * ds[:weight] }.round
      end

      # ── Grade + Label ───────────────────────────────────────────────────────

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

      # ── Signals ─────────────────────────────────────────────────────────────

      def build_signals(issues, rfis, submittals, today)
        # Issues signals
        open_issues  = issues.select { |i| i[:status] == "open" }
        overdue_i    = overdue_open(issues, today)
        stale_i      = stale_open(issues, today)
        unassigned_i = unassigned_open(issues)
        closed_week  = closed_recently(issues, today, days: 7)

        # RFI signals
        active_rfis    = rfis.select { |r| %w[open submitted answered].include?(r[:status].to_s) }
        overdue_rfis   = active_rfis.select { |r| r[:due_date].present? && Date.parse(r[:due_date].to_s) < today }
        impactful_rfis = active_rfis.select { |r| r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes" }

        # Submittal signals
        active_subs     = submittals.select { |s| %w[required open draft].include?(s[:status].to_s) }
        overdue_subs    = active_subs.select do |s|
          due = s[:due_date] || s[:submitter_due_date] || s[:required_on_job]
          due.present? && Date.parse(due.to_s) < today
        end
        awaiting_review = active_subs.select { |s| s[:sent_to_review].present? && s[:received_from_review].blank? }

        [
          { key: "open_issues",       label: "Open Issues",          value: open_issues.count,     severity: severity(open_issues.count,  10, 5),  domain: "issues" },
          { key: "overdue_issues",    label: "Overdue Issues",       value: overdue_i.count,       severity: severity(overdue_i.count,    3, 1),   domain: "issues" },
          { key: "stale_issues",      label: "Stale Issues",         value: stale_i.count,         severity: severity(stale_i.count,      5, 2),   domain: "issues" },
          { key: "unassigned_issues", label: "Unassigned Issues",    value: unassigned_i.count,    severity: unassigned_i.count > 0 ? "warning" : "good", domain: "issues" },
          { key: "closed_this_week",  label: "Issues Closed (7d)",   value: closed_week.count,     severity: closed_week.count > 0 ? "good" : "warning",  domain: "issues" },
          { key: "overdue_rfis",      label: "Overdue RFIs",         value: overdue_rfis.count,    severity: severity(overdue_rfis.count,   2, 1),  domain: "rfis" },
          { key: "impactful_rfis",    label: "RFIs with Impact",     value: impactful_rfis.count,  severity: severity(impactful_rfis.count, 3, 1),  domain: "rfis" },
          { key: "overdue_subs",      label: "Overdue Submittals",   value: overdue_subs.count,    severity: severity(overdue_subs.count,   3, 1),  domain: "submittals" },
          { key: "awaiting_review",   label: "Awaiting Review",      value: awaiting_review.count, severity: severity(awaiting_review.count, 5, 2), domain: "submittals" }
        ]
      end

      # Reusable severity helper — critical/warning/good based on thresholds
      def severity(value, critical_threshold, warning_threshold)
        if value >= critical_threshold    then "critical"
        elsif value >= warning_threshold  then "warning"
        else                                   "good"
        end
      end

      # ── Issue filters ───────────────────────────────────────────────────────

      ACTIVE_ISSUE_STATUSES = %w[open pending in_review].freeze

      def overdue_open(issues, today)
        issues.select do |i|
          ACTIVE_ISSUE_STATUSES.include?(i[:status]) &&
            i[:due_date].present? &&
            Date.parse(i[:due_date].to_s) < today
        end
      end

      def stale_open(issues, today)
        issues.select do |i|
          i[:status] == "open" &&
            i[:created_at].present? &&
            Date.parse(i[:created_at].to_s) < (today - 30)
        end
      end

      def unassigned_open(issues)
        issues.select { |i| i[:status] == "open" && i[:assigned_to].blank? }
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
