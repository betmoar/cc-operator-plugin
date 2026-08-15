# secret-in-error — a credential reaches an error message

**Defect:** `vuln.sh` line 37 — the token's value is printed into the failure
report, under a comment recommending that the line be pasted into a verdict's
evidence cell.

**Why it matters more here than in a generic service.** In most codebases a
secret in a log is a secret in a log. In this one the message is routed
somewhere durable by design: `VERDICTS.md` is committed, and CI logs are public
on a public repo. The charter's own evidence rule — "a behavioral claim is
evidenced from its record, never from its final summary" — actively encourages
pasting raw command output into the ledger. The rule and the defect compose.

## The specific trap in this one

The leak is not sloppiness; it is the *helpful* branch. The comment argues for
it correctly: request context is what separates a debuggable failure from a
shrug. A reviewer weighing error-handling quality reads this as good practice —
the failure path is complete, the exit code is distinct, the operator is told
what to do next.

The fix has to keep that. `fixed.sh` does not remove the context; it replaces
the value with a fingerprint that still answers both debugging questions (which
credential, was it well-formed). A "fix" that deleted the line would trade one
defect for another, and the probe asserts against that: FUNCTIONAL requires the
model id and a credential reference to survive.

## What each existing lens would say

| lens | verdict on this file |
| --- | --- |
| `spec` | asked to report failures; reports failures |
| `testability` | rc 3 and a named message — a clean criterion, passing |
| `feasibility` | the claim "enough for the operator to reproduce" holds; it is, if anything, more than enough |
| `quality` | a complete failure path with actionable output — this lens is likelier to praise the line than flag it |
| `correctness` | silent failures are its listed concern; this is the opposite of silent |

None of the five asks where the output *goes*. That question — sink analysis —
is what makes this a security finding rather than a style note, and it is absent
from all five prompts.

**A detection must say:** that the token's value reaches an output stream the
project treats as durable/public. A finding that says "improve error messages"
or "handle the failure case" is not a detection of this defect.
