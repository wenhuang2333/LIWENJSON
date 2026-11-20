"""HTTP facade tests: start a server on an ephemeral port and call it."""

from __future__ import annotations

import json
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request

from liwenjson.http import create_server
from version import engine_version, registry_version



class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = create_server("127.0.0.1", 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def post(self, path: str, body: dict) -> tuple[int, dict]:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def get(self, path: str) -> tuple[int, dict]:
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as response:
            return response.status, json.loads(response.read())

    def test_healthz(self) -> None:
        status, body = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["engine"], engine_version())

    def test_analyze(self) -> None:
        status, body = self.post(
            "/analyze",
            {
                "text": '{"words":["a" "b"]}',
                "profile": "execution",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["decision"], "ambiguous")

    def test_repair(self) -> None:
        status, body = self.post("/repair", {"text": "{'a':1,}"})
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["text"], '{"a":1}')

    def test_structured_error(self) -> None:
        status, body = self.post("/analyze", {"text": "{}", "profile": "nope"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "E050")

    def test_unknown_path(self) -> None:
        status, body = self.post("/nope", {})
        self.assertEqual(status, 404)
        self.assertFalse(body["ok"])

    def test_cors_preflight(self) -> None:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/analyze", method="OPTIONS"
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 204)
            self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")


if __name__ == "__main__":
    unittest.main()


class HTTPConnectionBodies(unittest.TestCase):
    """Raw-socket cases: the body limit must be decided before reading."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = create_server(
            "127.0.0.1", 0, max_body=64, read_timeout=0.5, max_workers=2
        )
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    @staticmethod
    def _read_response(sock: socket.socket, timeout: float) -> tuple[int, bytes]:
        sock.settimeout(timeout)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                raise AssertionError("the server closed before sending a response")
            data += chunk
        head, rest = data.split(b"\r\n\r\n", 1)
        status = int(head.split(b" ", 1)[1].split(b" ", 1)[0])
        length = 0
        for line in head.split(b"\r\n")[1:]:
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1])
        while len(rest) < length:
            chunk = sock.recv(65536)
            if not chunk:
                break
            rest += chunk
        return status, rest

    def _exchange(
        self, head: bytes, body: bytes = b"", timeout: float = 5.0
    ) -> tuple[int, bytes, socket.socket]:
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        self.addCleanup(sock.close)
        sock.sendall(head + body)
        return (*self._read_response(sock, timeout), sock)

    def test_negative_length_is_400_before_reading(self) -> None:
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\n"
        )
        self.assertEqual(status, 400)
        self.assertIn(b"Content-Length", body)

    def test_negative_one_length_is_400_before_reading(self) -> None:
        # P1-06 calls out -1 explicitly: a negative length must be refused by
        # the framing check, not handed to a read that fails on its own.
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n"
        )
        self.assertEqual(status, 400)
        self.assertIn(b"invalid Content-Length", body)

    def test_non_numeric_length_is_400(self) -> None:
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 1e3\r\n\r\n"
        )
        self.assertEqual(status, 400)

    def test_duplicate_length_is_400(self) -> None:
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n"
            b"Content-Length: 2\r\n\r\n{}"
        )
        self.assertEqual(status, 400)
        self.assertIn(b"duplicate", body)

    def test_transfer_encoding_is_400(self) -> None:
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            b"0\r\n\r\n"
        )
        self.assertEqual(status, 400)
        self.assertIn(b"Transfer-Encoding", body)

    def test_declared_over_limit_is_413_before_the_body(self) -> None:
        # Only the header is sent: a server that reads first would block here.
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 65\r\n\r\n",
            timeout=3.0,
        )
        self.assertEqual(status, 413)
        self.assertIn(b"65", body)

    def test_exactly_the_limit_is_accepted(self) -> None:
        body = b'{"text":"{}"}' + b" " * (64 - 13)
        self.assertEqual(len(body), 64)
        status, payload, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
            b"Content-Length: 64\r\n\r\n",
            body,
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)["result"]["text"], "{}")

    def test_one_over_the_limit_is_413(self) -> None:
        body = b'{"text":"{}"}' + b" " * (65 - 13)
        status, _, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 65\r\n\r\n", body
        )
        self.assertEqual(status, 413)

    def test_slow_body_is_408_and_bounded(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(sock.close)
        sock.sendall(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n"
        )
        t0 = time.monotonic()
        for _ in range(20):
            try:
                sock.sendall(b" ")
            except OSError:
                break
            time.sleep(0.1)
            if time.monotonic() - t0 > 3:
                break
        status, _ = self._read_response(sock, 5)
        elapsed = time.monotonic() - t0
        self.assertEqual(status, 408)
        self.assertLess(elapsed, 4.0)

    def test_partial_body_then_close_is_400(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(sock.close)
        sock.sendall(b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n{\"a\"")
        sock.shutdown(socket.SHUT_WR)
        status, body = self._read_response(sock, 5)
        self.assertEqual(status, 400)
        self.assertIn(b"ended after", body)
