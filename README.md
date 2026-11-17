# HIDS-NIDS-hybrid-Infrastructure

A GNS3 networking and security lab developed in stages: LAN and routing,
resilience, QoS, HIDS/NIDS, and an eventual AWS VPN connection. GitHub Actions
will provide controlled automation and evidence of lab state.

## Current stage

The two-PC foundation has passed manual bidirectional ping tests and the
GitHub Actions foundation check (reported by the user). A single c7200 has
also booted successfully with IOS 15.3(3)XB12 and six FastEthernet ports.
The router hardware check also passed on the real runner (reported by the
user), and R1's saved Idle-PC value is `0x60630338`. The core deployment
has created four routers and five links in Hybrid-Core-Lab. A supplied API
artifact showed all four routers started, and the user confirmed their IOS
consoles reached a prompt. The interface workflow then passed all ten
directional neighbor ping tests and saved all four configurations (reported
by the user). The successful downloaded OSPF artifact confirms ten directional FULL
neighbors, twelve remote loopback routes, twelve routed 3/3 pings, primary
next hops through R2 and four acknowledged configuration saves.
See [the live evidence archive](docs/evidence/2026-11-17/README.md).
The user reports the corrected failover workflow passed; its successful
artifact still needs inspection. The security stack and AWS remain pending.

| Component | Location | Observed configuration |
| --- | --- | --- |
| Working computer | Project author's Windows PC | Local Git repository |
| Ubuntu working VM | Project author's PC | Running with Internet access |
| Self-hosted runner | Friend's Windows PC | Labels: self-hosted, Windows, X64, gns-lab |
| GNS3 controller | Friend's Windows PC | Version 2.2.61, http://127.0.0.1:3076 |
| GNS3 VM | Friend's VMware environment | Version 2.2.61, 192.168.238.128:80 |
| Foundation devices | GNS3 VM | PC1 and PC2, both started |

The two people work on different networks. The runner and GNS3 are on the
friend's side, so this first workflow requires no connection from the
author's Ubuntu VM to the lab. `127.0.0.1` in the workflow means the runner's
computer, not the author's computer and not a GitHub-hosted machine.

Manual tests showed five successful ping replies in each direction:

- PC1: 192.168.1.10/24
- PC2: 192.168.1.20/24

These observations are the initial baseline; they are not a claim that the
lab is always available or that automated connectivity testing exists.

## First workflow

`.github/workflows/gns3-preflight.yml` defines **GNS3 foundation check**.
It runs only when manually requested. It does not run on pushes or pull
requests, check out repository code, install software, or use AWS secrets.

It sends read-only GET requests to check:

1. The controller API returns a GNS3 version.
2. Compute `vm` is connected.
3. Project `c2de961e-c2bb-4849-bda7-2ae06e3fd28b` is opened.
4. PC1 and PC2 are VPCS nodes, started on compute `vm`.

A green result confirms API access from the runner and the expected device
state. It does **not** prove that a cable exists, IP addresses are correct,
or ping succeeds. Packet connectivity is currently checked manually.

### Run it after publishing

The workflow must be committed and pushed to the repository's default
branch before its manual trigger becomes available.

On the friend's PC:

1. Keep GNS3 and the GNS3 VM running.
2. Open the existing foundation project and start PC1 and PC2.
3. Keep the interactive runner terminal open and confirm its GitHub status
   is Idle. The runner must belong to this repository or have access to it
   through an organization runner group.

On GitHub:

1. Open this repository's **Actions** tab.
2. Select **GNS3 foundation check**.
3. Select **Run workflow**, choose `main`, and confirm.
4. Open the run to inspect its job logs and summary.

### Troubleshooting

- **Queued / waiting for a runner:** confirm the runner is online, has all
  four labels specified by `runs-on`, and is available to this repository.
- **Connection refused or timeout:** confirm GNS3 is running on the same
  Windows PC as the runner and its controller still uses port 3076.
- **HTTP 401 or 403:** the browser session may have authentication that
  the runner does not. Stop and configure credentials through GitHub
  secrets; never paste passwords or tokens into this repository.
