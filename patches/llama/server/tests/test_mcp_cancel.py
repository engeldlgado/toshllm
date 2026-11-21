# ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
# Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
"""POST /tools of the patched llama-server against the synthetic MCP server in mcp_probe.py: a caller
that goes away stops its call, a queued caller that goes away sends nothing, a late answer never
reaches another caller, a handshake that fails is not sent again by every call queued behind it, and
the engine keeps serving after each failure. No model, network or credentials: the engine runs as a
router with no models, on loopback.

    LLAMA_SERVER_BIN_PATH=vendor/llama.cpp/build-static/bin/llama-server \\
        python3 -I patches/llama/server/tests/test_mcp_cancel.py [-v]
"""

import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
PROBE = os.path.join(HERE, "mcp_probe.py")
BINARY = os.environ.get("LLAMA_SERVER_BIN_PATH") or os.path.join(ROOT, "vendor", "llama.cpp", "build-static", "bin",
                                                                  "llama-server")
HOST = "127.0.0.1"
# far above every bound asserted below, so a call that waits for another call's timeout fails the test
LONG_MS = 10000
TEST_SECONDS = 90
KEEP = os.environ.get("TOSH_TEST_KEEP") == "1"
TIMINGS = os.environ.get("TOSH_TEST_TIMINGS")


# the reason the engine gives an MCP server when the caller of a tool goes away
CANCELLED = "cancelled"


def note(key, seconds):
    if TIMINGS:
        with open(TIMINGS, "a") as f:
            f.write(json.dumps({key: round(seconds, 3)}) + "\n")


def wait_for(predicate, seconds):
    end = time.monotonic() + seconds
    while True:
        value = predicate()
        if value or time.monotonic() >= end:
            return value
        time.sleep(0.02)


def free_port():
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def leave(connection):
    """Goes away without reading the answer, as a client that is closed or loses its network."""
    connection.sock.shutdown(socket.SHUT_RDWR)
    connection.close()


def in_background(function, *args, **kwargs):
    result = {}

    def run():
        try:
            result["value"] = function(*args, **kwargs)
        except Exception as error:  # reported by the test that reads it
            result["error"] = error

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, result


