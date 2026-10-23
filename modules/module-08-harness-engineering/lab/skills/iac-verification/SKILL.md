---
name: iac-verification
description: Use when about to say infrastructure is applied, destroyed, clean, passing, green, or ready, or when relaying a teammate's or an earlier run's result, in any message about Terraform, checkov, or Floci.
---

# IaC Verification
Adapts superpowers:verification-before-completion to infrastructure. A claim about
infrastructure is exactly as real as the command output pasted next to it.
**Violating the letter of this rule is violating the spirit of this rule.**

## The rule
Each claim below appears in a message only with its evidence line pasted verbatim, in a
code block, in the same message, from a command you ran in this session:

| Claim | Evidence line that must be pasted |
|---|---|
| "tests pass" | the `terraform test` summary, e.g. `Success! 4 passed, 0 failed.` |
| "checkov clean" / "scan passes" | `Passed checks: N, Failed checks: M, Skipped checks: K` plus every `FAILED for resource` line |
| "applied" | `Apply complete! Resources: N added, M changed, K destroyed.` |
| "destroyed" | `Destroy complete! Resources: N destroyed.` |

No evidence line? Then the message says `NOT VERIFIED: <claim>` and why. That is a complete answer.

## Not evidence
- A paraphrase ("4/4 pass", "scan was fine", "went fine"). Paraphrases drift: one summary of a checkov run named the wrong key type. Paste the line.
- Output you did not produce: a teammate's word, a standup note, an earlier session, a file whose provenance you did not check.
- `terraform plan` or `validate` standing in for apply.

## Rationalizations
| Excuse | Reality |
|---|---|
| "The lead only wants yes/no" | Yes plus one pasted line is still short. Yes without the line is a guess. |
| "The emulator is busy, I'll confirm from the teammate's report" | Then the claim is theirs. Write NOT VERIFIED and name the gap. |
| "I ran it, I remember the numbers" | Memory is a paraphrase. Paste the line. |
| "Clean except one small finding" | "Clean" above a FAILED line is false. Paste the counts and the finding. |

## Red flag
About to type "applied", "destroyed", "clean", "passes", "all green", or "went fine" with no
code block above it in the same message: stop. Run the command, or write NOT VERIFIED.
