# Portable parallel lane rebalance (b92e741) - local test evidence

| Scenario | Result | Evidence |
|---|---|---|
| Coverage guard passes and reports balanced, fully hinted lanes | pass: parallel_max_ms=414299, imbalance 30 ms, parallel_unhinted=0 | check-coverage-head.txt |
| Regression repro: base split packs lane 1 over the 10-min cap, head split is under it | base lane1 624299 ms (10.4 min) vs lane2 204269; head 414269 / 414299 | lane-balance-base-vs-head.txt, pr3-ci-prefix-portable-parallel-job-walls.txt (PR #3 lane 1 cancelled at 616 s) |
| Lane 1 runs end to end with the CI flags (Pi gate skip is fatal) | pass: 11/11, 0 failed, 0 gate skips, 557 s local wall on WSL (ran alongside the mutation drive) | lane-portable-parallel-1-run.log, fm-test-timing-portable-parallel-1.json |
| Lane 2 runs end to end | pass: 13/13, 0 failed, 502 s local wall | lane-portable-parallel-2-run.log, fm-test-timing-portable-parallel-2.json |
| Stored lane order == runner's longest-hint-first schedule; lanes partition the same 24 proven-isolated scripts; Pi test stays in the lane with the Pi install | pass | lane-order-partition-and-nonlane-scheduling.txt, ci-yml-semantic-parity.txt |
| Adversarial: other --list-scheduled selections and lanes are unchanged from base | pass: byte-identical for proven-isolated, all, family, portable-serial, serial shard, herdr, script list | lane-order-partition-and-nonlane-scheduling.txt |
| Adversarial: guard catches drift (pre-fix split, missing hint, >5% imbalance, hint leak), tolerates small <5% moves | pass | guard-mutation-drive.txt |
| Mechanical cherry-pick of upstream 869ae90; workflow semantics unchanged (comments only) | pass | upstream-cherry-pick-parity.txt, ci-yml-semantic-parity.txt |
| CI on PR #4 at this head: both parallel lanes succeed under the 600 s cap | success: lane 1 434 s / 426 s, lane 2 351 s / 414 s job wall | pr4-ci-portable-parallel-job-walls.txt |

Note: mutant copies report total=195 because the trimmed test file added to each copy is itself a new tests/*.test.sh.
