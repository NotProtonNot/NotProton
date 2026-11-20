# Fork synchronization

When asked to “sync fork”, update every remote fork branch against the latest
`upstream/main` while preserving each branch's features. Use
`python3 tools/sync-fork.py --push` from a clean or dirty checkout; it operates in
its own worktree, verifies changes and pushes all branch updates atomically.

If it reports a conflict, resolve it in the indicated sync worktree using the
actual upstream and branch behavior, run appropriate feature tests, stage the
resolution, and continue the reported session. The assistant handles conflicts;
do not ask the user to resolve them. Never use blanket ours/theirs resolutions,
force-push or discard local work. Git's recorded resolutions can be reused when
the same conflict recurs, but new conflicts require review.