- **VM disconnected:** check the GNS3 VM status in the desktop application.
- **Project missing or closed:** open the original foundation project.
  Recreating a project gives it a new ID; update `GNS3_PROJECT_ID` only
  after confirming the new project is the intended one.
- **PC not started on VM:** check the device name, compute placement, and
  running state in GNS3.

## Router hardware check

`.github/workflows/gns3-router-check.yml` adds the manually triggered
**GNS3 router check**. It targets the separate router test project:

- Project ID: `7b095e33-a5df-43c0-818c-ccb01e8847d5`
- R1 node ID: `812c3358-55d9-4e22-8aac-23f4eab1b483`
- Compute: `vm`; emulator: Dynamips; platform: c7200; RAM: 512 MiB
- Slot 0: `C7200-IO-FE`; slots 1 through 5: `PA-FE-TX`; slot 6: empty
- Ports: `FastEthernet0/0` through `FastEthernet5/0`

After publishing, open Router-Boot-Test in GNS3, start R1, keep the runner
online, then select **Actions > GNS3 router check > Run workflow** on GitHub.
The foundation project does not need to be open for this separate check.

The workflow only reads the API. It fails on unexpected hardware rather
than replacing adapters or restarting R1. A green result proves the
expected metadata, not IOS readiness or working packet forwarding. The
manual console test separately established that IOS booted.

The initial router metadata had an empty Idle-PC value. It has since been
set to `0x60630338`; the console remained responsive and a screenshot showed
the GNS3 VM at about 6.3% CPU. There was no before measurement, so this does
not quantify a CPU improvement. This value is specific to the tested image
and must be reassessed if the image changes.
No managed switch image is installed yet, so VLAN, RSTP and LACP experiments
still require a suitable switching device.

## Four-router topology deployment

The **GNS3 core topology** workflow creates a separate project named
`Hybrid-Core-Lab` with four c7200 routers and five Ethernet links.
The two baseline test projects are not deployment targets.

- `gns3/core-topology.json` defines project and device IDs, adapters,
  coordinates, Idle-PC, links, and the proposed link subnets.
- `scripts/Deploy-CoreTopology.ps1` reconciles the lab with that manifest.
- `tests/Test-CoreTopology.ps1` tests the real deployment script against a
  simulated API, including repeated runs, drift detection, and recovery
  after an interrupted deployment. No extra packages are needed.

| Link | First endpoint | Second endpoint | Planned subnet |
| --- | --- | --- | --- |
| R1-R2 | R1 FastEthernet0/0 | R2 FastEthernet0/0 | 10.0.12.0/30 |
| R2-R4 | R2 FastEthernet1/0 | R4 FastEthernet0/0 | 10.0.24.0/30 |
| R1-R3 | R1 FastEthernet1/0 | R3 FastEthernet0/0 | 10.0.13.0/30 |
| R3-R4 | R3 FastEthernet1/0 | R4 FastEthernet1/0 | 10.0.34.0/30 |
| R1-R4 | R1 FastEthernet2/0 | R4 FastEthernet2/0 | 10.0.14.0/30 |

The manifest's subnet labels are documentation only at this stage. The
script does not configure IOS hostnames, IP addresses, interface activation,
OSPF, EIGRP, or any other IOS settings. Interface shutdown status is
expected until the configuration milestone. API state `started` confirms
the emulator process state, not completion of IOS boot or connectivity.

### Run the deployment

After committing and pushing the files:

1. Keep GNS3, its VM, and the runner running on the friend's PC. The tested
   IOS image must remain installed on compute `vm`. The old test projects
   can be closed; this workflow does not depend on them being open.
2. In GitHub Actions, select **GNS3 core topology > Run workflow**.
3. First select **mode: plan**. Leave **start_routers** unchecked. The job
   only reads the API and records what would be created.
4. Inspect the plan: on the first run it should list one new project, four
   routers, and five links.
5. Run again with **mode: apply**. Check **start_routers** to start the four
   routers after the topology has been verified. Leaving it unchecked
   creates missing routers in the stopped state and preserves the running
   state of existing routers.
