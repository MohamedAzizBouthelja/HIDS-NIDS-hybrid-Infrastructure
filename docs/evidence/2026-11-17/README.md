# Successful live OSPF baseline

Inspected locally on 17 November 2026, Africa/Tunis. The user downloaded
`core-ospf-43959781140-1.zip` and placed it in the repository workspace.
This archive retains an unchanged copy and all seven original JSON files.
These files are supplied live lab evidence, separate from local simulations.

SHA-256 of the ZIP:
`aa9acfd768a3908659d20c9c943007fa1b783cb15d86e549cd5f2fe6615e1a46`

The filename indicates run **43959781140**, attempt **1**:
[workflow run](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/actions/runs/43959781140).
The URL is constructed from that filename. GitHub run metadata was not
independently queried. The user reports a successful workflow; the ZIP
does not include the final job log, execution timestamp or commit SHA.

## Verified contents

- `neighbors.json`: final observation has FULL neighbors R1=3, R2=2,
  R3=2, R4=3. Earlier observations are retained unchanged.
- `routes.json`: twelve unique remote loopback /32 routes through OSPF 10.
  R1 to 10.255.0.4 selects only 10.0.12.2 via FastEthernet0/0; R4 to
  10.255.0.1 selects only 10.0.24.1 via FastEthernet0/0. Both metrics are 21.
- `loopback-pings.json`: twelve distinct remote loopback-source tests,
  each with raw IOS output reporting 100 percent (3/3).
- `console-transcript.json`: four `write memory` outputs include `[OK]`.
  R2, R3 and R4 include the image-version NVRAM confirmation and successful
  continuation; R1 saves without that question.
- `before-ospf.json`, `ospf-plan.json`, `pending-commands.json`: original
  prerequisite/configuration evidence from the same supplied ZIP.
- `inspection.json`: locally generated counts, provenance and checksum.

Saving was acknowledged; persistence after a restart has not been tested.
This artifact establishes the baseline, not failover, traceroute, packet
loss, convergence time, repeat-deployment behavior or the tertiary backup.

See [Progress.md](../../../Progress.md) and the new
[failover workflow](../../../.github/workflows/gns3-core-failover.yml)
for the next checkpoint. The 16 November evidence remains historical.
