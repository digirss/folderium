# Folderium-X 0.1.3 action-beachball release evidence — 2026-09-30

Release owner: TL (Hermes session 20260929_233419_4d204e). Per Leon: fix everything that beachballs on user actions; no OpenAI-family workers (token exhausted) — all work TL self-performed.

## Released artifact
- Commit e8f6a14707d789b1fdd75643389931e024c22b6b on leon/main (ff from 4e32855), pushed to fork digirss/folderium, remote readback e8f6a14.
- Formal bundle build/Folderium-X.app, version 0.1.3 (4) — content-only change over nav release, executable SHA256 eb140f8a495463c581225b165ec936a1ba99b036cfbf87512686520c2fbcdc32, codesign --strict PASS.

## What was fixed (all previously ran synchronous FileManager I/O on the main actor)
1. performDropOperation (drag-drop move): whole move pipeline (no-op/descendant guards, moveItem) in Task.detached; UI refresh on MainActor.
2. pasteFiles cut-branch: moves + conflict resolution detached; UI state hop.
3. commitInlineRename: moveItem detached; success path updates selection/list on main, failure alert on main.
4. Context-menu moveToTrash / deleteFile: trashItem/removeItem detached; refresh after.
5. createNewFolderInActivePane / createNewFolder / createNewFile: unique-name probing + mkdir/write detached.
6. getUniqueDestinationURL (both variants) + resolveConflictDestination + resolveDropConflict: existence probes and replacement removeItem detached; NSAlert prompts remain on main (user interaction).
7. selectFolder: startAccessingSecurityScopedResource + saveBookmark detached; state applied on main after grant confirmed.

## Verification chain
- RED first: tests/test_action_responsiveness.py failed 10/12 against unmodified 0.1.3 source (method-body extraction + blocking-call detection outside Task.detached).
- GREEN: 12/12 new guards; full suite 30/30 PASS; compiled slow-filesystem harness PASS; QuickAccess smoke PASS.
- CLT build exit 0 (first two attempts failed on Swift concurrency errors: await in repeat-while condition, missing .value — fixed, logged honestly); codesign strict PASS.
- Install: atomic swap with verified rollback; running PID 21184 exact formal path; window present (LaunchServices activate after known 0-window bare-exec state), frontmost, CPU 0.1%; 5s idle sample shows main thread in event-loop wait, no blocked filesystem calls.
- User state: queue.json SHA unchanged e3d2ef98..., paused, 0 batches; defaults unchanged.

## Rollback
- release-backups/Folderium-X-v0.1.3-nav-before-action-20260930.app (SHA 2dbe0908..., codesign OK) — immediate previous release
- release-backups/Folderium-X-v0.1.2-before-v0.1.3-20260930.app; Folderium-X-v0.1.1-before-v0.1.2-20260929.app
- Procedure: quit app, mv build/Folderium-X.app aside, cp -Rp chosen backup to build/Folderium-X.app; git reset --hard <sha> for source.

## Residual limits
- No real SMB mounted; slow-filesystem harness is controlled fault injection, not SMB acceptance.
- Per-action GUI automation not run (OpenAI GUI worker unavailable); acceptance = source guards + compiled harness + real launch + idle main-thread sample. Next real-world SMB beachball report should be sampled live before claiming that surface fixed.