6. Open `Hybrid-Core-Lab` from GNS3's project list. If it does not appear
   immediately, refresh or reopen the project-selection dialog.
7. Repeat **apply** with the same settings to prove idempotence. The plan
   should show no new routers or links, and started routers are not restarted.

Workflow artifacts contain `plan.json`, `before.json`, and, for apply,
`after.json`. They are kept for seven days. Failed runs attempt to save the
partial state too. The files are evidence of API state, not packet captures
or proof of routing. Local `artifacts/` outputs are excluded from Git.

When starting routers, the deployment records `start-responses.json` and
polls the controller for roughly two minutes, requiring three consecutive
all-started observations. `startup-status.json` records each observation,
including per-router status and console address. HTTP request time can
extend the polling duration. A delayed update is tolerated; a router that
remains stopped or stops again causes a failure with its last known state.
Start requests are not retried automatically, and routers already started
are not restarted. This check still does not verify IOS boot completion.

If startup fails, keep the project. Inspect `startup-status.json` and
`after.json`, open the affected routers' consoles, and inspect the GNS3
server logs. A start acknowledgement alone does not establish successful
startup. If publishing a workflow fix, launch a new run on `main`; rerunning
an old job uses that run's original commit.

### Existing state and interrupted runs

The deployment creates only missing objects with the manifest's stable
IDs. It does not clone the source router's MAC address or Dynamips runtime
ID; GNS3 assigns those identities. It does not modify templates, replace
adapters on existing devices, stop routers, or delete anything.

Unexpected devices, duplicate names, incorrect adapters, an unset/wrong
Idle-PC value, project name/ID collisions, and unexpected or impaired links
cause a failure. Resolve the mismatch before rerunning. A closed target
project must be opened explicitly in GNS3; the workflow does not open it,
because doing so could trigger an existing auto-start setting.

An interrupted deployment may leave a partial project. There is no automatic
rollback: deleting partially created routers could lose later configuration.
Inspect the evidence, resolve the cause, and rerun **plan**, then **apply**
to add only what is missing. Do not manually recreate the target project
under the same name with a different ID. Avoid editing the target lab while
the deployment is running.

For a local simulated test on Windows PowerShell:

```powershell
.\tests\Test-CoreTopology.ps1
```

The deployment has run against the friend's GNS3 and its resulting API
artifact showed four started routers and five links. The immediate startup
check initially failed before those states updated; the workflow now waits
for stable status. A successful repeated run is still needed to complete
live idempotence verification.

## Core interface configuration

The separate **GNS3 core interfaces** workflow configures the router
hostnames and the ten link endpoints over their existing Telnet consoles.
It uses the installed Windows PowerShell and .NET runtime; no Python or
additional console package is required on the runner. Console addresses
and ports are read from the GNS3 API rather than assumed.

| Link | First endpoint address | Second endpoint address | Mask |
| --- | --- | --- | --- |
| R1-R2 | R1: 10.0.12.1 | R2: 10.0.12.2 | 255.255.255.252 |
| R2-R4 | R2: 10.0.24.1 | R4: 10.0.24.2 | 255.255.255.252 |
| R1-R3 | R1: 10.0.13.1 | R3: 10.0.13.2 | 255.255.255.252 |
| R3-R4 | R3: 10.0.34.1 | R4: 10.0.34.2 | 255.255.255.252 |
| R1-R4 | R1: 10.0.14.1 | R4: 10.0.14.2 | 255.255.255.252 |

### Run the interface workflow

1. Keep Hybrid-Core-Lab open and all four routers started.
2. Finish yes/no IOS setup questions manually. The reader accepts an EXEC
   prompt (`Router>`, `R1#`, etc.) and can send RETURN up to two additional
   times at the exact `Press RETURN to get started` prompt during initial
   connection. Password-protected consoles and unfinished yes/no setup
   dialogs are rejected. No passwords or setup answers are sent.
3. Close your console windows before the job and do not type into a router
   console while automation is using it.
