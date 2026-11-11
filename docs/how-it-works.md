# How the replay works

[README](../README.md#how-it-works) has the overview. This page explains each step and why it is needed, with a worked example.

## Why a replay

A pull request isn't stored in git. It is a GitHub record with a number, a title, a body, a head and a base, and a state. There is no API to create a PR that is already merged, or to choose its number. The only way to get a real merged PR #N in another repo is to make it happen the same way again:

- **Numbers.** Issues and PRs share one counter, and GitHub assigns the next free number. Replaying the PRs in order into an empty repo gives #1, #2, … again. That's one reason `preflight` refuses issues and numbering gaps in the source. Once the destination has PRs or issues of its own, the numbers can't line up any more. Each later copy then takes the next free number, and its body gets a `Copied from <link>` line (see [A destination people work in](#a-destination-people-work-in)).
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
| comments | posted in order, if any | | the conversation, each with an "Originally posted by" line |
| base → merge | `main = M1` (fast-forward) | `main = M2` | the head is now in `main` |
| wait | state `MERGED` | `MERGED` | GitHub's detection is asynchronous, so `wait_merged` polls |
| delete branch | `feat/a` | `feat/b` | like "Delete branch" after a merge |

Then `sync_refs` brings every source branch and tag to the source's commit. That restores PR branches the source still has, and leaves the destination's own branches alone (next section).

The base branch may move backwards on purpose. If PRs were merged out of number order (say #3 was merged before #2), replaying #3 moves the base *back* to `M3^1`, because otherwise #3's head would already be in the base and GitHub would refuse to open it. That only happens while the base holds source history alone, and the next push moves it forward again.

## A destination people work in

A copy can become a repo people work in: they open PRs there, push branches, and merge into `main`. A sync must add the source's new work without removing theirs.

The motivation is a real failure, on 2026-11-11. The first version of `sync_refs` ran GitHub's documented `git push --mirror`, which deletes every destination branch the source doesn't have ([git push](https://git-scm.com/docs/git-push), `--mirror`). It deleted a collaborator's PR branch in a shared destination, and GitHub closed that PR. The commits survived in GitHub's `refs/pull/<n>/head`, so the branch could be restored and the PR reopened.

**Telling their work from the source's.** Each phase that pushes first fetches the destination's branches and tags into the bare clone, as `refs/dest/heads/*` and `refs/dest/tags/*` (`fetch_dest`; `--no-tags` keeps them out of the source's own `refs/tags`). A destination commit that no source branch or tag contains (`git for-each-ref --contains`) was made in the destination. `ref_state` compares each destination ref with the source's commit:

| State | Meaning | `sync_refs` | `verify` |
|---|---|---|---|
| same | the destination has the source's commit | nothing to do | PASS |
| missing | no such ref in the destination | creates it | FAIL until created |
| behind | only source history there (older, or replaced) | moves it | FAIL until moved |
| ahead | their commits on top of the source's commit | keeps theirs | INFO |
| diverged | both repos changed it | keeps theirs; stops if it's the default branch | WARN |

A destination branch the source doesn't have is deleted only if it is a merged source PR's branch that holds source history alone, i.e. the source deleted it after the merge. Every other one is kept and listed. The replay never moves a branch that is ahead or diverged either. If the source has a new PR whose base the destination changed, the run stops before touching that branch and asks you to merge the two. PRs it copied earlier in the same run stay copied.

**Pushes that can't overwrite.** Between the snapshot and a push, someone may push to the destination. Every push therefore carries `--force-with-lease=<ref>:<commit in the snapshot>`, with an empty value for a ref that must not exist yet. git then updates the ref only if the destination still has what the snapshot saw, and otherwise rejects it with "stale info" ([git push](https://git-scm.com/docs/git-push)). A `+` in the refspec would have git ignore a stale lease. A local test with git 2.56 force-updated the ref anyway, so no refspec has one. After each of its own pushes, `push_ref` updates the snapshot, so the next lease on the same branch expects the new commit.

**Matching copies.** A source PR is already copied when a merged destination PR has its merge commit. That stays true whatever numbers the copies got. The real case on 2026-11-11: the destination's own PR took #46, so the source's #46 was copied as #47.

**Runs that stop half way.** If a run stops between opening a copy and merging it (a failed API call, or a stale lease), the next run finds the open copy with the same head commit. It reuses that copy, because GitHub refuses a second PR for the same branches, and posts only the comments the copy doesn't have yet.

**Settings.** Settings and labels are set only on a repo the run creates. In an existing destination, its admins own them: a sync only adds the source labels it lacks (`gh label clone` without `--force` skips existing ones, [gh label clone](https://cli.github.com/manual/gh_label_clone)). `verify` reports different settings as WARN.

## Why each check exists

| Check | Phase | What would go wrong without it |
|---|---|---|
| no issues, no numbering gaps | `preflight` | Issues aren't copied, and a first copy's PR numbers would shift. Gaps come from deleted issues and from discussions, which share the counter. |
| only merged PRs | `preflight` | An open PR's branch is deleted after the replay, which would close it. A closed PR has no merge commit to replay. |
| base branch not changed in the destination | `push_ref` | Replaying needs to move the base, which would drop the destination's own commits there. |
| no fork PRs | `preflight` | The head branch lives in another repo, and its name can clash with a destination branch. |
| no reviews/labels/assignees/milestone | `preflight` | The replay sends the title, body and conversation comments only, so these would be lost without notice. |
| merge commit's second parent = head | `check_merges` | Squash and rebase merges make new commits that don't contain the head, so GitHub would never mark the PR merged. |
| lease on every push | `push_ref`, `sync_refs` | A commit pushed to the destination during the run would be overwritten. |

## Commands per phase

- `clone_source`: `git clone --bare $SOURCE_GIT_URL work/src.git`. Bare clones skip GitHub's hidden `refs/pull/*`, which GitHub refuses on push. Each PR head is a merge's second parent, so it is in the clone.
- `create_target`:
  - For a new destination: `gh repo create DEST --<visibility> --description ...`, then `gh repo edit DEST` with flags built from the source settings, then `gh label clone SOURCE --repo DEST --force`.
  - For an existing one: only `gh label clone SOURCE --repo DEST`.
- `replay_prs`:
  - **Snapshot and pushes.** `git fetch --prune --no-tags DEST` into `refs/dest/*`. Then `git push --force-with-lease=refs/heads/<branch>:<snapshot> DEST <sha>:refs/heads/<branch>` (through `push_ref`).
  - **Already copied.** The destination's merged PRs' merge commits, from `gh pr list --state merged --json mergeCommit`.
  - **Reuse.** An open copy left by an earlier run: `gh pr list --state open --head <branch> --json number,headRefOid`.
  - **Opening the PR.** The PR comes from `gh api repos/SOURCE/pulls/N --jq '{title, body, head: .head.ref, base: .base.ref}'` and is created with `gh api repos/DEST/pulls --input pr_N.json`. Going through a JSON file keeps the body byte for byte.
  - **Renumbered copy.** If its number differs, the body with the link comes from `--jq <NOTE_JQ>` and is set with `gh api -X PATCH repos/DEST/pulls/M --input note_N.json` ([update a pull request](https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request)).
  - **Comments.** They come from `gh api repos/SOURCE/issues/N/comments --paginate --jq <COMMENTS_JQ>`, which prints one `{"body": ...}` per line. The ones the copy doesn't have yet are posted with `gh api repos/DEST/issues/M/comments --input -`. They are posted before the merge commit is pushed, so a run that stops later never leaves a merged PR without its comments.
- `sync_refs`: `fetch_dest`, then one `git push` with one `--force-with-lease` per ref, for refs that are missing or behind and for merged PR branches the source deleted. On a new destination, it then runs `gh repo edit DEST --default-branch <source default>`. Before that, the default branch is whichever branch was pushed first.
- `copy_secrets`: `gh secret set --env-file FILE --repo DEST`.
- `verify`:
  - **Refs.** `fetch_dest` and `ref_state` for every source branch and tag.
  - **PRs.** For each repo, `gh pr list --json number,mergeCommit,title,state,headRefName,headRefOid,baseRefName,isDraft,comments,body` turned into one line per PR by `PRS_JQ`, with the `Copied from` line removed. Destination lines are matched to source lines by merge commit and compared without the number.
  - **The rest.** `gh label list`, `gh repo view --json <settings>` (one `key=value` per line) and `gh secret list`.

All git commands run as `git -c credential.helper= -c 'credential.helper=!gh auth git-credential'`. The empty value resets any configured helpers ([gitcredentials](https://git-scm.com/docs/gitcredentials#_custom_helpers)), so gh's token is used. That token carries the `workflow` scope, which GitHub requires for pushing commits that change `.github/workflows`. Your git config is not modified.

## Sync

`replay_prs` skips every source PR whose merge commit a merged destination PR already has. A later run therefore replays only PRs merged in the source since the last run, whatever numbers they get. `clone_source` re-clones each time, and `sync_refs` moves every branch that is still behind, so new commits pushed straight to a source branch arrive too. A sync doesn't update PRs it has already copied. That is fine, because a merged PR doesn't change.

## What GitHub shows on a replayed PR

The PR page shows "Merged", the original merge commit, and the commits and diff, which are identical. The dates are the time of the copy, and the person who opened and merged it is the account that ran the copy, because the API can't set either. The head branch is deleted, the same as after a normal merge with "Delete branch", so the page offers "Restore branch".
