#!/usr/bin/env python3
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



import argparse
import concurrent.futures
import socket
import unittest


def read_exact(client, count):
    result = bytearray()
    while len(result) < count:
        chunk = client.recv(count - len(result))
        if not chunk:
            raise EOFError("Forwarder closed before the complete Redis response")
        result.extend(chunk)
    return bytes(result)


class RedisVMRelayTests(unittest.TestCase):
    host = "127.0.0.1"
    port = 16382

    def connect(self):
        client = socket.create_connection((self.host, self.port), timeout=3)
        client.settimeout(3)
        return client

    def ping(self):
        with self.connect() as client:
            client.sendall(b"*1\r\n$4\r\nPING\r\n")
            self.assertEqual(read_exact(client, 7), b"+PONG\r\n")

    def test_ping(self):
        self.ping()

    def test_binary_echo(self):
        payload = bytes(range(256)) * 256
        with self.connect() as client:
            client.sendall(b"*2\r\n$4\r\nECHO\r\n$65536\r\n" + payload + b"\r\n")
            self.assertEqual(read_exact(client, 8), b"$65536\r\n")
            self.assertEqual(read_exact(client, len(payload) + 2), payload + b"\r\n")

    def test_pipelined_commands(self):
        with self.connect() as client:
            client.sendall(b"*1\r\n$4\r\nPING\r\n" * 100)
            self.assertEqual(read_exact(client, 700), b"+PONG\r\n" * 100)

    def test_concurrent_clients(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.ping(), range(32)))

    def test_repeated_reconnections(self):
        for _ in range(50):
            self.ping()

    def test_client_disconnect_during_response(self):
        payload = b"x" * 65536
        for _ in range(10):
            with self.connect() as client:
                client.sendall(b"*2\r\n$4\r\nECHO\r\n$65536\r\n" + payload + b"\r\n")
        self.ping()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test Redis through an existing TCP-to-Unix-socket forwarder using PING and ECHO.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=16382)
    args = parser.parse_args()
    RedisVMRelayTests.host = args.host
    RedisVMRelayTests.port = args.port
    unittest.main(argv=[__file__], verbosity=2)