4. Publish the files, then select **Actions > GNS3 core interfaces > Run
   workflow** with **mode: plan**. This only reads the API and displays
   the intended addresses. It does not inspect current IOS configuration.
5. Review the address plan, then run the workflow again with **mode: apply**.

Apply first verifies the exact four nodes and five unmodified Ethernet
links, then opens all four consoles and reads the existing hostname and
target interface configurations. These are backed up to `before-ios.json`
before configuration begins. A different existing IP address/mask,
unnumbered interface, or VRF is refused before any router is configured.

It applies only missing hostname, IP address and interface activation
commands. Matching interfaces are not reconfigured. It does not modify
unused interfaces or create routes, VLANs, OSPF or EIGRP configuration.
`terminal length 0` is set for each console session to avoid pagination.

After applying changes to all routers, the workflow waits for the ten
endpoints to show their expected IP and `up/up` state. It performs an ARP
warm-up ping, then a separate three-packet measured ping for every
direction of every link (ten tests). Every measured test must return 3/3
replies. The transcript preserves warm-up results too. Only after all tests
pass does it issue `write memory` on the four routers and require `[OK]`.

When that exact command produces the warning about NVRAM previously written
by a different image version and asks `Overwrite the previous NVRAM
configuration?[confirm]`, the reader sends Enter once, preserves the warning
in its transcript and waits for the normal prompt. The caller still requires
`[OK]`. Unrelated, repeated or bootstrap-image confirmations are rejected.
If a previous failed run left a console waiting at a confirmation, cancel
that old dialogue manually before closing the console and starting a new run.

Artifacts are retained for seven days and include the address plan,
pre-change hostname/interface backups, pending commands, console transcript,
and ping results. Backups cover the managed hostname and interfaces, not
the entire router configuration. The user confirmed a successful live
apply with all ten measured directional tests passing and configurations
saved. Repeat-apply behavior is covered by simulated tests and still needs
its own live confirmation.

There is no automatic rollback. A failed apply may leave some running
configuration changed. Configurations are not saved by this run until all
link tests pass; a later failure during saving may leave only some routers
saved. Inspect the evidence and correct the cause before rerunning. A
repeat apply skips matching IP/activation commands and repeats verification.
Do not erase the routers to recover from a workflow error.

The console transport handles Telnet option negotiation and rejects IOS
command errors, password prompts and setup dialogs. Telnet is used only
on the private runner-to-VM console network. No console ports need to be
opened to the Internet.

Recognized asynchronous IOS syslog messages may interrupt a command echo.
The reader accepts the command characters in order in that case while still
requiring a stable current IOS prompt and checking for command errors. The
raw interleaved output is preserved in the transcript. An interrupted job
can be resumed; matching router configuration is skipped on the next apply.

For local simulated tests:

```powershell
.\tests\Test-CoreInterfaces.ps1
```

For the optional local integration test, use an installed Python 3 runtime:

```powershell
python tests/Test-InterfaceTransport.py
```

It runs the actual PowerShell entry point against local HTTP and TCP
servers that simulate the GNS3 API and four IOS consoles. It checks plan,
apply, repeat apply, generated ping evidence, and the OSPF entry point. It
never contacts the real lab. The GitHub workflow does not require Python
or run this test.

## OSPF baseline

The **GNS3 core OSPF** workflow adds OSPF process 10 in area 0 to the
existing core. `gns3/ospf.json` defines the router IDs, link costs and the
required primary next hops. It does not enable EIGRP or perform failover.

Each router receives Loopback0 with a /32 address, also used as its OSPF
router ID:

| Router | Loopback0 and router ID |
| --- | --- |
| R1 | 10.255.0.1 |
| R2 | 10.255.0.2 |
| R3 | 10.255.0.3 |
| R4 | 10.255.0.4 |

Loopback addresses provide remote test destinations that require routing,
rather than only testing the directly connected /30 links.

