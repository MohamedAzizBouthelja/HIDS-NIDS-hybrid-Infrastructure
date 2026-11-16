"""Interface/OSPF integration: real HTTP JSON and Telnet, simulated IOS.

Uses Python's standard library and Windows PowerShell. Does not contact GNS3.
The GitHub workflow uses the dependency-free PowerShell tests instead.
"""
import json
import heapq
import socketserver
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "gns3/core-topology.json").read_text())
OSPF = json.loads((ROOT / "gns3/ospf.json").read_text())
PROJECT_ID = MANIFEST["project"]["project_id"]
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
COUNTERS = dict(opens=0, changes=0, saves=0, measured_pings=0, wake_returns=0)
ROUTERS = {}


def all_ospf_configured():
    for name, router in ROUTERS.items():
        loop = router["interfaces"].get("Loopback0", {})
        if (router["router_id"] != OSPF["router_ids"][name] or not router["passive"]
                or loop.get("address") != router["router_id"] or not loop.get("ospf")):
            return False
    for link in MANIFEST["links"]:
        for side in ("a", "b"):
            router = ROUTERS[link[side]]
            name = f'FastEthernet{link[f"{side}_adapter"]}/0'
            interface = router["interfaces"][name]
            if (not interface.get("ospf") or interface.get("cost") != OSPF["link_costs"][link["subnet"]]
                    or interface.get("network") != "point-to-point" or name not in router["active"]):
                return False
    return True


def route_next_hop(source, destination):
    graph = {name: [] for name in ROUTERS}
    for link in MANIFEST["links"]:
        cost = OSPF["link_costs"][link["subnet"]]
        graph[link["a"]].append((link["b"], cost, link["b_ip"], f'FastEthernet{link["a_adapter"]}/0'))
        graph[link["b"]].append((link["a"], cost, link["a_ip"], f'FastEthernet{link["b_adapter"]}/0'))
    queue, visited = [(0, source, "", "")], set()
    while queue:
        cost, name, first_hop, first_interface = heapq.heappop(queue)
        if name in visited:
            continue
        visited.add(name)
        if name == destination:
            return first_hop, first_interface, cost + 1
        for peer, weight, next_hop, interface in graph[name]:
            heapq.heappush(queue, (cost + weight, peer, first_hop or next_hop, first_interface or interface))
    raise AssertionError("Simulated topology is disconnected")


