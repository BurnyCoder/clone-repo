# How the replay works

[README](../README.md#how-it-works) has the overview. This page explains each step and why it is needed, with a worked example.

## Why a replay

A pull request isn't stored in git. It is a GitHub record with a number, a title, a body, a head and a base, and a state. There is no API to create a PR that is already merged, or to choose its number. The only way to get a real merged PR #N in another repo is to make it happen the same way again:

- **Numbers.** Issues and PRs share one counter, and GitHub assigns the next free number. Replaying the PRs in order into an empty repo gives #1, #2, … again. This is why `preflight` refuses issues and numbering gaps, and why `replay_prs` stops if the number GitHub returns isn't the expected one.
- **Merged state.** GitHub closes a PR as merged when a push makes its head commit reachable from its base branch. The [hub-merge(1)](https://man.archlinux.org/man/hub-merge.1.en) docs describe this for a merge commit created locally and then pushed. Pushing the source's own merge commit reproduces it, so the PR shows as merged by that same SHA.

## Worked example

Source history. The `main` first-parent chain is `A → M1 → M2`. PR #1 (`feat/a`, head `H1`) was merged as `M1`, and PR #2 (`feat/b`, head `H2`) as `M2`:

```text
A ── M1 ── M2            main
 \   /  \  /
  H1      H2
```

`M1^1 = A`, `M1^2 = H1`, `M2^1 = M1` and `M2^2 = H2` ([gitrevisions](https://git-scm.com/docs/gitrevisions): `^1` is the first parent, `^2` the second).

What `replay_prs` does in the empty destination:

| Step | PR #1 | PR #2 | Why |
|---|---|---|---|
| base → `merge^1` | `main = A` | `main = M1` (already) | the base as it was just before the merge |
| branch → head | `feat/a = H1` | `feat/b = H2` | the PR's commits |
| open PR | `POST /pulls` → **#1** | → **#2** | needs commits between base and head, which exist now |
| base → merge | `main = M1` (fast-forward) | `main = M2` | the head is now in `main` |
| wait | state `MERGED` | `MERGED` | GitHub's detection is asynchronous, so `wait_merged` polls |
| delete branch | `feat/a` | `feat/b` | like "Delete branch" after a merge |

Then `sync_refs` runs `git push --mirror`. It force-updates every branch and tag to the source's value and deletes destination branches the source doesn't have ([git push --mirror](https://git-scm.com/docs/git-push#Documentation/git-push.txt---mirror)). Branches that still exist in the source come back, any temporary state is undone, and the result equals the source.

The base branch is pushed with `--force` on purpose. If PRs were merged out of number order (say #3 was merged before #2), replaying #3 moves the base *back* to `M3^1`, because otherwise #3's head would already be in the base and GitHub would refuse to open it. On a new destination this is harmless, and the mirror push at the end restores the final state.

## Why each check exists

| Check | Phase | What would go wrong without it |
|---|---|---|
| no issues, no numbering gaps | `preflight` | PR numbers would shift. Gaps come from deleted issues and from discussions, which share the counter. |
| only merged PRs | `preflight` | An open PR's branch is deleted after the replay, which would close it. A closed PR has no merge commit to replay. |
| no fork PRs | `preflight` | The head branch lives in another repo, and its name can clash with a destination branch. |
| no comments/reviews/labels/assignees/milestone | `preflight` | The replay sends only the title and body, so these would be lost without notice. |
| merge commit's second parent = head | `check_merges` | Squash and rebase merges make new commits that don't contain the head, so GitHub would never mark the PR merged. |
| returned number = N | `replay_prs` | Catches anything created in the destination by someone else during the run. |

## Commands per phase

- `clone_source`: `git clone --bare $SOURCE_GIT_URL work/src.git`. Bare clones skip GitHub's hidden `refs/pull/*`, which GitHub refuses on push. Each PR head is a merge's second parent, so it is in the clone.
- `create_target`: `gh repo create DEST --<visibility> --description ...`, then `gh repo edit DEST` with flags built from the source settings, then `gh label clone SOURCE --repo DEST --force`.
- `replay_prs`: `git push --force DEST <sha>:refs/heads/<branch>` (through `push_ref`). The PR comes from `gh api repos/SOURCE/pulls/N --jq '{title, body, head: .head.ref, base: .base.ref}'` and is created with `gh api repos/DEST/pulls --input pr_N.json`. Going through a JSON file keeps the body byte for byte.
- `sync_refs`: `git push --mirror DEST`, then `gh repo edit DEST --default-branch <source default>`. Before that, the default branch is whichever branch was pushed first.
- `copy_secrets`: `gh secret set --env-file FILE --repo DEST`.
- `verify`: for each repo, `git ls-remote` (branches, tags, `refs/pull/N/head`), `gh pr list --json number,title,body,state,headRefName,headRefOid,baseRefName,mergeCommit,isDraft`, `gh label list`, `gh repo view --json <settings>` and `gh secret list`. The two snapshots are diffed. GitHub creates `refs/pull/N/head` for every PR, so a match there also shows the head SHAs line up.

All git commands run as `git -c credential.helper= -c 'credential.helper=!gh auth git-credential'`. The empty value resets any configured helpers ([gitcredentials](https://git-scm.com/docs/gitcredentials#_custom_helpers)), so gh's token is used. That token carries the `workflow` scope, which GitHub requires for pushing commits that change `.github/workflows`. Your git config is not modified.

## Sync

`replay_prs` first lists the destination's PR numbers and skips those. A later run therefore replays only PRs merged in the source since the last run. `clone_source` re-clones each time and `sync_refs` mirrors the current refs, so new commits pushed straight to a branch arrive too. A sync doesn't update PRs it has already copied. That is fine, because a merged PR doesn't change.

## What GitHub shows on a replayed PR

The PR page shows "Merged", the original merge commit, and the commits and diff, which are identical. The dates are the time of the copy, and the person who opened and merged it is the account that ran the copy, because the API can't set either. The head branch is deleted, the same as after a normal merge with "Delete branch", so the page offers "Restore branch".