| Path between R1 and R4 | Link costs | Total transit cost |
| --- | --- | --- |
| R1-R2-R4 | 10 + 10 | 20 |
| R1-R3-R4 | 30 + 30 | 60 |
| R1-R4 | 100 | 100 |

Costs are symmetric. The destination loopback's own OSPF cost is added to
the installed route metric, so the primary loopback route normally has
metric 21 rather than 20. The comparison between transit paths stays the
same. R2 and R3 can have equal-cost routes to each other through R1/R4;
the workflow requires a unique next hop through R2 specifically for the
R1-to-R4 and R4-to-R1 loopback routes.

Physical core links use the OSPF point-to-point network type. The process
has `passive-interface default`, with only the known inter-router ports
made non-passive. Loopback0 is advertised without forming neighbors.
The explicit router ID is configured before OSPF is enabled on interfaces.

### Run OSPF

1. Keep the existing core project open, all routers started and their
   interfaces configured. Close interactive console windows.
2. Publish the files. Run **GNS3 core OSPF** with **mode: plan** first.
   This validates API topology and prints the intended configuration. It
   does not open consoles or check existing IOS routing configuration.
3. Review the plan, then run **mode: apply**.
4. Allow time for neighbors and routes to converge. Inspect the job logs
   and artifacts if convergence does not complete.

Before changing any router, apply checks all four consoles and backs up
their router sections, affected physical interface configurations and any
existing Loopback0. It requires the existing link IPs and masks to match
the foundation and the endpoints to be up/up. It rejects EIGRP/other
routing processes, conflicting loopbacks, differing explicit router IDs,
different existing OSPF costs/network types, and additional routing policy.
No routing process is cleared, removed, or automatically redistributed.

Matching OSPF configuration lines are skipped on repeated apply. After
configuration, verification requires:

1. Two consecutive observations of every expected neighbor in FULL state:
   three on R1, two on R2, two on R3 and three on R4 (ten directional
   observations across five unique adjacencies).
   IOS may display the state as `FULL/  -`; the parser normalizes spaces
   before counting it as `FULL/-`. Logs label the count `parsed_neighbors`,
   and a failed convergence check prints the final raw tables for diagnosis.
2. Each of the twelve remote loopback /32 routes learned through OSPF 10.
   A static or less-specific route does not satisfy this check.
3. R1's route to 10.255.0.4 has the sole next hop 10.0.12.2 through
   FastEthernet0/0; R4's route to 10.255.0.1 has the sole next hop
   10.0.24.1 through FastEthernet0/0. These are control-plane checks of
   selected primary next hops, not traceroute or packet-capture evidence.
4. Twelve loopback-source ping tests return 3/3 replies, after separate
   single-packet warm-ups.
5. All four routers acknowledge `write memory` with `[OK]`.

The workflow records `ospf-plan.json`, `before-ospf.json`,
`pending-commands.json`, `neighbors.json`, `routes.json`,
`loopback-pings.json` and `console-transcript.json`, retained for seven
days. Backups cover only the inspected configuration sections. A failed
apply can leave some running configuration changed; there is no automated
rollback. Saving happens after verification, but a failure during saving
can leave only some routers saved. Inspect artifacts before resuming.

The workflow is tested with simulated IOS state and actual local
HTTP/Telnet connections. The successful downloaded live artifact now includes
all four OSPF saves. Separate failover artifacts now establish backup
routing through R3, primary recovery and six traceroutes. A separate
live run measured sampled packet loss across both transitions. Exact OSPF
convergence timing and packet captures remain open.
No ordinary OSPF deployment cuts links.

For the dependency-free OSPF tests on Windows PowerShell:

```powershell
.\tests\Test-CoreOspf.ps1
```

## Next milestones

1. Preserve successful repeat-apply evidence for configuration idempotence.
2. Test the tertiary direct backup separately.
3. Obtain a suitable managed switch image and implement the VLAN/access network.
4. Compare OSPF and EIGRP in separate routing campaigns.
5. Add routing experiments, QoS measurements, Suricata, Wazuh and Zabbix.
6. Add AWS and end-to-end VPN validation.

