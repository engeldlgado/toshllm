# ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
# Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Context checkpoints on the patched llama-server with a real model: a follow-up goes on from the previous prompt,
a sliding-window model whose window still holds the conversation also keeps the previous answer, and a recurrent
state is checkpointed exact while memory allows, in 8 bits and fewer copies when it is short. Skipped without a model.

    TOSH_TEST_MODEL=~/models/Qwen3.5-4B-Q4_K_M.gguf TOSH_FA_AMD=1 \\
    LLAMA_SERVER_BIN_PATH=vendor/llama.cpp/build-static/bin/llama-server \\
        python3 -I patches/llama/server/tests/test_checkpoints.py [-v]
"""

import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
BINARY = os.environ.get("LLAMA_SERVER_BIN_PATH") or os.path.join(ROOT, "vendor", "llama.cpp", "build-static", "bin",
                                                                  "llama-server")
MODEL = os.path.expanduser(os.environ.get("TOSH_TEST_MODEL", ""))
HOST = "127.0.0.1"
KEEP = os.environ.get("TOSH_TEST_KEEP") == "1"

# short enough to stay inside a 1024-token sliding window
SYSTEM = " ".join(f"Rule {i}: give the exact figure and say when a value is missing." for i in range(12))
QUESTIONS = ["Describe the depots of the north in a few sentences.", "Now describe the ones in the south.",
             "Which of the two grew faster, and why?"]
CREATED = re.compile(r"created context checkpoint \d+ of (\d+) \(.*?size = ([\d.]+) MiB\)")
SWA = re.compile(r"n_swa\s+=\s+[1-9]")
RECURRENT = re.compile(r"ssm_d_inner\s+=\s+[1-9]")


def free_port():
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


class Engine:
    def __init__(self, env=None):
        self.dir = tempfile.mkdtemp(prefix="tosh-checkpoint-test-")
        self.port = free_port()
        self.env = env or {}

    def start(self, seconds=180):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LLAMA_", "TOSH_RS_", "TOSH_AUTO_SIM"))}
        env.update(self.env)
        self.output = open(os.path.join(self.dir, "server.log"), "wb")
        self.process = subprocess.Popen(
            [BINARY, "--host", HOST, "--port", str(self.port), "--offline", "--no-ui", "--jinja", "-m", MODEL,
             "-ngl", "99", "-fa", "auto", "-c", "8192", "-np", "1", "--cache-ram", "0", "-lv", "4"],
            stdout=self.output, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        end = time.monotonic() + seconds
        while time.monotonic() < end and self.process.poll() is None:
            try:
                if self.request("GET", "/health", timeout=2)[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.3)
        raise RuntimeError("the engine did not start; its output is in " + self.output.name)

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(10)
        self.output.close()
        if not KEEP:
            shutil.rmtree(self.dir, ignore_errors=True)

    def log(self):
        with open(self.output.name, errors="replace") as f:
            return f.read()

    def request(self, method, path, body=None, timeout=300):
        connection = http.client.HTTPConnection(HOST, self.port, timeout=timeout)
        try:
            connection.request(method, path, None if body is None else json.dumps(body),
                               {"Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, json.loads(response.read() or b"null")
        finally:
            connection.close()


@unittest.skipUnless(MODEL and os.path.exists(MODEL), "set TOSH_TEST_MODEL to a GGUF model")
class CheckpointTest(unittest.TestCase):
    def engine(self, env=None):
        engine = Engine(env)
        engine.start()
        self.addCleanup(engine.stop)
        return engine

    def conversation(self, engine, turns, max_tokens=24):
        """Turns of a chat sent the way the app sends them, the history without reasoning; their timings."""
        messages = [{"role": "system", "content": SYSTEM}]
        timings = []
        for question in QUESTIONS[:turns]:
            messages.append({"role": "user", "content": question})
            status, body = engine.request("POST", "/v1/chat/completions", {
                "messages": messages, "max_tokens": max_tokens, "temperature": 0, "cache_prompt": True,
                "chat_template_kwargs": {"enable_thinking": False}})
            self.assertEqual(status, 200)
            messages.append({"role": "assistant", "content": body["choices"][0]["message"]["content"] or ""})
            timings.append(body["timings"])
        return timings

    def checkpoints(self, env=None):
        engine = self.engine(env)
        self.conversation(engine, 1)
        log = engine.log()
        if not RECURRENT.search(log):
            self.skipTest("the model has no recurrent state")
        found = CREATED.findall(log)
        self.assertTrue(found, "no context checkpoint was created")
        return int(found[-1][0]), float(found[-1][1]), log

    def test_a_follow_up_goes_on_from_the_previous_prompt(self):
        engine = self.engine()
        timings = self.conversation(engine, 3)
        for previous, now in zip(timings, timings[1:]):
            prompt = previous["cache_n"] + previous["prompt_n"]
            self.assertGreaterEqual(now["cache_n"], prompt - 8, f"a follow-up reused {now['cache_n']} of {prompt} tokens")
        self.assertNotIn("forcing full prompt re-processing", engine.log())

    def test_a_sliding_window_model_keeps_the_previous_answer(self):
        engine = self.engine()
        if not SWA.search(engine.log()):
            self.skipTest("the model has no sliding window")
        timings = self.conversation(engine, 3, max_tokens=96)
        for previous, now in zip(timings, timings[1:]):
            prompt = previous["cache_n"] + previous["prompt_n"]
            self.assertGreater(now["cache_n"], prompt + previous["predicted_n"] // 2,
                               f"a follow-up reused {now['cache_n']} tokens of a {prompt}-token prompt and its "
                               f"{previous['predicted_n']}-token answer")

    def test_a_recurrent_state_is_checkpointed_exact(self):
        _, size, _ = self.checkpoints()
        _, rounded, _ = self.checkpoints({"TOSH_RS_STATE_TYPE": "q8_0"})
        self.assertGreater(size, rounded * 3, f"a checkpoint of {size:.1f} MiB against {rounded:.1f} MiB in 8 bits")

    def test_little_free_memory_keeps_fewer_checkpoints_in_8_bits(self):
        n, size, _ = self.checkpoints()
        n_short, rounded, log = self.checkpoints({"TOSH_AUTO_SIM_RAM_MIB": "2400"})
        self.assertTrue("keeping them in 8 bits" in log, "the checkpoints stayed exact with little free memory")
        self.assertLess(rounded * 3, size)
        self.assertLess(n_short, n)


if __name__ == "__main__":
    unittest.main()
