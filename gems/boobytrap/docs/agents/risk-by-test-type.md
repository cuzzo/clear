# Empirical Risk Assessment: Integrating Mutation Signal

This document outlines the design for incorporating "Verification Quality" (specifically mutation testing signals) into the `Boobytrap` and `SlopCop` risk models.

## 1. The Core Philosophy: "Hollow" vs. "Load-Bearing" Tests

Currently, `Decomplex` identifies structural risk (complexity, scattered state) and `Boobytrap` identifies historical risk (churn, bugspots). However, standard line-coverage cannot differentiate between a "Hollow Test" (code executed without assertion) and a "Load-Bearing Test" (code explicitly verified against mutation).

By joining **Mutation Coverage** with **Structural Complexity**, we move from static analysis to **Empirical Risk Assessment**.

## 2. The "Structural Integrity" Formula

Risk is no longer just "Is this code complex?" It is: **"Is this complexity protected?"**

We introduce a three-axis risk assessment for every method/module:

| Axis | Tool | Signal | Risk Indicator |
| :--- | :--- | :--- | :--- |
| **Complexity** | `Decomplex` | Decision Pressure, Co-Update | The code is hard for humans to reason about. |
| **History** | `Boobytrap` | Bugspots, Commit Churn | The code breaks frequently in practice. |
| **Verification** | `Mutant` | Kill-Rate, Gate Status | The test suite is incapable of catching regressions. |

### The Risk Profiles

1. **The "Lurking Disaster" (Critical Risk)**
   - *Signal:* High Complexity + High Churn + Low/No Mutation Coverage.
   - *Verdict:* A developer changing this code is flying blind. Even if tests pass, they are performative. This is the highest priority for refactoring or hard-gating.

2. **The "Hardened Veteran" (Low/Managed Risk)**
   - *Signal:* High Complexity + Low/Moderate Churn + High Mutation Coverage (Hard-Gated).
   - *Verdict:* The code is complex, but the safety net is empirically proven. The "Decision Pressure" is high, but it is "Safe Complexity." SlopCop can downgrade the urgency of this warning.

3. **The "Fragile Newcomer" (Rising Risk)**
   - *Signal:* Low Complexity + High Churn + Low Mutation Coverage.
   - *Verdict:* Code that is frequently modified but lacks strict verification. A bug factory in the making.

## 3. Implementation Plan

This does not require a new gem; it requires a **Verification Join** within the existing `SlopCop` / `Boobytrap` rollup.

### Step 1: Fact Extraction (Mutant)
Modify the mutation runner (`tools/mutants/ruby_specs.rb` or similar) to emit a structured JSON fact file:
```json
{
  "schema": "mutant-facts/v1",
  "subjects": [
    {
      "method": "EscapeAnalysis#apply",
      "file": "src/semantic/escape_analysis.rb",
      "kill_rate": 32.58,
      "gate_status": "advisory"
    }
  ]
}
```

### Step 2: The Join (SlopCop)
In `SlopCop::Rollup` (or the equivalent Boobytrap analyzer), join the `Decomplex` structural facts with the `Mutant` verification facts using `(file, method)` as the primary key.

### Step 3: Reporting & Verdicts
Update the `SlopCop` report to expose the Verification layer.
- Elevate the severity of complex methods that lack mutation coverage.
- Add a "Verification Status" column to standard outputs.

## 4. Why This Matters for v0.1

- **Internal Velocity:** It provides a deterministic "Heatmap" for the remaining 10 weeks of development. It highlights exactly which "Advisory" mutant subjects are protecting complex, highly-churned code (e.g., `EscapeAnalysis`).
- **Product Value:** When launching `SlopCop`, this feature becomes a primary differentiator. It offers a level of insight—differentiating "Safe Complexity" from "Unsafe Complexity"—that standard linters and coverage tools cannot match.
