---
name: pr-babysit
description: Watch a pull request until it is green: fix failing CI jobs, address review comments (Codex or human), reply on each thread with the fixing commit, and resolve the threads. Use with /loop for unattended polling, e.g. `/loop 10m /pr-babysit 266`.
---

# pr-babysit

Keep a pull request moving without the user watching. One invocation does a
single pass over the PR; run it under `/loop` to repeat.

Argument: the PR number (default: the PR of the current branch, via
`gh pr view --json number`).

## Rules

- Work on the PR's branch. Never commit to `main`.
- Commit messages follow the repository convention (see CLAUDE.md), one commit per
  logical fix, then `git push`.
- Reply on a review thread only after the fix is pushed, and quote the short SHA.
- Resolve a thread only if you actually addressed it. If you disagree with a
  comment, reply with the reason and leave it open.
- If the same CI job fails twice with the same error after a fix, stop and report
  instead of retrying.
- Report what changed at the end of every pass, even when nothing changed.

## Pass

### 1. CI

```bash
gh pr checks <PR>
```

For each job that is `fail`:

```bash
gh run view --job <JOB_ID> --log > /tmp/job.log
grep -nE "Test Failed|Error During|ERROR:|error\[" /tmp/job.log | head
```

Reproduce locally when possible (`julia --project test/<file>.jl`, or the
`cargo` commands in CLAUDE.md), fix, run the affected tests, commit, push.
Platform-only failures (Windows path/CRLF, Linux linker) usually cannot be
reproduced; fix from the log and let CI confirm.

If any job is `pending`, note it and move on; the next pass picks it up.

### 2. Review comments

List unresolved threads with their first comment:

```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved path line comments(first:1){nodes{databaseId author{login} body}}}}}}}' \
  -f o=<OWNER> -f r=<REPO> -F n=<PR> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)'
```

For each unresolved thread:

1. Read the comment and the referenced code. Decide: fix, or disagree.
2. Fix: edit, add or update a test that exercises the reported scenario, run it,
   commit with a message that names the review, push.
3. Reply on the thread (the `databaseId` of the first comment is the reply target):

   ```bash
   gh api -X POST repos/<OWNER>/<REPO>/pulls/<PR>/comments/<COMMENT_ID>/replies \
     -f body="Fixed in <SHA>: <one or two sentences on what changed and which test covers it>."
   ```

4. Resolve the thread:

   ```bash
   gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<THREAD_ID>
   ```

Also read top-level review bodies (`gh api repos/<OWNER>/<REPO>/pulls/<PR>/reviews`)
for requests that have no inline thread; answer those with a PR comment
(`gh pr comment <PR> --body ...`).

### 3. Re-review

If you pushed fixes for review comments and the reviewer is a bot that re-reviews
on request (Codex: comment `@codex review`), request it once per pass at most.

### 4. Report

Summarize in a few lines: jobs fixed, threads resolved (with SHAs), threads left
open and why, jobs still pending. If everything is green and no threads are
open, say so and suggest stopping the loop (`/loop` ends with `stop`).
