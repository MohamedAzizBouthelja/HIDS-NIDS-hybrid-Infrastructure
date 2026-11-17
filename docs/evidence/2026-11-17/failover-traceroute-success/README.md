# Successful failover with traceroutes

Original user-downloaded ZIP and four original JSON files, inspected on
17 November 2026. `inspection.json` is a locally derived validation summary.

[Run 44156385861, attempt 1](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/actions/runs/44156385861)
records commit `3c9e910742530e61f6c23b386ce1ce69095ad53d` and execution from
19:16:10 to 19:16:50 UTC (20:16:10 to 20:16:50 Africa/Tunis).
Metadata comes from the supplied artifact; the GitHub job was not independently queried.

ZIP SHA-256:
`eb887dbc0fc5bdc31706d7018ee41520dc48bff9420567b143a91cd4ee22e0b7`

The result records `passed: true`, `restored: true`, `capture_traceroute: true`
and empty error fields. Raw outputs corroborate all six traces:

| Phase | Direction | First hop | Second hop | Router path |
| --- | --- | --- | --- | --- |
| Baseline | R1 to R4 | 10.0.12.2 | 10.0.24.2 | R1-R2-R4 |
| Baseline | R4 to R1 | 10.0.24.1 | 10.0.12.1 | R4-R2-R1 |
| Backup | R1 to R4 | 10.0.13.2 | 10.0.34.2 | R1-R3-R4 |
| Backup | R4 to R1 | 10.0.34.1 | 10.0.13.1 | R4-R3-R1 |
| Recovery | R1 to R4 | 10.0.12.2 | 10.0.24.2 | R1-R2-R4 |
| Recovery | R4 to R1 | 10.0.24.1 | 10.0.12.1 | R4-R2-R1 |

All traces contain two responding hops without asterisk timeouts. The second
hop uses an interface address belonging to the destination router, although
the target is its loopback. Numeric hop addresses are retained unchanged.

The console transcript also establishes unique OSPF next hops for both
directions in all three phases, six measured ping tests at 3/3, `no shutdown`
and restored R1 FastEthernet0/0 up/up. No `write memory` was issued.

This proves observed primary/backup/recovered paths at this checkpoint.
It does not measure transition packet loss, precise convergence time or
the direct R1-R4 tertiary backup. Traceroute RTTs are individual probe
round-trip measurements and must not be presented as convergence times.
