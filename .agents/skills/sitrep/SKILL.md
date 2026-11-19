---
name: sitrep
description: >-
  Show the colour-coded at-a-glance situation report for this firstmate home.
  Use when the captain invokes /sitrep or asks for a sitrep, a situation report, how all the projects are doing at a glance, what needs their decision right now, or which workers are running and how much memory they use.
user-invocable: true
metadata:
  internal: true
---

# sitrep

Run `bin/fm-sitrep.sh` for this home and relay its output.
The script's header owns every section, status word, colour, threshold, and flag; do not restate or re-derive any of it here or in chat.

1. Run `bin/fm-sitrep.sh --no-color` once.
   Chat does not render terminal colour codes, and the status words carry the same meaning without them.
2. Relay the output faithfully inside one plain code block, unedited and untrimmed.
   The report is written in captain-facing language for exactly this purpose, so the verbatim output is the deliverable rather than evidence to translate.
3. After the block, add at most three short lines naming what needs the captain now: overdue decisions first, then anything blocked, then other decisions or reviews.
   Add nothing when the report already says nothing needs them.
4. Mention once, in a few words, that running `bin/fm-sitrep.sh` in a terminal shows the same report in colour, and `--json` gives the machine form.

The invocation is read-only.
It never answers a decision, merges, steers, dispatches, stands work down, or tidies records; any follow-up the captain asks for afterwards goes through the normal lifecycle and authority rules.
If the script fails, report its error plainly instead of composing a substitute report from other sources.
For the narrative pick-up-where-I-left-off digest, the dated report, or the interactive board, use `/bearings` instead.
