# ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
# Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
"""The address the patched llama-server hands its agent to call it back: a URL the agent reads with its host and
port on every address the server listens on, IPv4, a name, IPv6 loopback and a link-local address with its zone.
The agent here is the synthetic MCP server of mcp_probe.py, which logs the arguments it gets. No model, network or
credentials: the engine runs as a router with no models.

    LLAMA_SERVER_BIN_PATH=vendor/llama.cpp/build-static/bin/llama-server \\
        python3 -I patches/llama/server/tests/test_mcp_agent_url.py [-v]
"""

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
PROBE = os.path.join(HERE, "mcp_probe.py")
BINARY = os.environ.get("LLAMA_SERVER_BIN_PATH") or os.path.join(ROOT, "vendor", "llama.cpp", "build-static", "bin",
                                                                  "llama-server")
# lo0 has this link-local address on macOS
HOSTS = (("127.0.0.1", "127.0.0.1"), ("localhost", "localhost"), ("::1", "::1"), ("fe80::1%lo0", "fe80::1%lo0"))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class AgentUrlTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)

    def handed(self, host):
        """The base_url the server gave its agent for one chat request, listening on `host`."""
        log, port = os.path.join(self.dir, f"agent-{port_safe(host)}.log"), free_port()
        config = {"mcpServers": {"agent": {"command": sys.executable, "args": ["-I", PROBE, log], "timeout_ms": 30000}}}
        # the engine refuses tools on any address but loopback unless told the network is trusted
        trusted = [] if host in ("127.0.0.1", "localhost", "::1") else ["--allow-unauthenticated-tools"]
        process = subprocess.Popen([BINARY, "--host", host, "--port", str(port), "--offline", "--no-ui",
                                    "--mcp-servers-json", json.dumps(config), "--mcp-agent", "agent", *trusted],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                self.assertIsNone(process.poll(), f"llama-server exited listening on {host}")
                connection = http.client.HTTPConnection(host, port, timeout=5)
                try:
                    connection.request("GET", "/health")
                    if connection.getresponse().status == 200:
                        break
                except OSError:
                    time.sleep(0.5)
                finally:
                    connection.close()
            connection = http.client.HTTPConnection(host, port, timeout=60)
            connection.request("POST", "/v1/chat/completions", json.dumps({"messages": [{"role": "user", "content": "hi"}]}),
                               {"Content-Type": "application/json", "X-Tosh-Agent": "on"})
            connection.getresponse().read()
            connection.close()
        finally:
            process.terminate()
            process.wait(30)
        with open(log) as handle:
            calls = [json.loads(line).get("got") or {} for line in handle]
        run = next(m for m in calls if m.get("method") == "tools/call" and (m.get("params") or {}).get("name") == "run")
        return run["params"]["arguments"]["base_url"], port

    def test_the_agent_reads_the_address_it_is_handed(self):
        for host, expected in HOSTS:
            with self.subTest(host=host):
                url, port = self.handed(host)
                parsed = urllib.parse.urlparse(url)
                try:
                    read = (urllib.parse.unquote(parsed.hostname or ""), parsed.port)
                except ValueError:
                    read = None
                self.assertEqual(read, (expected, port), url)


def port_safe(host):
    return "".join(c if c.isalnum() else "_" for c in host)


if __name__ == "__main__":
    unittest.main()
