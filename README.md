# HIDS-NIDS-hybrid-Infrastructure

A GNS3 networking and security lab developed in stages: LAN and routing,
resilience, QoS, HIDS/NIDS, and an eventual AWS VPN connection. GitHub Actions
will provide controlled automation and evidence of lab state.

## Current stage

The two-PC foundation has passed manual bidirectional ping tests and the
GitHub Actions foundation check (reported by the user). A single c7200 has
also booted successfully with IOS 15.3(3)XB12 and six FastEthernet ports.
Its automated router check is prepared locally but has not yet run on the
real runner. The four-router
network, security stack, AWS connection, deployment automation, and rollback
are planned work, not implemented features.

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

The supplied router metadata has an empty Idle-PC value. The workflow
warns about this; check CPU usage at idle before adding multiple routers.
No managed switch image is installed yet, so VLAN, RSTP and LACP experiments
still require a suitable switching device.

## Next milestones

1. Run the router hardware check successfully on the friend's runner.
2. Verify router idle CPU usage and obtain a suitable managed switch image.
3. Build and validate the four-router LAN and its addressing.
4. Add controlled configuration automation and connectivity verification.
5. Add routing experiments, QoS measurements, Suricata, Wazuh and Zabbix.
6. Add AWS and end-to-end VPN validation.

Keep disruptive experiments separate from ordinary checks. Do not expose
the GNS3 API or device consoles to the public Internet. Future remote
administration needs a private management connection; it must not bypass
the routed paths used for network measurements.

## References

- [GNS3 API endpoints](https://api.gns3.net/en/latest/endpoints.html)
- [Manually running GitHub workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
