# Fork synchronization

Run `python3 tools/sync-fork.py --push` to fetch `origin` and `upstream`, merge
`upstream/main` into fork `main`, then merge that result into every remote fork
branch in an isolated worktree, run the
available compatibility, launcher and feature checks, and push the verified
results together with an atomic non-force push. Local branch checkouts and their
uncommitted changes are not modified. The remote's branch list and tips are
checked again immediately before pushing; if they changed, restart the sync.

Without `--push`, the command prepares and verifies the results only. It prints
its session path; publish them later using `--continue SESSION --push`.

Git's rerere cache reuses previously recorded conflict resolutions. If a new
conflict appears, the script stops before pushing anything and prints the
isolated checkout and session path. Resolve and stage the conflict in that
checkout, verify the feature, and resume with `--continue SESSION --push`.
For a failed test, commit the correction in that checkout before continuing.
The session and results survive interruption; successfully pushed sessions
remove the temporary worktree. No merge strategy can safely resolve every future
semantic conflict without review.

`python3 tools/tests/sync-fork-test.py` tests the workflow against temporary
local remotes, including a conflict, continuation, atomic publishing, feature
history preservation, and isolation of a dirty working checkout.