class Engine:
    """A llama-server router with no models and the probe as its only MCP server, or as its agent, which
    answers chat requests."""

    def __init__(self, timeout_ms, agent=False):
        self.dir = tempfile.mkdtemp(prefix="tosh-mcp-test-")
        self.log = os.path.join(self.dir, "probe.log")
        self.port = free_port()
        self.timeout_ms = timeout_ms
        self.agent = agent
        self.held = 0
        self.process = None
        self.output = None

    def start(self, seconds=60):
        config ={"mcpServers": {"probe": {"command": sys.executable, "args": ["-I", PROBE, self.log],
                                           "timeout_ms": self.timeout_ms}}}
        env = {k: v for k, v in os.environ.items() if not k.startswith("LLAMA_")}
        env["LLAMA_CACHE"] = os.path.join(self.dir, "cache")
        self.output = open(os.path.join(self.dir, "server.log"), "wb")
        agent = ["--mcp-agent", "probe"] if self.agent else []
        self.process = subprocess.Popen(
            [BINARY, "--host", HOST, "--port", str(self.port), "--offline", "--no-ui",
             "--mcp-servers-json", json.dumps(config)] + agent,
            stdout=self.output, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        up = self.healthy if self.agent else lambda: "probe_echo" in self.tools()
        ready = wait_for(lambda: self.process.poll() is not None or up(), seconds)
        if not ready or self.process.poll() is not None:
            raise RuntimeError("the engine did not start; its output is in " + self.output.name)

    def request(self, method, path, body=None, timeout=30):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=timeout)
        try:
            connection.request(method, path, None if body is None else json.dumps(body),
                               {"Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, json.loads(response.read() or b"null")
        finally:
            connection.close()

    def healthy(self):
        try:
            return self.request("GET", "/health", timeout=2)[0] == 200
        except OSError:
            return False

    def chat(self, timeout=30):
        """A chat request the agent answers; its status."""
        connection = self.start_chat(timeout)
        try:
            return connection.getresponse().status
        finally:
            connection.close()

    def start_chat(self, timeout=30):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=timeout)
        connection.request("POST", "/v1/chat/completions", json.dumps({"messages": [{"role": "user", "content": "hi"}]}),
                           {"Content-Type": "application/json", "X-Tosh-Agent": "on"})
        return connection

    def hold(self):
        """Holds the handshake of the next probe the engine starts; returns the file that holds it."""
        self.held = len(self.received("initialize"))
        hold = self.log + ".hold"
        open(hold, "w").close()
        return hold

    def handshakes(self):
        """The initialize requests the probe received since hold()."""
        return self.received("initialize")[self.held:]

    def tools(self):
        try:
            status, body = self.request("GET", "/tools", timeout=2)
        except OSError:
            return []
        if status != 200:
            return []
        return [t.get("tool") or t.get("definition", {}).get("function", {}).get("name") for t in body]

    def call(self, tool, timeout=30, **params):
        start = time.monotonic()
        status, body = self.request("POST", "/tools", {"tool": "probe_" + tool, "params": params}, timeout)
        if status != 200:
            raise AssertionError("POST /tools answered %d: %s" % (status, body))
        return body, time.monotonic() - start

    def start_call(self, tool, **params):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=30)
        connection.request("POST", "/tools", json.dumps({"tool": "probe_" + tool, "params": params}),
                           {"Content-Type": "application/json"})
        return connection

    def entries(self):
        try:
            with open(self.log) as f:
                text = f.read()
        except FileNotFoundError:
            return []
        # the probe writes each line whole, newline included
        return [json.loads(line) for line in text.split("\n")[:-1]]

    def received(self, method):
        return [e for e in self.entries() if e.get("got", {}).get("method") == method]

    def calls(self):
        """Every tools/call the probe received, as (pid, id, tool, message)."""
        return [(e["pid"], e["got"]["id"], e["got"]["params"]["name"], e["got"]["params"]["arguments"].get("message"))
                for e in self.received("tools/call")]

    def call_of(self, message):
        found = [c for c in self.calls() if c[3] == message]
        assert len(found) <= 1, found
        return found[0] if found else None

    def cancels_of(self, message):
        """The reasons the probe was given to stop the call that carried this message."""
        call = self.call_of(message)
        if call is None:
            return []
        return [e["got"]["params"]["reason"] for e in self.received("notifications/cancelled")
                if e["pid"] == call[0] and e["got"]["params"]["requestId"] == call[1]]

    def woke(self, message):
        call = self.call_of(message)
        return call is not None and any(e.get("woke") == call[1] and e["pid"] == call[0] for e in self.entries())

    def processes(self):
        rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,stat=,command="], capture_output=True, text=True).stdout
        return [row.split(None, 3) for row in rows.splitlines() if len(row.split(None, 3)) == 4]

    def live_probes(self):
        # the engine's own command line names the log too, inside its MCP config
        engine = self.process.pid if self.process else None
        return [int(pid) for pid, _, stat, command in self.processes()
                if self.log in command and "Z" not in stat and int(pid) != engine]

    def zombies(self):
        return [int(pid) for pid, ppid, stat, _ in self.processes()
                if self.process and int(ppid) == self.process.pid and "Z" in stat]

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(10)
        if self.output:
            self.output.close()

    def close(self):
        """Stops the engine and whatever it left behind, however the test ended."""
        self.stop()
        for pid in self.live_probes():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.process:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        if KEEP:
            print("kept " + self.dir, file=sys.stderr)
        else:
            shutil.rmtree(self.dir, ignore_errors=True)


