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
consoles reached a prompt. IP configuration, routing, the security stack,
AWS and rollback verification are still pending. Interface automation is
prepared locally and requires its first live run.

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
2. Finish the initial IOS setup prompts manually. Consoles must be at an
   EXEC prompt (`Router>`, `R1#`, etc.). Password-protected consoles and
   unfinished initial setup are rejected. No passwords are guessed or sent.
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

Artifacts are retained for seven days and include the address plan,
pre-change hostname/interface backups, pending commands, console transcript,
and ping results. Backups cover the managed hostname and interfaces, not
the entire router configuration. The first live apply is still pending;
simulated tests do not establish that real network connectivity works.

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
apply, repeat apply, and generated ping evidence. It never contacts the
real lab. The GitHub workflow does not require Python or run this test.

## Next milestones

1. Complete a successful repeated core deployment with stable startup checks.
2. Run the interface workflow in plan mode, then apply, then repeat apply.
3. Add and verify OSPF routing with explicit path costs.
4. Obtain a suitable managed switch image and implement the VLAN/access network.
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
- [Manually running GitHub workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
