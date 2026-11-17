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

Cable trunk B and bring Gi0/1 up on both ends. Use
`show spanning-tree summary` and `show spanning-tree vlan 10`. On SW-A2,
one uplink should be a forwarding root port and the other a blocked
alternate. Verify the VLAN 10 ping, then shut the currently forwarding
uplink on SW-A2. Confirm the alternate forwards and the ping works again.
Restore the uplink and confirm the original redundant topology returns.
Keep both spanning-tree outputs and the ping results.

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
