# Managed switching pilot

The pilot uses SW-A1 and SW-A2 to verify VLAN separation, an 802.1Q trunk,
rapid spanning tree and LACP. Run it in a new GNS3 project named
`Switching-Pilot`. Once it passes, build the third switch on the server
side and integrate the client VLANs with R1 and server VLANs with R4.

Run **GNS3 switch readiness** with the GNS3 VM online. The workflow reads
the controller's compute and template inventories and uploads
`readiness.json`. A candidate is a QEMU IOSvL2 template registered on the
GNS3 VM with at least four adapters, a referenced disk, and a Telnet console.
Use an image approved for your GNS3 deployment. Import and configure it
if the inventory is empty. Then boot two instances and check
`show version` and `show interfaces status` to confirm the image and map
the GNS3 connectors to IOS interface names. The inventory does not check
whether the disk boots or which commands the installed image accepts.
[GNS3 appliance import](https://docs.gns3.com/docs/using-gns3/beginners/install-from-marketplace).

### Provision the isolated topology

If you have already created `Switching-Pilot` manually, keep that project
and proceed to the boot checks below. Otherwise run **GNS3 switching pilot**
in **plan** mode. It checks readiness again and previews five nodes and
four links in the separate pilot project. When only one candidate passes,
the workflow picks it. If several pass, enter the chosen eligible UUID
from `readiness.json` in **switch_template_id**.

Run **apply** to create the project, two switches and three VPCS, with
trunk A and the three access links. Leave trunk B uncabled until the
two-trunk RSTP test. The workflow validates existing pilot nodes and
links before adding missing objects. It keeps the routed core separate.
Review `plan.json` and `nodes.json`, then open `Switching-Pilot` in
GNS3 and start the five devices. Check `show version` and
`show interfaces status` on both switches before applying configuration.

If either console reports Open vSwitch or presents a Linux shell, stop
before configuring the trunks or running the Cisco RSTP test. In the
`Switching-Pilot` project, open the consoles directly from **SW-A1** and
**SW-A2** and check each guest separately. A Cisco guest should identify
itself in the output of `show version`. On a Linux guest,
`ovs-vsctl --version` identifies the installed Open vSwitch utility.
If the Linux console belongs to a pilot switch, inspect that node's QEMU
boot disk in GNS3. The template label and cabling evidence establish the
controller configuration only. To use the two Open vSwitch appliances,
follow the separate [Open vSwitch VLAN procedure](#open-vswitch-vlan-pilot).

### Resolve a failed readiness check

From the failed job, download the **switch-readiness** artifact and open
`readiness.json`. If `iosvl2_candidates` is empty, check GNS3 on the
runner PC. Use **File → Import appliance** to import the Cisco IOSvL2
`.gns3a` descriptor. Select the GNS3 VM and supply the matching boot image
that you are permitted to use in GNS3. Finish the import so the template
appears in the device list. The appliance descriptor provides settings.
The boot image is a separate file. [GNS3 import steps](https://docs.gns3.com/docs/using-gns3/beginners/import-gns3-appliance).

If `iosvl2_candidates` lists a template, check its `issues` field or
the job output for the settings to correct. The older readiness artifact
lists the same settings separately under `compute_id`, `adapters`,
`disk_referenced`, and `telnet_console`. Rerun readiness after making
the change.

Cisco's CML-supplied images require separate authorization for use outside
CML. Confirm permission before using an image in GNS3.
[Cisco image terms](https://developer.cisco.com/docs/modeling-labs/vm-images-for-cml-labs/).

| Node and port | Peer | Assignment |
| --- | --- | --- |
| SW-A1 Gi0/0 | SW-A2 Gi0/0 | Trunk A |
| SW-A1 Gi0/1 | SW-A2 Gi0/1 | Trunk B, initially uncabled |
| SW-A1 Gi0/2 | Client-A | VLAN 10, 192.168.10.11/24 |
| SW-A2 Gi0/2 | Client-B | VLAN 10, 192.168.10.12/24 |
| SW-A2 Gi0/3 | Test-C | VLAN 30, 192.168.30.13/24 |

Use the actual IOS port names if the boot test shows a different mapping.
Leave gateways blank for these Layer 2 tests. Use VLAN 99 for future
management and leave its SVI and access ports unconfigured in the pilot.
VLAN 999 is the unused native VLAN. Keep unused physical ports shut.

## Verify VLANs on one trunk

Start with the three host links and trunk A physically connected. On both
switches, run the following from privileged EXEC.

```text
configure terminal
spanning-tree mode rapid-pvst
vlan 10
 name CLIENTS
vlan 30
 name TEST
vlan 99
 name MANAGEMENT
vlan 999
 name UNUSED_NATIVE
exit
interface range GigabitEthernet0/0 - 1
 shutdown
 switchport
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 999
 switchport trunk allowed vlan 10,30,99
exit
interface GigabitEthernet0/0
 no shutdown
exit
interface GigabitEthernet0/2
 switchport
 switchport mode access
 switchport access vlan 10
 spanning-tree portfast
 spanning-tree bpduguard enable
 no shutdown
end
```

On SW-A1 set `spanning-tree vlan 10,30,99 priority 4096` in global
configuration mode. This makes the intended root deterministic in the pilot.
On SW-A2 configure Gi0/3 as an access port in VLAN 30 with PortFast, BPDU
guard and `no shutdown`. Use `show vlan brief` and
`show interfaces trunk` to check the assignments and allowed VLAN list.

Set both clients' listed addresses with the VPCS `ip` command, for example
`ip 192.168.10.11/24`. The clients must ping each other in both directions.
For a controlled isolation check set Test-C temporarily to
`192.168.10.13/24`. First associate its switch port with VLAN 10 and
confirm Client-A reaches it. Move Gi0/3 to VLAN 30, clear the VPCS ARP cache
with `clear arp` before retesting, and verify the same ping fails while
Client-A still reaches Client-B. Restore Test-C's planned
`192.168.30.13/24` address after the check.

## Verify rapid spanning tree with two trunks

For an IOSvL2 pilot, cable SW-A1 Gi0/1 to SW-A2 Gi0/1 after Rapid PVST
and both standalone trunks are configured. Check `show spanning-tree vlan 10`
and identify the forwarding and alternate ports on SW-A2. Confirm the client
pings, shut the forwarding port on SW-A2, and verify the alternate forwards
and the pings recover. Use `no shutdown` to restore the original port and
check both spanning-tree roles and pings again.
[Cisco spanning-tree output reference](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/lanswitch/configuration/xe-3s/asr903/lanswitch-xe-3s-asr903-book/lanswitch-xe-3s-asr903-book_chapter_0110.pdf).

## Verify LACP and member recovery

Shut both inter-switch interfaces on both ends before changing them from
independent trunks to members of Port-channel1. Keep them shut until both
ends are configured. On each switch, run the following from privileged EXEC.

```text
configure terminal
interface range GigabitEthernet0/0 - 1
 shutdown
 channel-group 1 mode active
exit
interface Port-channel1
 switchport
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 999
 switchport trunk allowed vlan 10,30,99
 no shutdown
end
```

Bring Gi0/0 and Gi0/1 up on both ends. Use `show etherchannel summary` and
`show lacp neighbor` on both switches. Port-channel1 should be an active
Layer 2 bundle with both member ports bundled. Check
`show interfaces trunk` and `show spanning-tree vlan 10` for the logical
trunk, and confirm the VLAN 10 ping. Shut one member on SW-A2 and verify
the bundle stays up with one bundled member and the ping still works.
Restore the member and confirm both ports bundle again.
[Cisco LACP verification](https://www.cisco.com/c/en/us/td/docs/switches/lan/c9000/lyr2-fwd/etherchannel/etherchannel-configuration-guide/etherchannels.html).

Retain the switch versions, port map, VLAN and trunk states, spanning-tree
roles, LACP state and ping outputs. These checks cover the isolated
Layer 2 pilot. Router subinterfaces, cross-core VLAN traffic and
management access policy follow in the integration phase.

## Open vSwitch VLAN pilot

The console outputs for `OpenvSwitch-1` and `OpenvSwitch-2` show Open
vSwitch 2.17.12 with `eth0` through `eth15` on `br0`. Use the OVS nodes
in a separate, isolated GNS3 project. The Cisco pilot and its workflows
expect the QEMU IOSvL2 nodes and Cisco commands.
[GNS3 Open vSwitch appliance](https://github.com/GNS3/gns3-registry/blob/master/appliances/openvswitch.gns3a).

Before configuring anything, verify these four cables on the canvas.
Keep all other switch ports uncabled, especially the second inter-switch
link. Name the project `Switching-Pilot-OVS`, or enter its exact name in
the RSTP workflow. Place both OVS appliances and all three VPCS on the
GNS3 VM. Use the node names listed below.

| Port | Peer |
| --- | --- |
| OpenvSwitch-1 eth0 | OpenvSwitch-2 eth0 |
| OpenvSwitch-1 eth2 | Client-A Ethernet0 |
| OpenvSwitch-2 eth2 | Client-B Ethernet0 |
| OpenvSwitch-2 eth3 | Test-C Ethernet0 |

Run these commands on **both** OVS consoles. Port eth0 carries only tagged
VLANs 10, 30 and 99. Port eth2 is an untagged access port in VLAN 10.

```sh
ovs-vsctl -- clear Port eth0 tag -- set Port eth0 vlan_mode=trunk trunks=10,30,99
ovs-vsctl -- clear Port eth2 trunks -- set Port eth2 vlan_mode=access tag=10
```

On **OpenvSwitch-2 only**, initially put Test-C in VLAN 10 for a positive
control.

```sh
ovs-vsctl -- clear Port eth3 trunks -- set Port eth3 vlan_mode=access tag=10
```

On the VPCS consoles, set Client-A to `ip 192.168.10.11/24`, Client-B
to `ip 192.168.10.12/24`, and Test-C to `ip 192.168.10.13/24`.
Leave all gateways blank. Ping between Client-A and Client-B in both
directions. From Client-A, also ping Test-C. All should succeed before
changing Test-C's VLAN.

On **OpenvSwitch-2**, move the Test-C access port to VLAN 30.

```sh
ovs-vsctl set Port eth3 tag=30
```

Leave the VPCS IPs unchanged for the comparison. Run `clear arp` on
Client-A and Test-C, then ping Test-C again from Client-A. It should fail.
Client-A and Client-B should still reach each other. Then give Test-C its
planned address with `ip 192.168.30.13/24`.

Save the ping outputs and the output of the following command on each
switch. This verifies the intended port settings alongside the packet
tests. Test with a second uplink only after setting up and verifying OVS
RSTP; parallel links before loop protection can create a Layer 2 loop.

```sh
ovs-vsctl --columns=name,vlan_mode,tag,trunks list Port
```

[Open vSwitch VLAN configuration](https://docs.openvswitch.org/en/stable/faq/configuration/) ·
[OVS port VLAN fields](https://www.openvswitch.org/support/dist-docs/ovs-vswitchd.conf.db.5.html).

### Run the OVS RSTP workflow

Once the VLAN test passes, open the isolated project in GNS3 on the runner
side. Start the switches and clients and close their manual consoles.
Run **GNS3 Open vSwitch RSTP** with the following modes in sequence.

1. **plan** checks the five nodes and the cable map using the GNS3 API.
2. **prepare** requires `eth1` to be uncabled. It verifies the VLAN port
   settings and bidirectional client pings, prepares `eth1` as a tagged
   trunk, and enables bridge RSTP. It assigns OpenvSwitch-1 the lower
   bridge priority and verifies VLAN 10 connectivity on the single trunk.
   Connect `eth1` to `eth1` only after prepare passes.
3. **apply** verifies a forwarding root port and a discarding alternate
   on OpenvSwitch-2. It shuts the forwarding port briefly, checks that the
   alternate takes over and that both clients get 3/3 replies, then
   restores the port and checks redundancy and connectivity again.

Download the `ovs-rstp` artifact for `result.json` and
`console-transcript.json`. If the runner is stopped during apply or a
restore fails, inspect the port named by `interrupted_port` on OpenvSwitch-2
and bring it up with `ip link set eth0 up` or `ip link set eth1 up`,
depending on which port was taken down. OVS RSTP runs per bridge. The pings
in this workflow verify that VLAN 10 traffic follows the resulting tree.
[OVS RSTP fields](https://www.openvswitch.org/support/dist-docs/ovs-vswitchd.conf.db.5.html).
