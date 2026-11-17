# Live OSPF failover loss measurement

[Run 44160336159, attempt 1](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/actions/runs/44160336159)
records commit `545c520af8c5afd6809f9b8c9e3139a555ed4664` and ran from
20:39:01 to 20:40:09 Africa/Tunis on 17 November 2026. Metadata comes from
the supplied artifact. This directory retains the original ZIP, its five
raw files, and a locally computed `inspection.json`.

ZIP SHA-256
`30b0dba18a1c1ef652788f9db78c9836c0b4c00cb780181f4ef8b3d11b576439`

| Transition | Probes started after command | ICMP timeouts | First reply in final uninterrupted streak |
| --- | ---: | ---: | ---: |
| R1 link shutdown and switch to R3 | 24 | 5 consecutive | 7.104 s after shutdown command start |
| R1 link restoration and return to R2 | 25 | 0 | 1.315 s after restoration command start |

The shutdown window recorded five consecutive missed replies followed by
19 replies. In the restoration window, all 25 probes started after the
command received replies. One additional probe straddled the restoration
command start and also received a reply. Both windows had three successful
pre-transition probes and no console errors.

Probes were ICMP round trips initiated from the R4 loopback toward the R1
loopback. The 7.104 s value measures from the shutdown command timestamp
to the read of the first sustained reply, with console and sampling delays
included. The 1.315 s value gives the first sampled post-restoration reply.
This test can miss interruptions between probes and cannot isolate the
exact OSPF route change time.

The transcript confirms primary routing through R2, backup routing through
R3, and primary recovery through R2, with 3/3 pings in both directions at
each checkpoint. R1 FastEthernet0/0 returned to up/up. The restoration
warning in the supplied run excerpt came from the simulated failure test.
