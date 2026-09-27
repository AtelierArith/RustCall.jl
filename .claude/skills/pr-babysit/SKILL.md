---
name: pr-babysit
description: "Monitor a pull request through current-head CI and a converged review: triage findings in a batch, verify P2 reports with regression tests, reply with fixing SHAs, and resolve only acted-on threads."
---

# pr-babysit

Keep a pull request moving without the user watching. One invocation does a
single pass over the PR. If the host supports scheduled or repeated invocation,
run another pass after its interval; otherwise invoke the skill again as needed.

Argument: the PR number (default: the PR of the current branch, via
`gh pr view --json number`).

## Rules

- Work on the PR's branch. Never commit to `main`.
- Use one commit per logical fix. Do not push individual fixes while working a
  review round; push all commits for that round together after collecting and
  addressing its actionable CI and review findings.
- Follow CLAUDE.md's rule to request `@codex review` immediately after every push.
- Track CI and review results against the current head SHA; a result for an older
  head does not count for the current one.
- Gather the feedback available for a head before editing. Keep one review round
  quiet until its findings are in, then batch the round's fixes into one push.
- Reply on a review thread only after the fix is pushed, and quote the short SHA
  and the test that covers the finding.
- Resolve a thread only if you actually addressed it. If you disagree with a
  comment, reply with the reason and leave it open.
- If the same CI job fails twice with the same error after a fix, stop and report
  instead of retrying.
- Do not use “P2 count is zero” as the sole completion condition. Every actionable
  finding still needs a disposition, and a clean review round is evidence rather
  than a substitute for passing checks and addressed threads.
- Report what changed at the end of every pass, even when nothing changed.

## Pass

At the beginning of every pass, record the current PR head before collecting CI
results, logs, reviews, or threads:

```bash
HEAD_SHA=$(gh pr view <PR> --json headRefOid --jq .headRefOid)
```

### 1. CI

```bash
gh api repos/<OWNER>/<REPO>/commits/$HEAD_SHA/check-runs \
  -f per_page=100 \
  --jq '.check_runs[] | [.id, .name, .status, .conclusion, .details_url] | @tsv'
```

This lists check runs for the captured SHA. Use its job IDs and details URLs for
failure logs; do not add results from another head to this pass's ledger. After
collecting checks and logs, fetch the PR head again. If it differs from
`HEAD_SHA`, discard this pass's CI ledger and end as pending without editing.

For each job that is `fail`:

```bash
gh run view --job <JOB_ID> --log > /tmp/job.log
rg -n -e "Test Failed|Error During|ERROR:|error\[" /tmp/job.log | head
```

Reproduce locally when possible (`julia --project test/<file>.jl`, or the
`cargo` commands in CLAUDE.md) and record the failing job, error, and likely
reproducer. Do not edit code during this collection pass. Platform-only failures
(Windows path/CRLF, Linux linker) usually cannot be reproduced; record what the
log establishes and what needs CI confirmation.

If any check is queued or in progress, note it and end this pass as pending
without editing or pushing; a later pass can collect the completed result. If no
check run exists yet for `HEAD_SHA`, treat that as pending too.

### 2. Review comments

List unresolved threads with their first comment:

```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved path line comments(first:1){nodes{databaseId author{login} body}}}}}}}' \
  -f o=<OWNER> -f r=<REPO> -F n=<PR> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)'
```

For each unresolved thread:

Read the comment and cited code as part of the review-only pass below. Do not edit
while collecting or classifying findings.

Also read top-level review bodies (`gh api repos/<OWNER>/<REPO>/pulls/<PR>/reviews`)
and add any requests without inline threads to the finding ledger.

Wait until the requested Codex review for `HEAD_SHA` is complete before editing.
Check the review status summary as well as review records and threads.
A missing result or a `Running` status is pending, not a clean round.
Once the review is complete, rerun the check-runs query for `HEAD_SHA` and
refresh review bodies and threads. Re-read the PR head. Continue only if the PR
still points to `HEAD_SHA` and the review has completed. All check runs for
`HEAD_SHA` must be complete. If the head changed, no check run exists, or any
check or review is pending or unavailable, end this pass as pending without
editing.

After that gate, make a review-only pass over all findings for the unchanged head.
Inspect the cited code, relevant callers, and tests, then keep a small finding
ledger (finding, evidence, disposition, test, fixing SHA, thread status). Classify
each finding as a previously missed case, a regression from a recent fix, a
duplicate, or a claim whose assumptions do not hold. This avoids treating every
new comment as proof that the last fix caused a new bug.

For P2 findings, verify the reported scenario against the code and its callers.
If it is a real defect, add a regression test that reproduces it before or with
the fix. If the scenario is not possible or the behavior is intentional, record
the specific code, contract, or test evidence for the response; do not silently
ignore it or close the thread. When a finding returns after a fix, compare the
exact scenario and test with the earlier round, then investigate the underlying
path or missed case instead of applying the same symptom-level patch again.

### 3. Fix and re-review

After the CI and review collection gates complete for `HEAD_SHA`, fix all CI
failures and actionable review findings from that round, grouping related changes
where that keeps the patch understandable. Use one commit per logical fix, then
push those commits together once the whole round is addressed. Run the relevant
regression tests and repository-required checks before pushing. Immediately after
the push, request a Codex review as required by CLAUDE.md. Then reply on each
fixed thread using the first comment's `databaseId` as the reply target:

```bash
gh api -X POST repos/<OWNER>/<REPO>/pulls/<PR>/comments/<COMMENT_ID>/replies \
  -f body="Fixed in <SHA>: <what changed and which test covers it>."
```

Resolve only findings the change addresses:

```bash
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<THREAD_ID>
```

For findings you disagree with, reply with the recorded evidence and leave the
thread open. If no code change was needed, make that evidence-based reply without
a push and leave the thread open. Answer top-level reviews without inline threads
with a PR comment. Wait for CI and Codex results for that head before starting
another round.

### 4. Completion and report

Declare the PR complete only when required CI is green for the current head, all
actionable findings have a verified disposition, fixed findings have regression
coverage, and no review threads remain unresolved. A single pass may end before
those conditions hold; report the remaining work and do not call the PR complete.
If the same issue keeps reappearing, pause code edits and report the cause
analysis and evidence instead of continuing a review loop that only aims to reach
zero comments.

Summarize in a few lines: jobs fixed, threads resolved (with SHAs), threads left
open and why, jobs still pending. If everything is green and no threads are
open, say so and suggest stopping repeat polling if it is active.