def setUpModule():
    # the first start of a new binary compiles its Metal library, about a minute here; no test should time that
    engine = Engine(LONG_MS)
    try:
        engine.start(seconds=600)
    finally:
        engine.close()


class EngineTest(unittest.TestCase):

    def setUp(self):
        self.engines = []
        signal.signal(signal.SIGALRM, self.expired)
        signal.alarm(TEST_SECONDS)

    def tearDown(self):
        signal.alarm(0)
        for engine in self.engines:
            engine.close()

    @staticmethod
    def expired(signum, frame):
        raise TimeoutError("the test took longer than %d s" % TEST_SECONDS)

    def engine(self, timeout_ms, agent=False):
        engine = Engine(timeout_ms, agent)
        self.engines.append(engine)
        engine.start()
        return engine

    def assertServing(self, engine):
        self.assertIsNone(engine.process.poll(), "the engine exited")
        self.assertEqual(engine.request("GET", "/health", timeout=5)[0], 200)
        body, _ = engine.call("echo", timeout=15, message="still serving")
        self.assertEqual(body, {"plain_text_response": "still serving"})

    def leave_while_queued(self, engine):
        """A gate call holds the probe's lane while a hang call queued behind it goes away, then the gate opens."""
        gate = os.path.join(engine.dir, "open")
        first, result = in_background(engine.call, "gate", message="first", path=gate)
        self.assertTrue(wait_for(lambda: engine.call_of("first"), 10), "the first call never reached the probe")
        queued = engine.start_call("hang", message="queued")
        # nothing tells when the engine has read the request and queued it; it takes milliseconds
        time.sleep(0.5)
        leave(queued)
        open(gate, "w").close()
        first.join(15)
        self.assertEqual(result.get("value", (result.get("error"),))[0], {"plain_text_response": "first"})


