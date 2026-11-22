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
If the project has a different name, copy its exact name from GNS3 into
the workflow's **project_name** field. The workflow expects a project
containing both OVS appliances, Client-A, Client-B and Test-C.
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

### Run the OVS LACP workflow

After RSTP apply passes, keep both inter-switch cables connected and close
the manual consoles. Run **GNS3 Open vSwitch LACP** with the same project
name. Use **plan** to check the cabling. **Apply** takes both trunks down
during conversion and leaves an active LACP trunk named `bond0` on each
bridge, carrying tagged VLANs 10, 30 and 99. Apply migrates existing
pilot balance-tcp bonds in place. Active-backup forwarding prefers eth0
on both switches and uses eth1 when eth0 fails. This tests redundancy
with one transmitting member per switch. Apply disables bridge RSTP
only after both bonds pass configuration checks. On a ping failure, the
console transcript includes VLAN settings, interface state, learned MAC
addresses and port counters from both switches.

The workflow checks both switches and probes VLAN 10 in both directions
at five checkpoints: baseline, eth0 down, eth0 restored, eth1 down and
eth1 restored. Download the `ovs-lacp` artifact for the completed
checkpoints in `result.json` and raw console output. If conversion stops
partway, rerun apply with the same project. It recognizes completed bonds
and brings up both links after verifying both ends.

### Connect VLAN 10 to the OSPF core

The first routed checkpoint uses one access switch and one client. In GNS3,
duplicate the saved four-router `Hybrid-Core-Lab` project as
`Hybrid-Core-Integration`. Open the copy and start the four routers.
The existing core workflows validate the original project ID and its exact
five-link topology. Use the integration copy for the additional equipment.

1. Confirm R1 and R4 can reach each other's loopbacks and have three FULL
   OSPF neighbors each. On R1, check `show ip interface brief` and
   `show running-config interface FastEthernet3/0`. Verify Fa3/0 is
   uncabled, unaddressed and has no existing subinterfaces in the copy.
2. Add a fresh OVS appliance named `SW-CLIENT` and a VPCS named `Client-A`
   on the GNS3 VM. Cable R1 Fa3/0 to SW-CLIENT eth4 and Client-A Ethernet0
   to SW-CLIENT eth2. Start both nodes. On the OVS console confirm
   `ovs-vsctl port-to-br eth4` and `ovs-vsctl port-to-br eth2` both return
   `br0`. Configure the client and router-facing ports.

   ```sh
   ovs-vsctl -- clear Port eth2 trunks -- set Port eth2 vlan_mode=access tag=10
   ovs-vsctl -- clear Port eth4 tag -- set Port eth4 vlan_mode=trunk trunks=10
   ```

3. On the integration copy of R1, configure the gateway and advertise it
   in the existing OSPF process. The passive subinterface advertises the
   network without seeking neighbors on the client LAN.

   ```text
   configure terminal
   interface FastEthernet3/0
    no shutdown
   exit
   interface FastEthernet3/0.10
    encapsulation dot1Q 10
    ip address 192.168.10.1 255.255.255.0
   exit
   router ospf 10
    passive-interface FastEthernet3/0.10
    network 192.168.10.0 0.0.0.255 area 0
   end
   ```

4. On Client-A set `ip 192.168.10.11/24 192.168.10.1`. Warm up ARP
   with a gateway ping, then collect the following evidence.

   | Where | Command | Pass condition |
   | --- | --- | --- |
   | R1 | `show ip interface brief` | Fa3/0.10 is up/up with 192.168.10.1 |
   | Client-A | `ping 192.168.10.1 -c 3` | 3/3 replies from its gateway |
   | R4 | `show ip route 192.168.10.0` | OSPF route for 192.168.10.0/24 via R2 (10.0.24.1) with the primary path healthy |
   | Client-A | `ping 10.255.0.4 -c 3` | 3/3 replies from R4 |
   | R4 | `ping 192.168.10.11 source Loopback0 repeat 3` | 3/3 replies from Client-A |
   | R1 and R4 | `show ip ospf neighbor` | Three FULL core neighbors on each |

5. After the checks pass, save R1 with `copy running-config startup-config`
   and save Client-A with `save`. Retain the console outputs. The following
   stage adds the server switch and VLAN 20 gateway on R4.

### Run the R4 server VLAN workflow

After the R1 VLAN 10 checkpoint passes, add an Open vSwitch appliance named
`SW-SERVER` and a VPCS named `Server-A` on the GNS3 VM in the integration
copy. Cable R4 FastEthernet4/0 to SW-SERVER eth4 and Server-A Ethernet0 to
SW-SERVER eth2. This assigns Fa4/0 to the server LAN and leaves Fa3/0
available for the planned private link. Start all eight nodes, leave the
server ports at their defaults and close the manual consoles.

Run **GNS3 routed server VLAN** on main in **plan** mode using the integration
project name. It checks the nine cables, the candidate interfaces and the
existing Client-A to R4 loopback path. Run **apply** after plan passes.
Apply configures the tagged trunk, VLAN 20 access port, R4 gateway
192.168.20.1/24, passive OSPF interface and Server-A 192.168.20.11/24.
It verifies the local gateway, R1's OSPF route via R2 and 3/3 client/server
pings in each direction before saving R4 and Server-A. Download the
`server-vlan` artifact for the result and console transcript.
