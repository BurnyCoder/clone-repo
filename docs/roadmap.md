# Roadmap

clone-repo only copies what it can reproduce exactly, and `preflight` / `check_merges` refuse everything else. This page lists each refused case with the planned way to support it. The [README](../README.md#what-is-and-isnt-copied) has the full copied / not-copied list.

| Refused today | Planned approach | What would still differ |
|---|---|---|
| Issues | Create issues and PRs together in number order, so the counter stays aligned. Copy title, body, labels and state (`state_reason` for closed issues). | Dates and author (the copying account). The body could say "originally by @user on date" when the author differs. |
| Numbering gaps (deleted issues, discussions) | Create a closed placeholder issue for each missing number. | Placeholders are visible. |
| Closed, unmerged PRs | Push the head from the source's `refs/pull/N/head` (fetched explicitly, since a bare clone skips it), open the PR, then close it. | None beyond dates. |
| Open PRs | Same, but leave the PR open and keep its branch, so skip the branch delete and exclude it from the mirror prune. | Dates. |
| Squash / rebase-merged PRs | Open the PR from `refs/pull/N/head` against the pre-merge base, push the real squash commit, then close the PR with a note naming the merge SHA. | The state is CLOSED instead of MERGED. GitHub only marks merged when the head is in the base. |
| Fork PRs | Push the head to a namespaced branch such as `pr/N/<branch>`. | The head branch name. |
| Comments, reviews, labels, assignees, milestones | Comments as issue comments with an "originally by" line. Labels via `POST /issues/N/labels`. Milestones created first, then assigned. Assignees only if they have access. Inline review comments as plain comments. | Authors and dates of comments. Inline review threads become plain comments. |
| More than 1000 PRs | Paginate past gh's `--limit 1000`. | None. |

## Other gaps

- **Topics and homepage:** `gh repo edit --add-topic / --homepage` from the source.
- **Releases:** recreate them from `gh release view` (notes, draft/prerelease flags) and re-upload the assets.
- **Git LFS:** `git lfs fetch --all` in the bare clone, then `git lfs push --all` to the destination, as in GitHub's [duplicating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository).
- **Actions during the replay:** turn off Actions in the destination while replaying (`PUT /repos/{owner}/{repo}/actions/permissions`), then restore it, so replayed pushes don't start CI runs.
- **Rate limits:** GitHub allows about 80 content-creating requests per minute and 500 per hour, and recommends at least one second between writes ([REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)). Large repos would need a pause between PRs and should honor `retry-after`.

## Related tools

- [itchyny/github-migrator](https://github.com/itchyny/github-migrator) keeps numbers and comments, but turns PRs into issues.
- [GitHub Enterprise Importer](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrating-between-github-products/about-migrations-between-github-products) migrates PRs fully, but its documented destinations are GitHub Enterprise Cloud and GHE.com.