class McpCancelTest(EngineTest):

    def test_a_call_goes_through_the_engine_to_the_mcp_server_and_back(self):
        engine = self.engine(LONG_MS)
        self.assertTrue({"probe_echo", "probe_hang", "probe_gate"} <= set(engine.tools()))
        body, _ = engine.call("echo", message="hello")
        # the probe answers with MCP content blocks; the flat field is the engine's own
        self.assertEqual(body, {"plain_text_response": "hello"})
        self.assertEqual([c[2:] for c in engine.calls()], [("echo", "hello")])
        clients = {e["got"]["params"]["clientInfo"]["name"] for e in engine.received("initialize")}
        self.assertEqual(clients, {"llama.cpp"})
        self.assertServing(engine)

    def test_a_server_is_told_how_long_the_engine_waits_for_a_call(self):
        engine = self.engine(LONG_MS)
        engine.call("echo", message="hello")
        started = [e for e in engine.entries() if e.get("started")]
        self.assertTrue(started)
        self.assertEqual({e["timeout_ms"] for e in started}, {str(LONG_MS)})

    def test_a_caller_that_goes_away_cancels_its_call(self):
        engine = self.engine(LONG_MS)
        caller = engine.start_call("hang", message="gone")
        self.assertTrue(wait_for(lambda: engine.call_of("gone"), 10), "the call never reached the probe")
        leave(caller)
        gone = time.monotonic()
        told = wait_for(lambda: engine.cancels_of("gone"), 3)
        note("disconnect_cancel_s", time.monotonic() - gone)
        self.assertEqual(told, [CANCELLED], "the probe was not told within 3 s")
        self.assertServing(engine)

    def test_a_call_after_a_cancelled_one_is_answered_at_once(self):
        engine = self.engine(LONG_MS)
        caller = engine.start_call("hang", message="gone")
        self.assertTrue(wait_for(lambda: engine.call_of("gone"), 10), "the call never reached the probe")
        leave(caller)
        body, elapsed = engine.call("echo", message="next")
        note("disconnect_next_call_s", elapsed)
        self.assertEqual(body, {"plain_text_response": "next"})
        self.assertLess(elapsed, 3, "the next call waited for the abandoned one")
        self.assertServing(engine)

    def test_a_queued_caller_that_goes_away_gives_up_its_place(self):
        engine = self.engine(LONG_MS)
        self.leave_while_queued(engine)
        body, elapsed = engine.call("echo", message="after")
        note("queued_gone_next_call_s", elapsed)
        self.assertEqual(body, {"plain_text_response": "after"})
        self.assertLess(elapsed, 3, "the next call waited behind the abandoned one")
        self.assertServing(engine)

    def test_a_queued_caller_that_goes_away_sends_nothing(self):
        engine = self.engine(LONG_MS)
        self.leave_while_queued(engine)
        engine.call("echo", message="after")
        # an absence shows only by waiting; a call sent late would have arrived within milliseconds
        time.sleep(0.5)
        self.assertIsNone(engine.call_of("queued"), "the abandoned call reached the MCP server")
        self.assertServing(engine)

    def test_a_late_answer_is_dropped_and_the_next_call_gets_its_own(self):
        engine = self.engine(1000)
        body, elapsed = engine.call("defer", message="late")
        self.assertIn("timed out", body.get("error", ""), body)
        self.assertTrue(0.9 <= elapsed < 3, elapsed)
        self.assertEqual(wait_for(lambda: engine.cancels_of("late"), 3), ["request timed out"])
        # the probe sends the held answer to "late" just before this one's
        body, _ = engine.call("echo", message="mine")
        self.assertEqual(body, {"plain_text_response": "mine"})
        self.assertServing(engine)

    def test_a_slow_answer_within_the_timeout_is_waited_for(self):
        engine = self.engine(5000)
        body, elapsed = engine.call("slow", message="slow", seconds=1)
        self.assertEqual(body, {"plain_text_response": "slow"})
        self.assertGreaterEqual(elapsed, 1)
        self.assertEqual(engine.received("notifications/cancelled"), [])
        self.assertServing(engine)

    def test_a_server_busy_past_the_timeout_fails_the_call_on_time_and_answers_later(self):
        engine = self.engine(1000)
        body, elapsed = engine.call("slow", message="busy", seconds=2.5)
        self.assertIn("timed out", body.get("error", ""), body)
        self.assertLess(elapsed, 2.2)
        self.assertTrue(wait_for(lambda: engine.woke("busy"), 5), "the probe never woke")
        body, _ = engine.call("echo", message="after")
        self.assertEqual(body, {"plain_text_response": "after"})
        self.assertServing(engine)

    def test_a_busy_server_is_told_its_caller_went_away_and_the_next_call_waits_only_for_it(self):
        engine = self.engine(LONG_MS)
        caller = engine.start_call("slow", message="busy", seconds=2)
        self.assertTrue(wait_for(lambda: engine.call_of("busy"), 10), "the call never reached the probe")
        leave(caller)
        gone = time.monotonic()
        body, _ = engine.call("echo", message="after")
        note("busy_gone_next_call_s", time.monotonic() - gone)
        self.assertEqual(body, {"plain_text_response": "after"})
        self.assertLess(time.monotonic() - gone, 5, "the next call waited for the abandoned call's timeout")
        self.assertEqual(engine.cancels_of("busy"), [CANCELLED])
        self.assertServing(engine)

    def test_concurrent_calls_each_get_their_own_answer(self):
        engine = self.engine(LONG_MS)
        with ThreadPoolExecutor(8) as pool:
            answers = list(pool.map(lambda i: engine.call("echo", message="m%d" % i)[0], range(24)))
        self.assertEqual(answers, [{"plain_text_response": "m%d" % i} for i in range(24)])
        ids = [c[:2] for c in engine.calls()]
        self.assertEqual(len(ids), 24)
        self.assertEqual(len(set(ids)), 24)
        self.assertServing(engine)

    def test_the_late_answer_of_a_cancelled_call_does_not_reach_the_next_caller(self):
        engine = self.engine(LONG_MS)
        caller = engine.start_call("defer", message="gone")
        self.assertTrue(wait_for(lambda: engine.call_of("gone"), 10), "the call never reached the probe")
        leave(caller)
        self.assertEqual(wait_for(lambda: engine.cancels_of("gone"), 3), [CANCELLED])
        # the probe sends the held answer to "gone" just before this one's, on the same process
        body, elapsed = engine.call("echo", message="mine")
        self.assertEqual(body, {"plain_text_response": "mine"})
        self.assertLess(elapsed, 3)
        gone, mine = engine.call_of("gone"), engine.call_of("mine")
        self.assertEqual(gone[0], mine[0])
        self.assertNotEqual(gone[1], mine[1])
        self.assertServing(engine)

    def test_an_mcp_server_that_dies_or_closes_its_output_fails_the_call_and_is_replaced(self):
        engine = self.engine(LONG_MS)
        for tool in ("die", "eof"):
            with self.subTest(tool=tool):
                body, elapsed = engine.call(tool, message=tool)
                self.assertIn("error", body)
                self.assertLess(elapsed, 3)
                body, _ = engine.call("echo", message="back after " + tool)
                self.assertEqual(body, {"plain_text_response": "back after " + tool})
                self.assertTrue(wait_for(lambda: len(engine.live_probes()) == 1, 5), engine.live_probes())
                self.assertEqual(engine.zombies(), [])
        self.assertServing(engine)

    def test_calls_queued_behind_a_handshake_that_times_out_fail_with_it(self):
        engine = self.engine(1500)
        hold = engine.hold()
        with ThreadPoolExecutor(3) as pool:
            results = list(pool.map(lambda i: engine.call("echo", message="q%d" % i), range(3)))
        slowest = max(elapsed for _, elapsed in results)
        note("held_handshake_slowest_s", slowest)
        self.assertTrue(all("error" in body for body, _ in results), results)
        self.assertLess(slowest, 2.5, "each queued call waited for a handshake of its own")
        self.assertEqual(len(engine.handshakes()), 1)
        os.remove(hold)
        # a failed handshake is sent again after a few seconds, to the same process
        self.assertTrue(wait_for(lambda: engine.call("echo", message="back")[0] == {"plain_text_response": "back"}, 15))
        self.assertServing(engine)

    def test_a_client_that_reads_only_content_gets_the_answer_and_never_a_draft(self):
        engine = self.engine(LONG_MS, agent=True)
        connection = http.client.HTTPConnection(HOST, engine.port, timeout=30)
        connection.request("POST", "/v1/chat/completions",
                           json.dumps({"messages": [{"role": "user", "content": "hi"}], "stream": True}),
                           {"Content-Type": "application/json", "X-Tosh-Agent": "on"})
        content, events = "", []
        for raw in connection.getresponse():
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[6:])
            for choice in chunk.get("choices") or []:
                content += (choice.get("delta") or {}).get("content") or ""
            if (chunk.get("tosh") or {}).get("event"):
                events.append(chunk["tosh"]["event"]["type"])
        connection.close()
        self.assertEqual(content, "The answer is 42.")
        self.assertIn("draft", events)
        self.assertIn("retract", events)

    def hang_twice(self, engine, tag):
        """Two calls that time out while the probe stops reading; the third, queued behind the second, is returned."""
        body, _ = engine.call("slow", timeout=15, message=tag + "-stuck", seconds=30)
        self.assertIn("timed out", body.get("error", ""), body)
        second, second_result = in_background(engine.call, "slow", 30, message=tag + "-again", seconds=30)
        time.sleep(0.3)
        return in_background(engine.call, "echo", 30, message=tag + "-queued")

    def test_a_server_that_stops_answering_is_replaced_and_a_queued_call_runs_once_on_the_fresh_one(self):
        engine = self.engine(1000)
        engine.call("echo", message="warm")
        old = {pid for pid, _, _, _ in engine.calls()}
        queued, result = self.hang_twice(engine, "first")
        queued.join(30)
        self.assertEqual(result.get("value", (result.get("error"),))[0], {"plain_text_response": "first-queued"})
        ran = [pid for pid, _, _, message in engine.calls() if message == "first-queued"]
        self.assertEqual(len(ran), 1, "the queued call ran %d times" % len(ran))
        self.assertNotIn(ran[0], old, "the queued call reached the hung process")
        self.assertTrue(wait_for(lambda: len(engine.live_probes()) == 1, 10), engine.live_probes())
        self.assertServing(engine)

    def test_a_slow_server_that_answers_a_ping_is_kept(self):
        engine = self.engine(1000)
        engine.call("echo", message="warm")
        for i in range(2):
            body, _ = engine.call("hang", message="hang %d" % i)
            self.assertIn("timed out", body.get("error", ""), body)
        body, _ = engine.call("echo", message="still")
        self.assertEqual(body, {"plain_text_response": "still"})
        self.assertEqual(len({pid for pid, _, _, _ in engine.calls()}), 1, "a slow server was restarted")
        self.assertTrue(engine.received("ping"))

    def test_a_server_that_hangs_again_after_a_restart_waits_before_the_next_start(self):
        engine = self.engine(1000)
        engine.call("echo", message="warm")
        # two calls time out on the first process and two on the fresh one, with no answer in between
        for i in range(4):
            body, _ = engine.call("slow", timeout=15, message="stuck %d" % i, seconds=30)
            self.assertIn("timed out", body.get("error", ""), body)
        body, elapsed = engine.call("echo", message="during the wait")
        self.assertIn("unavailable", body.get("error", ""), body)
        self.assertLess(elapsed, 1)
        self.assertTrue(wait_for(lambda: "plain_text_response" in engine.call("echo", message="after")[0], 15),
                        "the server was not started again after its wait")

    def test_chat_turns_queued_behind_the_agents_handshake_fail_with_it(self):
        # the agent's server takes calls in parallel, so its turns wait for the handshake itself, not for a call
        engine = self.engine(1500, agent=True)
        engine.hold()

        def turn(_):
            start = time.monotonic()
            return engine.chat(), time.monotonic() - start

        with ThreadPoolExecutor(3) as pool:
            results = list(pool.map(turn, range(3)))
        slowest = max(elapsed for _, elapsed in results)
        note("held_agent_handshake_slowest_s", slowest)
        self.assertTrue(all(status != 200 for status, _ in results), results)
        self.assertLess(slowest, 2.5, "each queued turn waited for a handshake of its own")
        self.assertEqual(len(engine.handshakes()), 1)
        self.assertTrue(engine.healthy())

    def test_the_engine_survives_every_failure_and_leaves_nothing_running(self):
        engine = self.engine(1500)
        caller = engine.start_call("hang", message="gone")
        self.assertTrue(wait_for(lambda: engine.call_of("gone"), 10), "the call never reached the probe")
        leave(caller)
        self.leave_while_queued(engine)
        for tool in ("hang", "defer", "die", "eof"):
            engine.call(tool, message=tool)
        engine.call("slow", message="busy", seconds=2)
        self.assertTrue(wait_for(lambda: engine.woke("busy"), 5), "the probe never woke")
        self.assertIn("probe_echo", engine.tools())
        self.assertServing(engine)
        self.assertEqual(engine.zombies(), [])
        engine.stop()
        self.assertTrue(wait_for(lambda: engine.live_probes() == [], 5), engine.live_probes())


if __name__ == "__main__":
    if not os.access(BINARY, os.X_OK):
        sys.exit("no llama-server at %s; build it or set LLAMA_SERVER_BIN_PATH" % BINARY)
    unittest.main()
