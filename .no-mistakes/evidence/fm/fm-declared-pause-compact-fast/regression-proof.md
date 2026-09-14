# Issue #34 regression proof: idle-compact declared-pause settle timing

## Scenario: declared episode, 61s after send

Ran the identical function body (fm_idle_compact_marker_write a declared=1
settling marker with settle_epoch 61s in the past, then
fm_idle_compact_process_task) against two checkouts of bin/fm-idle-compact.sh,
using the real, unmodified library functions (only tmux/composer/crew-state
external boundaries stubbed):

- **Pre-fix (3afcebc, base commit):** phase stayed `settling` at 61s (bug
  reproduced - the declared path was still waiting out the ordinary
  FM_IDLE_COMPACT_INTERVAL/FM_IDLE_COMPACT_SETTLE_SECS default of 300s).
- **Post-fix (445fd92, target commit):** phase advanced to `done` and the
  ring `compacted - start the validation run now` was sent at 61s.

## Scenario: real config file read end-to-end via fm_idle_compact_tick

config/idle-compact written as:
```
15
5
```
(threshold-minutes=15, declared-settle-secs=5, the documented two-line
contract). A declared=1 settling marker aged 6s past send, run through the
real `fm_idle_compact_tick` sweep entry point (the same one bin/fm-watch.sh
and bin/fm-supervise-daemon.sh call) advanced to phase=done and rang the
worker - proving the config value is read and threaded through the real
sweep, not just passed as a unit-test argument.

## Scenario: config parsing edge cases (fm_idle_compact_declared_settle_secs)

| config/idle-compact content | resulting declared_settle_secs |
|---|---|
| absent/empty | 60 (default) |
| `30` (no second line) | 60 (default) |
| `30\n90` | 90 |
| `30\nabc` | 60 (default - invalid never fails the caller) |
| `30\n0` | 60 (default) |
| `30\n-5` | 60 (default) |

All match docs/configuration.md's documented "a config typo must never fail
a watcher loop" contract.
