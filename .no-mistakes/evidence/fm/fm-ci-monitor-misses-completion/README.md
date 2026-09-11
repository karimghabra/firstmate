# Live evidence: CI monitor "waiting" after results exist (firstmate PR 6 replay)

All transcripts come from running the real `bin/fm-crew-state.sh`, `bin/fm-inactive-reconcile.sh`,
`bin/fm-wake-drain.sh`, and `bin/fm-watch.sh` from this change against the real GitHub forge.
The real `gh` read the real check rollups of karimghabra/firstmate PR 6 (14 checks, last settled
2026-09-11T17:30:54Z) and PR 5, and of a public PR whose checks were still running
(tibroc/tante_emma#73).

The only stub is the no-mistakes run record. A stalled pipeline CI monitor can't be induced on
demand, so the stub replays the 2026-09-11 reading word for word (`ci,running,25m3s`,
"quiet 24m25s ago: log: CI checks running, waiting for results..."). `drive-pr6-replay.sh` is the
driver that produced every transcript here.

| File | Shows |
|---|---|
| live-base-before.txt | BEFORE (base 609dd58): same inputs, the line reads only `validating (running)`, and the real watcher stays silent until it is killed |
| live-behind.txt | AFTER: `pipeline monitor behind: all 14 checks settled at 2026-09-11T17:30:54Z (…m ago), not yet observed`; the state stays `working · source: run-step`; one forge call |
| live-poll-window.txt | at the moment firstmate read PR 6 (69s after settle), and at 240s: "within the monitor's poll window"; at 241s: behind |
| live-running.txt | real PR with checks still running: `waiting on 2 of 3 checks: Backend, Frontend`, no wake |
| live-wake.txt | the inactive scan wakes once; a repeat scan (age moved) is quiet; after drain and ack it stays quiet; the task stays working; no terminal outcome |
| live-new-occurrence.txt | a later settlement on a new run head is a new occurrence and gets one new wake |
| live-watch.txt | the real `fm-watch.sh` poll exits with `check: inactive-outcome`, and the queue row names the behind monitor |
| live-wake-negative.txt | a monitor waiting for a CI re-run, or checks inside the poll window: no wake |
| live-rerun-wait.txt / live-head-moved.txt / live-unreadable.txt / live-monitor-green.txt | the guards: not behind when not claiming to wait, a foreign head is not compared, an unreadable forge is reported, and no forge read once the monitor itself reports green |
| live-blocked-claim.txt | the removed recency extension: a timed-out blocked claim during a quiet ci wait reads `superseded by active run`, identical to base |
