# app/services/acc/health_service.rb
#
# Calculates a project health score (0–100) from live ACC data.
#
# Formula is intentionally extensible — each domain returns a sub-score
# and a weight.  Domains not yet connected return a neutral score (50)
# so the overall score is still meaningful with partial data.
#
# Weights:
#   Issues      40%  ← live
#   RFIs        25%  ← live
#   Submittals  20%  ← neutral until Submittal API connected
#   Clashes     15%  ← neutral until Clash API connected

module Acc
  class HealthService
    class << self
      # @param issues [Array<Hash>]  formatted issues from Acc::IssuesService
      # @param rfis   [Array<Hash>]  formatted rfis   from Acc::RfisService
      # @return [Hash] full health report
      def calculate(issues, rfis)
        today = Date.today

        domain_scores = {
          issues:     { score: issues_score(issues, today), weight: 0.40 },
          rfis:       { score: rfi_score(rfis, today),      weight: 0.25 },
          submittals: { score: 50,                          weight: 0.20 }, # neutral — not yet connected
          clashes:    { score: 50,                          weight: 0.15 }  # neutral — not yet connected
        }

        overall = calculate_overall(domain_scores)

        {
          overall:      overall,
          grade:        grade(overall),
          label:        label(overall),
          domain_scores: domain_scores,
          signals:      build_signals(issues, rfis, today),
          calculated_at: Time.current.iso8601
        }
      end

      private

      # ── Issues Score (0-100) ──────────────────────────────────────────────
      #
      # Starts at 100 and deducts for risk signals; awards for recent progress.

      def issues_score(issues, today)
        return 50 if issues.nil? || issues.empty?

        score = 100.0
        score -= [ overdue_open(issues, today).count    * 10, 50 ].min  # max −50
        score -= [ stale_open(issues, today).count      *  5, 30 ].min  # max −30
        score -= [ unassigned_open(issues).count        *  3, 15 ].min  # max −15
        score += [ closed_recently(issues, today, days: 7).count * 5, 20 ].min  # max +20

        score.clamp(0, 100).round
      end

      # ── RFI Score (0-100) ─────────────────────────────────────────────────
      #
      # Same deduction structure as issues_score.
      # Overdue RFIs carry the heaviest penalty; high-priority / impactful RFIs
      # trigger a moderate deduction.

      def rfi_score(rfis, today)
        return 50 if rfis.nil? || rfis.empty?

        active  = rfis.select { |r| %w[open submitted answered].include?(r[:status]) }
        score   = 100.0

        overdue       = active.select { |r| r[:due_date].present? && Date.parse(r[:due_date].to_s) < today }
        high_priority = active.select { |r| r[:priority] == "High" }
        impactful     = active.select { |r| r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes" }

        score -= [ overdue.count       * 10, 50 ].min  # max −50 for overdue
        score -= [ high_priority.count *  5, 20 ].min  # max −20 for high-priority open RFIs
        score -= [ impactful.count     *  5, 20 ].min  # max −20 for cost/schedule-impacting RFIs

        # Award points for RFIs closed in the last 7 days.
        recently_closed = rfis.select do |r|
          r[:status] == "closed" &&
            r[:updated_at].present? &&
            Date.parse(r[:updated_at].to_s) >= (today - 7)
        end
        score += [ recently_closed.count * 5, 20 ].min  # max +20

        score.clamp(0, 100).round
      end

      # ── Overall Score ─────────────────────────────────────────────────────

      def calculate_overall(domain_scores)
        domain_scores.sum { |_, ds| ds[:score] * ds[:weight] }.round
      end

      # ── Grade + Label ─────────────────────────────────────────────────────

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

      # ── Signals ───────────────────────────────────────────────────────────
      def build_signals(issues, rfis, today)
        # ── Issues signals ───────────────────────────────────────
        open_issues = issues.select { |i| i[:status] == "open" }
        overdue_i   = overdue_open(issues, today)
        stale_i     = stale_open(issues, today)
        unassigned  = unassigned_open(issues)
        closed_week = closed_recently(issues, today, days: 7)

        # ── RFI signals ──────────────────────────────────────────
        active_rfis    = rfis.select { |r| %w[open submitted answered].include?(r[:status]) }
        overdue_r      = active_rfis.select { |r| r[:due_date].present? && Date.parse(r[:due_date].to_s) < today }
        high_pri_rfis  = active_rfis.select { |r| r[:priority] == "High" }
        impactful_rfis = active_rfis.select { |r| r[:cost_impact] == "Yes" || r[:schedule_impact] == "Yes" }

        # # ── Submittal signals ─────────────────────────────────────
        # active_subs   = submittals.select { |s| %w[submitted under_review revise_and_resubmit].include?(s[:status]) }
        # overdue_s     = active_subs.select { |s| s[:due_date].present? && Date.parse(s[:due_date].to_s) < today }
        # revise_resub  = submittals.select { |s| s[:status] == "revise_and_resubmit" }
        # under_review  = submittals.select { |s| s[:status] == "under_review" }

        [
          # Issues
          signal("open_issues",      "Open Issues",         open_issues.count,
                open_issues.count > 10 ? "critical" : open_issues.count > 5 ? "warning" : "good"),
          signal("issues_overdue",   "Issues Overdue",      overdue_i.count,
                overdue_i.count > 3 ? "critical" : overdue_i.count > 0 ? "warning" : "good"),
          signal("issues_stale",     "Issues Stale 30d+",   stale_i.count,
                stale_i.count > 5 ? "critical" : stale_i.count > 2 ? "warning" : "good"),
          signal("issues_unassigned", "Issues Unassigned",   unassigned.count,
                unassigned.count > 0 ? "warning" : "good"),
          signal("issues_closed_week",  "Closed This Week",   closed_week.count,
                closed_week.count > 0 ? "good" : "warning"),

          # RFIs
          signal("rfis_overdue",     "RFIs Overdue",        overdue_r.count,
                overdue_r.count > 3 ? "critical" : overdue_r.count > 0 ? "warning" : "good"),
          signal("rfis_high_priority", "RFIs High Priority", high_pri_rfis.count,
                high_pri_rfis.count > 5 ? "critical" : high_pri_rfis.count > 0 ? "warning" : "good"),
          signal("rfis_impactful",   "RFIs with Impact",    impactful_rfis.count,
                impactful_rfis.count > 3 ? "critical" : impactful_rfis.count > 0 ? "warning" : "good")

          # Submittals
          #   signal("subs_overdue",     "Submittals Overdue",  overdue_s.count,
          #         overdue_s.count > 3 ? "critical" : overdue_s.count > 0 ? "warning" : "good"),
          #   signal("subs_revise",      "Revise & Resubmit",   revise_resub.count,
          #         revise_resub.count > 3 ? "critical" : revise_resub.count > 0 ? "warning" : "good"),
          #   signal("subs_under_review","Under Review",        under_review.count,
          #         under_review.count > 10 ? "warning" : "good"),
        ]
      end

      def signal(key, label, value, severity)
        { key: key, label: label, value: value, severity: severity }
      end

      # ── Issue filters ─────────────────────────────────────────────────────

      def overdue_open(issues, today)
        issues.select do |i|
          i[:status] == "open" &&
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
