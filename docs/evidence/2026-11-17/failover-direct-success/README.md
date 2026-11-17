# Live direct OSPF backup and recovery

[Run 44163708409, attempt 1](https://github.com/MohamedAzizBouthelja/HIDS-NIDS-hybrid-Infrastructure/actions/runs/44163708409)
records commit `8cc204cc5db03967676822b1c82a328343f68e71` and ran from
21:01:21 to 21:02:27 Africa/Tunis on 17 November 2026. The metadata comes
from the downloaded artifact. This directory retains the original ZIP,
its four raw JSON files, and the locally derived `inspection.json`.

ZIP SHA-256
`a264141a1da0d62a71a13b367a099051735b12290aedb6f633284a200cc4032d`

| Checkpoint | R1 → R4 trace hops | R4 → R1 trace hops |
| --- | --- | --- |
| Baseline through R2 | 10.0.12.2 → 10.0.24.2 | 10.0.24.1 → 10.0.12.1 |
| Backup through R3 | 10.0.13.2 → 10.0.34.2 | 10.0.34.1 → 10.0.13.1 |
| Direct backup | 10.0.14.2 | 10.0.14.1 |
| Secondary recovery through R3 | 10.0.13.2 → 10.0.34.2 | 10.0.34.1 → 10.0.13.1 |
| Primary recovery through R2 | 10.0.12.2 → 10.0.24.2 | 10.0.24.1 → 10.0.12.1 |

All ten traces match the selected OSPF next hop and all ten measured pings
returned 3/3 replies. During the direct checkpoint, the console showed
both R1 transit interfaces administratively down. Each endpoint used its
FastEthernet2/0 interface and traced to the other endpoint in one hop.
R1 FastEthernet1/0 and then FastEthernet0/0 returned to up/up. The
transcript shows no configuration save. This run sampled reachability at
each checkpoint. It did not enable the transition loss sampler.