class ConsoleHandler(socketserver.BaseRequestHandler):
    def handle(self):
        COUNTERS["opens"] += 1
        router = self.server.router
        self.request.settimeout(15)
        self.request.sendall(bytes([255, 251, 1, 255, 253, 3]))
        # Replay old setup text before the current prompt, in separate reads.
        # The console reader must wait for the current terminal tail.
        self.request.sendall(b'Would you like to enter the initial configuration dialog? [yes/no]:')
        time.sleep(0.05)
        self.request.sendall(b' no\r\nPress RETURN to get started!\r\nPassword:\r\nRouter#\r\n')
        line, telnet_state, mode, selected = bytearray(), "data", "", None
        waiting_for_return = True
        while True:
            chunk = self.request.recv(8192)
            if not chunk:
                return
            for byte in chunk:
                if telnet_state == "iac":
                    telnet_state = "option" if byte in (251, 252, 253, 254) else "data"
                    continue
                if telnet_state == "option":
                    telnet_state = "data"
                    continue
                if byte == 255:
                    telnet_state = "iac"
                    continue
                if byte in (0, 10):
                    continue
                if byte != 13:
                    line.append(byte)
                    continue
                command = line.decode("ascii")
                line.clear()
                if not command:
                    if waiting_for_return:
                        # An early connection CR can arrive before IOS is ready.
                        self.request.sendall(b'\r\nPress RETURN to get started.')
                        waiting_for_return = False
                        continue
                    COUNTERS["wake_returns"] += 1
                    self.request.sendall(("\r\n" + router["hostname"] + "#").encode())
                    continue
                body = ""
                if command == "terminal length 0":
                    pass
                elif command == "show running-config | include ^hostname":
                    body = "hostname " + router["hostname"] + "\r\n"
                elif command == "show running-config | section ^router":
                    if router["process"]:
                        body = f'router ospf 10\r\n router-id {router["router_id"]}\r\n log-adjacency-changes\r\n'
                        if router["passive"]:
                            body += ' passive-interface default\r\n'
                        for interface in sorted(router["active"]):
                            body += f' no passive-interface {interface}\r\n'
                elif command.startswith("show running-config interface "):
                    name = command.split()[-1]
                    config = router["interfaces"][name]
                    body = "Building configuration...\r\nCurrent configuration : 90 bytes\r\n!\r\ninterface " + name + "\r\n"
                    body += (" ip address " + config["address"] + " " + config["mask"] if config["address"] else " no ip address") + "\r\n"
                    if config["shutdown"]:
                        body += " shutdown\r\n"
                    if config.get("ospf"):
                        body += ' ip ospf 10 area 0\r\n'
                    if config.get("network"):
                        body += f' ip ospf network {config["network"]}\r\n'
                    if config.get("cost"):
                        body += f' ip ospf cost {config["cost"]}\r\n'
                    body += " duplex auto\r\n speed auto\r\nend\r\n"
                elif command == "configure terminal":
                    mode = "(config)"
                elif command.startswith("hostname "):
                    router["hostname"] = command.split()[1]
                    COUNTERS["changes"] += 1
                elif command.startswith("interface "):
                    selected, mode = command.split()[1], "(config-if)"
                    if selected not in router["interfaces"]:
                        router["interfaces"][selected] = dict(address="", mask="", shutdown=True)
                        COUNTERS["changes"] += 1
                elif command.startswith("ip address "):
                    _, _, address, mask = command.split()
                    router["interfaces"][selected].update(address=address, mask=mask)
                    COUNTERS["changes"] += 1
                elif command == "no shutdown":
                    router["interfaces"][selected]["shutdown"] = False
                    COUNTERS["changes"] += 1
                elif command == 'ip ospf 10 area 0':
                    router['interfaces'][selected]['ospf'] = True
                    router['process'] = True
                    COUNTERS['changes'] += 1
                elif command == 'ip ospf network point-to-point':
                    router['interfaces'][selected]['network'] = 'point-to-point'
                    COUNTERS['changes'] += 1
                elif command.startswith('ip ospf cost '):
                    router['interfaces'][selected]['cost'] = int(command.split()[-1])
                    COUNTERS['changes'] += 1
                elif command == 'router ospf 10':
                    router['process'], mode, selected = True, '(config-router)', None
                elif command.startswith('router-id '):
                    router['router_id'] = command.split()[-1]
                    COUNTERS['changes'] += 1
                elif command == 'passive-interface default':
                    router['passive'] = True
                    COUNTERS['changes'] += 1
                elif command.startswith('no passive-interface '):
                    router['active'].add(command.split()[-1])
                    COUNTERS['changes'] += 1
                elif command == "exit":
                    mode = "(config)"
                elif command == "end":
                    mode = ""
                elif command == "show ip interface brief":
                    body = "Interface                  IP-Address      OK? Method Status                Protocol\r\n"
                    for name, config in router["interfaces"].items():
                        address = config["address"] or "unassigned"
                        status, protocol = ("administratively down", "down") if config["shutdown"] else ("up", "up")
                        body += f"{name:<26} {address:<15} YES manual {status:<21} {protocol}\r\n"
                elif command == 'show ip ospf neighbor':
                    body = 'Neighbor ID Pri State Dead Time Address Interface\r\n'
                    for link in MANIFEST['links']:
                        for side, other in (('a', 'b'), ('b', 'a')):
                            if link[side] == self.server.name:
                                state = 'FULL/-' if all_ospf_configured() else 'INIT/-'
                                body += f'{OSPF["router_ids"][link[other]]} 0 {state} 00:00:37 {link[f"{other}_ip"]} FastEthernet{link[f"{side}_adapter"]}/0\r\n'
                elif command.startswith('show ip route '):
                    COUNTERS['route_reads'] = COUNTERS.get('route_reads', 0) + 1
                    destination = command.split()[-1]
                    remote = next(name for name, address in OSPF['router_ids'].items() if address == destination)
                    hop, interface, metric = route_next_hop(self.server.name, remote)
                    if COUNTERS['route_reads'] == 1:
                        body = '% Network not in table\r\n'
                    else:
                        body = f'Routing entry for {destination}/32\r\n Known via "ospf 10", distance 110, metric {metric}, type intra area\r\n * {hop}, from {destination}, 00:00:03 ago, via {interface}\r\n Route metric is {metric}\r\n'
                elif command.startswith("ping "):
                    if "repeat 3" in command:
                        COUNTERS["measured_pings"] += 1
                        body = "!!!\r\nSuccess rate is 100 percent (3/3), round-trip min/avg/max = 1/1/1 ms\r\n"
                    else:
                        body = "Success rate is 0 percent (0/1)\r\n"
                elif command == "write memory":
                    COUNTERS["saves"] += 1
                    body = "Building configuration...\r\n[OK]\r\n"
                else:
                    body = "% Invalid input detected at '^' marker.\r\n"
                echo = command
                if command.startswith('no passive-interface '):
                    # Real IOS syslog can interrupt an echoed command without
                    # inserting a newline between the log and its remaining text.
                    message = '%LINEPROTO-5-UPDOWN: Line protocol on Interface Loopback0, changed state to up'
                    if command.endswith('FastEthernet0/0'):
                        message = '%OSPF-5-ADJCHG: Process 10, Nbr 10.255.0.2 on FastEthernet0/0 from LOADING to FULL'
                    echo = command[:7] + '\r\n*Nov 16 20:46:25.275: ' + message + command[7:]
                    COUNTERS['echo_interruptions'] = COUNTERS.get('echo_interruptions', 0) + 1
                self.request.sendall((echo + "\r\n" + body + router["hostname"] + mode + "#").encode())


class ConsoleServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def main():
    servers, nodes, links = [], [], []
    by_name = {router["name"]: router for router in MANIFEST["routers"]}
    for router in MANIFEST["routers"]:
        server = ConsoleServer(("127.0.0.1", 0), ConsoleHandler)
        server.name = router['name']
        server.router = dict(hostname="Router", process=False, router_id='', passive=False, active=set(),
                             interfaces={f"FastEthernet{i}/0": dict(address="", mask="", shutdown=True) for i in range(6)})
        ROUTERS[router['name']] = server.router
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        nodes.append(dict(name=router["name"], node_id=router["node_id"], project_id=PROJECT_ID,
                          compute_id="vm", node_type="dynamips", status="started", console_type="telnet",
                          console_host="127.0.0.1", console=server.server_address[1]))
    for link in MANIFEST["links"]:
        endpoints = [dict(node_id=by_name[link[side]]["node_id"], adapter_number=link[f"{side}_adapter"], port_number=0) for side in ("a", "b")]
        links.append(dict(nodes=endpoints, link_type="ethernet", suspend=False, filters={}))

    class ApiHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            routes = {"/v2/projects": [dict(project_id=PROJECT_ID, status="opened", name="Hybrid-Core-Lab")],
                      f"/v2/projects/{PROJECT_ID}/nodes": nodes, f"/v2/projects/{PROJECT_ID}/links": links}
            if self.path not in routes:
                self.send_error(404)
                return
            payload = json.dumps(routes[self.path]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args):
            pass

    api = ThreadingHTTPServer(("127.0.0.1", 0), ApiHandler)
    servers.append(api)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    evidence_dir = ROOT / "artifacts/interface-integration"
    try:
        for mode in ("plan", "apply", "apply"):
            command = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                       str(ROOT / "scripts/Configure-CoreInterfaces.ps1"), "-Mode", mode,
                       "-ApiBaseUrl", f"http://127.0.0.1:{api.server_port}", "-EvidenceDirectory", str(evidence_dir)]
            result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=45)
            assert result.returncode == 0, (result.stdout, result.stderr)
            if mode == "plan":
                assert COUNTERS["opens"] == 0 and COUNTERS["changes"] == 0
                print("PASS: entry-point plan reads real HTTP JSON arrays and opens no consoles")
            else:
                assert COUNTERS["changes"] == 24, COUNTERS
                print("PASS: entry-point apply uses real HTTP and four TCP console connections")
        assert COUNTERS["saves"] == 8 and COUNTERS["measured_pings"] == 20, COUNTERS
        assert COUNTERS["wake_returns"] == 8, COUNTERS
        evidence = json.loads((evidence_dir / "ping-results.json").read_text(encoding="utf-8-sig"))
        assert len(evidence) == 10 and all(record["passed"] for record in evidence)
        print("PASS: repeat apply makes no configuration changes; ten measured ping records saved")
        print("PASS: each console receives RETURN after its ready message, including on reconnect")
        first_ospf_change_count = None
        for mode in ('plan', 'apply', 'apply'):
            previous_changes = COUNTERS['changes']
            command = [POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                       str(ROOT / 'scripts/Configure-CoreOspf.ps1'), '-Mode', mode,
                       '-ApiBaseUrl', f'http://127.0.0.1:{api.server_port}',
                       '-EvidenceDirectory', str(ROOT / 'artifacts/ospf-integration')]
            result = subprocess.run(command, capture_output=True, text=True, errors='replace', timeout=180)
            assert result.returncode == 0, (result.stdout, result.stderr)
            if mode == 'plan':
                assert COUNTERS['changes'] == previous_changes
                print('PASS: OSPF entry-point plan changes no configuration')
            elif first_ospf_change_count is None:
                first_ospf_change_count = COUNTERS['changes']
                assert all_ospf_configured()
                print('PASS: OSPF entry-point apply configures and verifies the simulated network over real HTTP/TCP')
            else:
                assert COUNTERS['changes'] == first_ospf_change_count
                print('PASS: OSPF repeat apply changes no configuration')
        assert COUNTERS['measured_pings'] == 44 and COUNTERS['saves'] == 16, COUNTERS
        routes = json.loads((ROOT / 'artifacts/ospf-integration/routes.json').read_text(encoding='utf-8-sig'))
        assert len(routes) == 12 and all(route['valid'] for route in routes)
        print('PASS: twelve OSPF route records saved, including unique primary paths through R2')
        assert COUNTERS.get('echo_interruptions', 0) > 0
        print('PASS: OSPF configuration handles syslog inserted into command echoes')
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


