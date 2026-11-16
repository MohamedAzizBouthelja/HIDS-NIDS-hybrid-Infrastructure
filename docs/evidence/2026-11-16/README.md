# Live lab evidence checkpoint

Recorded on 16 November 2026, Africa/Tunis.

This checkpoint preserves the live outputs supplied in the project chat
and records their limits. It is not a download of the original GitHub
artifact ZIP. No original run ID, run URL, exact run timestamp or failed
run commit was supplied with the neighbor-table excerpt.

## Preserved records

| File | Source | What it supports |
| --- | --- | --- |
| [ospf-neighbors-attempt-40.json](ospf-neighbors-attempt-40.json) | Transcription of the user's excerpt from live `neighbors.json`, attempt 40, for R1-R4 | All ten expected directional neighbor entries were FULL, with their local interfaces, peer addresses and router IDs |
| [interface-success-confirmation.txt](interface-success-confirmation.txt) | The user's explicit confirmation in chat | The user reported that the live interface workflow passed all tests and saved the configurations; this is not the original job log |
| [local-workstation-ipv4.json](local-workstation-ipv4.json) | Direct read-only .NET network-interface inspection on the author's Windows PC | Adapter aliases/descriptions, IPv4 prefixes, operational states and configured gateways at the checkpoint; it does not inspect the Ubuntu guest or friend's host |
| [ospf-save-confirmation-failure.txt](ospf-save-confirmation-failure.txt) | User-supplied error from the subsequent OSPF run | Execution reached `write memory` and waited at the NVRAM overwrite confirmation; it does not establish a successful save or a complete workflow pass |

The neighbor records retain the failed workflow's `full: false` flags.
Those flags were parser results: the raw output contains `FULL/  -`, which
the old parser discarded. Do not interpret those flags as failed IOS
adjacencies. The corrected parser normalizes the spacing.

The same raw output is stored in
[the regression fixture](../../../tests/fixtures/ospf-neighbors-ios.json).
That fixture was transcribed from these user-supplied live tables.
Generated HTTP/TCP simulation outputs under the ignored `artifacts/`
directory were not used as live evidence for this archive.

## Observed adjacency count

| Router | FULL neighbors | Neighbor router IDs |
| --- | --- | --- |
| R1 | 3 | 10.255.0.4, 10.255.0.3, 10.255.0.2 |
| R2 | 2 | 10.255.0.4, 10.255.0.1 |
| R3 | 2 | 10.255.0.4, 10.255.0.1 |
| R4 | 3 | 10.255.0.1, 10.255.0.3, 10.255.0.2 |

These are observations from one supplied checkpoint, not a continuous
availability measurement. They establish neighbor state and observed
addresses/interfaces. They do not establish route selection, the exact
running OSPF cost settings, loopback interface masks, failover timing,
traceroute, end-to-end ping success or OSPF startup persistence.

## Configuration reference and remaining evidence

The documented source version is
[`d40a5140c7b63ead4476ed528b41608fe84e81eb`](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/commit/d40a5140c7b63ead4476ed528b41608fe84e81eb).
This identifies the code and manifests at the documentation checkpoint;
it does not identify the failed run's commit.

See [Progress.md](../../../Progress.md) for the complete interface/IP
register, confirmed milestones, known gaps and next actions.

To complete primary-file evidence, retain the original successful interface
job artifact and the corrected OSPF job's `routes.json`,
`loopback-pings.json`, `neighbors.json`, `before-ospf.json` and
`console-transcript.json`, together with their run URL, run ID, commit,
timestamp and final job result. The workflows currently retain artifacts
for seven days. No claim is made that those missing files have already
been downloaded or that the corrected live OSPF job has completed.
