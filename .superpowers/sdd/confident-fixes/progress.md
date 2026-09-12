# SDD ledger — plan: inline "Confident HIGH/MEDIUM Fixes" plan from controller session (no plan file; briefs inline in dispatches)

- BASE: e741e0986d21bd0f6823c5ac9488a45f72c0cdb2 (clean tree, single commit)
- Ruling: working directly in /Users/alexalbu/repos/sbx-helper without a git worktree — tasks are small same-repo fixes, worktree would break SwiftPM absolute paths and add nothing. Cost if wrong: none, tree is clean and each task commits separately.
- Ruling: plan lives inline in conversation, so no task-brief/review-package script files; briefs are pasted verbatim into dispatches and diffs reviewed via git commands. Cost if wrong: slightly larger context, no correctness impact.

## Pre-flight conflict scan

| Tasks | Shared file/interface | Finding |
|-------|----------------------|---------|
| 1 vs 2 | none | clean |
| 1 vs 3 | none (3 touches ConfigStore/SbxHelperApp, 1 touches ConfigCodec loadConfig catch only) | clean — note: 3 removes SbxHelperApp's second loadConfig call, which makes 1's rename-once semantics simpler; order-independent |
| 1 vs 4 | none | clean |
| 1 vs 5 | none | clean |
| 2 vs 3 | none (different SbxServices files) | clean |
| 2 vs 4 | none | clean |
| 2 vs 5 | none | clean |
| 3 vs 4 | none | clean |
| 3 vs 5 | Package.swift untouched by 3 | clean |
| 4 vs 5 | none | clean |

Self-check per task: tests specified match code specified; files created (none) vs modified consistent. Scan clean — proceeding.
Task 1: complete (commits e741e09..27e3652, review clean after 1 fix round; 2 deferred minors: no-.bak lock for unreadable/lenient paths, second-load return value)
Task 2: complete (commits 27e3652..cd150cd, review clean; deferred minors: identical trySettle bodies, handler-nil ordering, elapsed bound)
Task 3: complete (commits cd150cd..a655384, 1 fix round + re-review). Ruling: ConfigStore old-init duplication KEPT over delegation — delegated actor self.init form crashed deterministically at runtime per implementer (8/8 repro, EXC_BAD_ACCESS exclusivity trap in __allocating_init; 4/4 clean without). Cosmetic-only concern; will not revisit without a minimal repro. Cost if wrong: two init bodies could drift; mitigated by ConfigStoreTests covering both paths.
Task 4: complete (commits a655384..6196f93, review clean). Ruling: Dictionary NFC/NFD key conflation is inherited stdlib behavior, out of scope — ordering parity fixed for surviving keys; recorded as known limitation, not a defect of this task.
Task 5: complete (commits 6196f93..b2ca193, review clean)
Final verification: full suite 399/399 green on rerun. Ruling: single ScanCoordinationTests failure in first full run was parallel-load flakiness (passes in isolation 8/8; our diff touches no scan/spinner logic) — not attributed to these changes.
