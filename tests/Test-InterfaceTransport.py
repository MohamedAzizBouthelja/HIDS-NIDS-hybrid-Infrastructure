"""Local integration test: real HTTP JSON and Telnet sockets, simulated IOS.

Uses Python's standard library and Windows PowerShell. Does not contact GNS3.
The GitHub workflow uses the dependency-free PowerShell tests instead.
"""
import json
import socketserver
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "gns3/core-topology.json").read_text())
PROJECT_ID = MANIFEST["project"]["project_id"]
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
COUNTERS = dict(opens=0, changes=0, saves=0, measured_pings=0, wake_returns=0)


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
                elif command.startswith("show running-config interface "):
                    name = command.split()[-1]
                    config = router["interfaces"][name]
                    body = "Building configuration...\r\nCurrent configuration : 90 bytes\r\n!\r\ninterface " + name + "\r\n"
                    body += (" ip address " + config["address"] + " " + config["mask"] if config["address"] else " no ip address") + "\r\n"
                    if config["shutdown"]:
                        body += " shutdown\r\n"
                    body += " duplex auto\r\n speed auto\r\nend\r\n"
                elif command == "configure terminal":
                    mode = "(config)"
                elif command.startswith("hostname "):
                    router["hostname"] = command.split()[1]
                    COUNTERS["changes"] += 1
                elif command.startswith("interface "):
                    selected, mode = command.split()[1], "(config-if)"
                elif command.startswith("ip address "):
                    _, _, address, mask = command.split()
                    router["interfaces"][selected].update(address=address, mask=mask)
                    COUNTERS["changes"] += 1
                elif command == "no shutdown":
                    router["interfaces"][selected]["shutdown"] = False
                    COUNTERS["changes"] += 1
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
                self.request.sendall((command + "\r\n" + body + router["hostname"] + mode + "#").encode())


class ConsoleServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def main():
    servers, nodes, links = [], [], []
    by_name = {router["name"]: router for router in MANIFEST["routers"]}
    for router in MANIFEST["routers"]:
        server = ConsoleServer(("127.0.0.1", 0), ConsoleHandler)
        server.router = dict(hostname="Router", interfaces={f"FastEthernet{i}/0": dict(address="", mask="", shutdown=True) for i in range(6)})
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
    finally:
        for server in servers:
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