Keep disruptive experiments separate from ordinary checks. Do not expose
the GNS3 API or device consoles to the public Internet. Future remote
administration needs a private management connection; it must not bypass
the routed paths used for network measurements.

## References

- [GNS3 API endpoints](https://api.gns3.net/en/latest/endpoints.html)
- [GNS3 project creation](https://api.gns3.net/en/stable/api/v2/controller/project/projects.html)
- [GNS3 node creation](https://api.gns3.net/en/stable/api/v2/controller/node/projectsprojectidnodes.html)
- [GNS3 link creation](https://api.gns3.net/en/2.2/api/v2/controller/link/projectsprojectidlinks.html)
- [Cisco IPv4 interface configuration](https://www.cisco.com/c/en/us/td/docs/routers/ios-xe/ip-addressing/ip-addressing/m_config-ipv4-addr-0.html)
- [Cisco configuration save commands](https://www.cisco.com/c/en/us/td/docs/ios/fundamentals/command/Cisco_IOS_Configuration_Fundamentals_Command_Reference/C_commands.html)
- [Cisco OSPF neighbor command reference](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/iproute_ospf/command/iro-cr-book/ospf-s1.html)
- [Cisco ping command reference](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/fundamentals/command/Cisco_IOS_Configuration_Fundamentals_Command_Reference/monitor_event-trace_through_Q.html)
- [Manually running GitHub workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)


## Controlled OSPF failover

After pushing these files, run **GNS3 core failover** on `main`, first in
`plan`, then in `apply`. Keep all four routers and the runner running and
close manual consoles. Plan validates the topology without opening consoles.

Apply verifies primary next hops and loopback pings in both directions,
then temporarily shuts **R1 FastEthernet0/0** (R1-R2). It requires R1 to use
`10.0.13.2` and R4 to use `10.0.34.1`, both via FastEthernet1/0, with 3/3
loopback pings in both directions. It restores the interface in cleanup,
checks up/up, then verifies the primary next hops and pings again.

No `write memory` is issued. Restoration is attempted after failures,
including a lost shutdown acknowledgement, with a reconnect retry. Forced
cancellation, process termination or a disconnected console can prevent
restoration. If the result reports restoration failure, or the runner stops
during the experiment, restore R1 manually. Start at `R1#`; if the prompt
contains `(config...)`, run `end` first. Do not run `end` at `R1#`.

```text
configure terminal
interface FastEthernet0/0
no shutdown
end
```

Download the `core-failover` artifact. `result.json` records success and
restoration status; `observations.json` records route polling; the console
transcript retains route and ping outputs. Poll elapsed times describe route
observation latency, not precise convergence time or packet loss. The direct
R1-R4 tertiary backup remains outside this experiment.

Local verification: `./tests/Test-CoreFailover.ps1`. These mock tests cover
preflight refusal, primary/backup/recovery paths, ping failure, lost shutdown
acknowledgements and restoration failure. The successful corrected live run
is archived with its original ZIP, raw outputs, commit and timestamps.

The first reported live failover run passed baseline and backup path checks,
then failed restoration because `end` was sent at EXEC. Restoration now sends
`end` only from configuration mode, including on reconnect. The mode-aware
tests reproduce the original failure and pass with the fix. The user
subsequently confirms workflow success, including primary recovery.
Successful run artifacts and metadata are now archived under
`docs/evidence/2026-11-17/failover-success/`.


### Optional traceroute capture

The next checkpoint adds path observations to the proven failover test.
Run **GNS3 core failover** on updated `main`, mode `apply`, with
**capture_traceroute** checked. It captures both directions during baseline,
backup and recovery, producing six records in `traceroutes.json`.
The switch defaults to off, preserving the already validated test behavior.

Each command uses numeric output, one probe per TTL, a one-second probe
timeout and TTLs 1 through 4, with the local loopback as source:

```text
traceroute 10.255.0.4 numeric probe 1 source 10.255.0.1 timeout 1 ttl 1 4
```

[IOS command syntax reference](https://www.cisco.com/c/dam/en/us/td/docs/ios/lisp/command/reference/LISP_command_reference_1514xb5-only.pdf).
These diagnostic traces are retained for inspection; asterisk probe timeouts
are not automatically classified as failed routing. Route and ping acceptance
checks still determine path-test success. An IOS command rejection fails the
run and triggers the same restoration cleanup. This option has local mock
coverage for six captures and backup-phase command failure. Live compatibility
is now verified from run 44156385861: six two-hop traces show primary, backup
and recovered paths in both directions. See the
[successful traceroute archive](docs/evidence/2026-11-17/failover-traceroute-success/README.md).
It does not measure transition loss.

### Measure packet loss during failover

Run **GNS3 core failover** in `apply` mode with **measure_loss** checked.
Close the GNS3 console windows for R1 and R4 and stop any separate scripts
using those consoles before the run. Both workflow options can be enabled
together. Leave traceroute capture unchecked to collect only the loss experiment.
The sampler sends single loopback-sourced pings from R4 to R1 at roughly
one-second intervals. Each window starts with three consecutive replies,
continues across the R1 link command, and runs for at least another 25 seconds
after the command sequence completes. The workflow then checks routes and
bidirectional connectivity as usual.

The artifact contains `probes-backup.jsonl` and `probes-recovery.jsonl` with
each sample's command start, response read time, reply status and raw IOS
output. In `result.json`, `backup_probes` and `recovery_probes` count
replies and timeouts for probes whose commands started at or after the
transition command. Probes in flight at command start are counted separately
and retained in the raw log. Recovery uses the first `no shutdown` command
timestamp and retains any retry timestamps.

If IOS console output is malformed or the prompt times out, the sampler
records a `console_error` with a null reply and aborts the window. Check
`shutdown_attempted` and `restored` in `result.json`. If shutdown was
attempted and restoration is false, verify R1 FastEthernet0/0 and follow
the manual restore steps above if the interface is administratively down.

`first_reply_in_final_streak_seconds` estimates when sustained reachability
returned, using the first response in a final streak of at least three
replies. A null value means the sample never established that streak.
If there were no sampled timeouts, report zero observed timeouts for the
sampled direction. An interruption between probes can escape detection.
The interval includes IOS command and console delays, and subsequent route
polls verify the selected path after the measurement window.

The [live measurement archive](docs/evidence/2026-11-17/failover-loss-success/README.md)
records five consecutive timeouts in 24 post-shutdown probes and zero
timeouts in 25 post-restoration probes. The first sustained reply was read
7.104 seconds after the shutdown command started.

### Verify the direct R1–R4 backup

Run **GNS3 core failover** on the updated branch in `apply` mode with
**test_direct_backup** checked. Keep both console windows closed. The script
checks the direct link at both endpoints before changing either transit link.

| Checkpoint | R1 interface change | Expected path |
| --- | --- | --- |
| Baseline | None | R1–R2–R4 |
| Backup | Shut FastEthernet0/0 toward R2 | R1–R3–R4 |
| Direct | Also shut FastEthernet1/0 toward R3 | R1–R4 via FastEthernet2/0 |
| Secondary recovery | Restore FastEthernet1/0 | R1–R3–R4 |
| Primary recovery | Restore FastEthernet0/0 | R1–R2–R4 |

Each checkpoint requires the unique OSPF next hop and 3/3 loopback pings
in both directions. The direct-phase next hops must be `10.0.14.2` on R1
and `10.0.14.1` on R4. The direct interface stays up throughout the test.
**capture_traceroute** adds ten traces across the five checkpoints.
**measure_loss** samples the primary shutdown and restoration only.

Download the workflow artifact and check `result.json` for `passed`,
`restored`, and each link’s restoration status under `links`.
`observations.json` and `console-transcript.json` contain the route and
console evidence. The workflow attempts to restore each shutdown interface
even if restoring the other one fails. If the runner is stopped or cleanup
fails, check `show ip interface brief` on R1. Use the manual restore procedure
above for each affected interface, substituting `FastEthernet1/0` where needed.
The workflow makes no startup configuration save.
