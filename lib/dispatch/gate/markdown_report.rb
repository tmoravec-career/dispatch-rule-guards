module Dispatch
  module Gate
    # Renders an Impact report as Markdown for a PR comment. Section order is fixed (Q32).
    module MarkdownReport
      module_function

      def render(report)
        summary = report["summary"]
        breaches = report["policy_breaches"]
        lines = ["# Rule-change impact report", ""]
        lines << (breaches.empty? ? "**PASS**: no policy breached." : "**FAIL**: #{breaches.size} policy breach#{'es' unless breaches.size == 1}.")
        lines << ""

        section(lines, "Summary", table(%w[Metric Value], [
          ["Replayed claims", summary["replayed_claims"]],
          ["Claim source", summary["seed"].nil? ? "claims file" : "seeded generator (seed #{summary['seed']})"],
          ["Rerouted", "#{report['rerouted'].size} (#{summary['reroute_pct']}%)"],
          ["Unassigned (base / proposed)", "#{summary['unassigned_base']} / #{summary['unassigned_proposed']}"],
          ["Newly unassigned", report["newly_unassigned"].size],
          ["Newly assigned", report["newly_assigned"].size],
          ["Boundary probes changed", "#{report['boundary_probe_changes'].size} of #{report['boundary_probes'].size}"]
        ]))

        section(lines, "Policy breaches", table(%w[Policy Threshold Actual],
                                                breaches.map { |b| [code(b["policy"]), b["threshold"], b["actual"]] }))

        newly = table(["Claim", "Queue", "Reason code", "Base queue", "Base adjuster"],
                      report["newly_unassigned"].map do |c|
                        [c["claim_number"], code(c["queue"]), code(c["reason_code"]), code(c["base_queue"]), c["base_adjuster"]]
                      end)
        unless report["newly_assigned"].empty?
          newly += ["", "### Newly assigned (informational)", "",
                    *table(["Claim", "Queue", "Adjuster"],
                           report["newly_assigned"].map { |c| [c["claim_number"], code(c["queue"]), c["adjuster"]] })]
        end
        section(lines, "Newly unassigned", newly)

        section(lines, "Queue changes", table(%w[Queue Base Proposed Change],
                                              report["queue_changes"].map do |q|
                                                [code(q["queue"]), q["base"], q["proposed"], format("%+d", q["delta"])]
                                              end))

        section(lines, "Rerouted claims", table(["Claim", "Base queue", "Proposed queue"],
                                                report["rerouted"].map do |c|
                                                  [c["claim_number"], code(c["base_queue"]), code(c["proposed_queue"])]
                                                end))

        section(lines, "Boundary probe changes",
                table(["Field", "Value", "Threshold", "Base queue (rule)", "Proposed queue (rule)"],
                      report["boundary_probe_changes"].map do |p|
                        [code(p["field"]), p["value"], p["threshold"],
                         routed(p["base_queue"], p["base_matched_rule"]), routed(p["proposed_queue"], p["proposed_matched_rule"])]
                      end))
        "#{lines.join("\n").rstrip}\n"
      end

      def section(lines, title, body)
        lines.push("## #{title}", "", *body, "")
      end

      def table(headers, rows)
        return ["None."] if rows.empty?

        ["| #{headers.map { |h| cell(h) }.join(' | ')} |", "|#{headers.map { '---' }.join('|')}|",
         *rows.map { |row| "| #{row.map { |c| cell(c) }.join(' | ')} |" }]
      end

      # Table-safe text: a "|" would end the cell and a newline would end the row (Q56).
      def cell(value)
        value.to_s.gsub(/\s*\R\s*/, " ").gsub("|") { "\\|" }
      end

      def code(text)
        text.nil? ? "" : "`#{text}`"
      end

      def routed(queue, rule)
        "#{code(queue)} (#{rule.nil? ? 'no rule' : code(rule)})"
      end
    end
  end
end
