# Folderium-X 0.1.3 release evidence (beachball navigation fix) — 2026-09-30

Release owner: TL (Hermes session 20260929_233419_4d204e, Herdr w1G:p29). Prepared under standing no-HITL authorization ("ok go next"); user later instructed: no more OpenAI-family worker dispatches.

## Released artifact
- Formal bundle: /Users/leon/LeonPJ/folderium/build/Folderium-X.app
- Version 0.1.3 (build 4), commit 4e32855ca124d6cfdb4132d3c26e93d1694a88b2 on leon/main (fast-forward from 8e930e0)
- Executable SHA256 2dbe0908a19202adde8750f600fbc0f3ff5b349cd8b7274d69643697ed94aca6; codesign --strict PASS; tree-identical to candidate worktree bundle
- Fork remote digirss/folderium leon/main readback at 4e32855ca124d6cfdb4132d3c26e93d1694a88b2

## Verification chain
1. 18 Python source regression guards PASS (tests/test_navigation_responsiveness.py et al.)
2. Compiled Swift slow-filesystem harness PASS: responsive main actor, stale-result discard, 15s timeout (6/6 scenarios)
3. QuickAccessVisibility smoke PASS; CLT build + strict codesign PASS
4. Canary GUI (Codex Computer Use, worktree bundle, same SHA): fixture navigation two cycles, window responsive, no beachball
5. Formal-bundle read-only GUI check: window exists, responsive, no modal, no beachball
6. Post-merge re-run on formal repo: all tests + harness + smoke PASS, tree clean

## Startup-path discrepancy adjudication (ticket FAIL was wrong expectation, not code bug)
Formal GUI showed both panes at /Users/leon/Downloads while defaults hold left=/Applications, right=/Users/leon/Music.
Decoded bookmarks live with a compiled Swift tool: BOTH pane security-scoped bookmark roots are /Users/leon/Downloads.
Pre-existing (0.1.2) resolveRestoredPath guard: saved path outside bookmark root falls back to bookmark root.
/Applications and /Users/leon/Music are outside /Users/leon/Downloads, so startup shows Downloads BY DESIGN in both 0.1.2 and 0.1.3. No regression. User-visible options (not applied): re-grant bookmark per desired root, or drop sandbox fallback guard — both are product decisions for Leon.

## Rollback
- release-backups/Folderium-X-v0.1.2-before-v0.1.3-20260930.app (executable SHA b6d8832c8c374d102e10a1fbd0efe2fe708199a3a407565f8dcc5bd5b00c2222, codesign strict PASS)
- release-backups/Folderium-X-v0.1.1-before-v0.1.2-20260929.app (SHA 0824ce13b4f945db20fefb23800809fa32127f82c40fc7f17d792687618c9626)
- Both relocated OUTSIDE build/ (build script does rm -rf build) — this fixes the prior release note's flaw of keeping backups inside build/backups/
- Procedure: quit Folderium-X (currently PID 3109, formal path), then `mv build/Folderium-X.app release-backups/.Folderium-X-0.1.3-retired.app && cp -Rp release-backups/Folderium-X-v0.1.2-before-v0.1.3-20260930.app build/Folderium-X.app`; git reset --hard 8e930e0 if source rollback also wanted

## User state (verified unchanged)
- queue.json SHA e3d2ef98c02959b43a6e34c77a650041d389e996f6165a13a58e7d5c4750f50f, queuePaused=true, batches=0
- defaults: left=/Applications, right=/Users/leon/Music (canary test keys removed; 94 keys byte-equal to pre-test snapshot)

## Residual limits (unchanged, honest)
- No real SMB mounted; simulated slow-filesystem tests are not SMB acceptance
- URL-scheme handler re-registration side effect of direct executable launch not re-verified
- Other worktrees' lanes untouched: enter-focus (2b2bb96), quick-access (da9cf8a), volume-enumeration (e00a708)
