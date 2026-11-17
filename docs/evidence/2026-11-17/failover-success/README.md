# Successful controlled failover

Original user-downloaded ZIP and its three original JSON files, inspected
on 17 November 2026. `inspection.json` is a local derived summary.

[Run 44153014000, attempt 1](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/actions/runs/44153014000)
ran source commit `2cdd46d40a3824d6b9240e2e71e693e9a0e3570a`, according to
the artifact's result metadata. GitHub run metadata was not independently queried.
Execution timestamps: 2026-11-17 18:56:13–18:56:51 UTC
(19:56:13–19:56:51 Africa/Tunis).

ZIP SHA-256:
`cb83c3ae27f38d9e44d50b1c455b08cbcfae93f844e3469ea6ce125b3340fa44`

Inspection confirms `passed: true`, `restored: true`, empty error fields,
and corroborating raw command output:

| Phase | R1 next hop to R4 | R4 next hop to R1 | Measured pings |
| --- | --- | --- | --- |
| Baseline | 10.0.12.2, Fa0/0 | 10.0.24.1, Fa0/0 | 3/3 both directions |
| R1 Fa0/0 shutdown | 10.0.13.2, Fa1/0 | 10.0.34.1, Fa1/0 | 3/3 both directions |
| Restored | 10.0.12.2, Fa0/0 | 10.0.24.1, Fa0/0 | 3/3 both directions |

The transcript confirms `no shutdown`, restored R1 Fa0/0 up/up, and no
`write memory`. The startup configuration was not changed by this test.

First valid backup route polls occurred at 5.729 s (R1), 6.029 s (R4).
First valid primary recovery polls occurred at 18.823 s (R1), 8.617 s (R4).
Each timer starts with its route polling phase; polls are sequential and
include command/transport delays. These are observation latencies, not exact
convergence times. Pings ran after route selection; the test does not measure
packet loss during transitions. Traceroute and tertiary backup remain untested.