def check_interleaved_echo():
    """Reproduce an OSPF command interrupted by the exact reported syslog."""
    server = ConsoleServer(('127.0.0.1', 0), ConsoleHandler)
    server.name = 'R2'
    server.router = dict(hostname='R2', process=False, router_id='', passive=False, active=set(), interfaces={})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    transport = str(ROOT / 'scripts/IosConsole.ps1').replace("'", "''")
    code = ("$ErrorActionPreference='Stop'; . '" + transport + "'; "
            "$session=Open-IosConsole '127.0.0.1' " + str(server.server_address[1]) + "; "
            "try { $null=Send-IosCommand $session 'configure terminal'; "
            "$null=Send-IosCommand $session 'router ospf 10'; "
            "$output=Send-IosCommand $session 'no passive-interface FastEthernet1/0' -TimeoutSeconds 2; "
            "if ($session.Prompt -ne 'R2(config-router)#' -or $output -notlike '*%LINEPROTO-5-UPDOWN*') { throw 'Invalid echo test response' }; "
            "$null=Send-IosCommand $session 'end' "
            "} finally { Close-IosConsole $session }")
    try:
        result = subprocess.run([POWERSHELL, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', code],
                                capture_output=True, text=True, errors='replace', timeout=12)
        assert result.returncode == 0, (result.stdout, result.stderr)
        print('PASS: reported interleaved command echo completes over a real TCP console')
    finally:
        server.shutdown()
        server.server_close()


def check_live_challenges():
    """Auth/setup receive no answers; RETURN retries have a strict bound."""
    for challenge, expected_returns in (("Password:", 1), ("Username:", 1),
                                        ("Would you like to enter the initial configuration dialog? [yes/no]:", 1),
                                        ("Press RETURN to get started.", 3)):
        received = bytearray()

        class ChallengeHandler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(10)
                self.request.sendall(("Router#\r\n" + challenge).encode())
                while True:
                    data = self.request.recv(1024)
                    if not data:
                        return
                    received.extend(data)
                    self.request.sendall(("\r\n" + challenge).encode())

        server = ConsoleServer(("127.0.0.1", 0), ChallengeHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        transport = str(ROOT / "scripts/IosConsole.ps1").replace("'", "''")
        code = ("$ErrorActionPreference='Stop'; . '" + transport + "'; $rejected=$false; "
                "try { $null=Open-IosConsole '127.0.0.1' " + str(server.server_address[1]) + " } "
                "catch { $rejected=$_.Exception.Message -like '*currently waiting*' }; "
                "if (-not $rejected) { throw 'Expected a bounded rejection' }")
        try:
            result = subprocess.run([POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", code],
                                    capture_output=True, text=True, errors="replace", timeout=15)
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert bytes(received) == b"\r" * expected_returns, (challenge, received)
            print("PASS: live challenge receives only the permitted RETURN bytes -", challenge)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
    check_live_challenges()
    check_interleaved_echo()
