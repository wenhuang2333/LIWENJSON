"""HTTP facade tests: start a server on an ephemeral port and call it."""

from __future__ import annotations

import contextlib
import http.client
import json
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

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

    def test_unrepresentable_request_numbers_do_not_change_schema_constraints(self) -> None:
        for number in ("0.99999999999999999999", "1e-400", "1e400", "NaN", "Infinity", "-Infinity"):
            with self.subTest(number=number):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
                try:
                    connection.request("POST", "/analyze", body='{"text":"1","schema_json":{"const":' + number + '}}')
                    response = connection.getresponse()
                    body = json.loads(response.read())
                    self.assertEqual(response.status, 400)
                    self.assertEqual(body["error"]["code"], "E070")
                    self.assertNotIn("result", body)
                finally:
                    connection.close()
        status, body = self.post("/analyze", {"text": "1", "schema": "number(enum:[0.99999999999999999999])"})
        self.assertEqual(status, 200)
        self.assertFalse(body["result"]["executable"])
        self.assertFalse(body["result"]["refusal"]["auto_retry"])

    def test_unrepresentable_response_numbers_are_refused_without_non_json_infinity(self) -> None:
        for number in ("0.99999999999999999999", "1e-400", "1e400"):
            status, body = self.post("/analyze", {"text": '{"amount":' + number + '}'})
            self.assertEqual(status, 200)
            self.assertFalse(body["result"]["executable"])
            self.assertIsNone(body["result"]["value"])
            self.assertFalse(body["result"]["refusal"]["auto_retry"])
            json.dumps(body, allow_nan=False)

    def test_refused_response_cannot_contain_infinity(self) -> None:
        status, body = self.post("/analyze", {"text": '{"amount":1e400,"words":["a" "b"]}', "profile": "permissive"})
        self.assertEqual(status, 200)
        self.assertFalse(body["result"]["executable"])
        self.assertIsNone(body["result"]["value"])
        self.assertFalse(body["result"]["refusal"]["auto_retry"])
        json.dumps(body, allow_nan=False)

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

    def test_host_json_decode_limits_return_a_structured_error(self) -> None:
        for raw in (
            '{"text":"{}","number":' + "1" * 4500 + "}",
            '{"text":"{}","nested":' + "[" * 20000 + "0" + "]" * 20000 + "}",
        ):
            with self.subTest(size=len(raw)):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
                try:
                    connection.request("POST", "/repair", body=raw.encode())
                    response = connection.getresponse()
                    body = json.loads(response.read())
                    self.assertEqual(response.status, 400)
                    self.assertFalse(body["ok"])
                    connection.request("GET", "/healthz")
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    response.read()
                finally:
                    connection.close()

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

    def test_content_length_non_ascii_digits_and_huge_integer_are_bounded(self) -> None:
        for length, expected in ((b"\xb2", 400), (b"9" * 4500, 413)):
            with self.subTest(length_bytes=len(length)):
                status, body, _ = self._exchange(
                    b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: " + length + b"\r\n\r\n"
                )
                self.assertEqual(status, expected)
                self.assertFalse(json.loads(body)["ok"])
        status, body, _ = self._exchange(
            b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: " + b"0" * 4500 + b"13\r\n\r\n",
            b'{"text":"{}"}',
        )
        self.assertEqual(status, 200)

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

    def test_a_refused_body_is_drained_before_the_close(self) -> None:
        # A socket closed while data is still queued is reset, not closed: on
        # Windows the peer then loses the response it was about to read
        # (WinError 10053), and everywhere else the next read is a reset. The
        # server therefore reads the announced remainder after refusing, so the
        # peer can still send it and still read the 408.
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(sock.close)
        sock.sendall(b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n")
        sock.sendall(b" ")
        time.sleep(0.7)  # past read_timeout=0.5s: the 408 is already on the wire
        sock.sendall(b" " * 19)  # must not be refused: the server is draining
        status, _ = self._read_response(sock, 5)
        self.assertEqual(status, 408)
        # The close is a plain FIN, so the refusal is the last thing on it.
        sock.settimeout(5)
        self.assertEqual(sock.recv(65536), b"")

    def _take_all_workers(self) -> None:
        # A response on the wire does not mean the handler is done: a refused
        # body is drained before the close, so a worker slot stays held for up
        # to the drain's own bound after its 408/413 was sent. Take the slots
        # once they are free; the wait is bounded, so a slot that never comes
        # back is still a failure rather than a hang.
        held = 0
        deadline = time.monotonic() + 5.0
        while held < self.server.max_workers:
            if self.server._workers.acquire(blocking=False):
                held += 1
            elif time.monotonic() >= deadline:
                for _ in range(held):
                    self.server._workers.release()
                self.fail(
                    f"{self.server.max_workers - held} of "
                    f"{self.server.max_workers} worker slots never freed"
                )
            else:
                time.sleep(0.02)

    @contextlib.contextmanager
    def _refusal_case(self, path: str):
        busy = path == "/repair"
        if busy:
            self._take_all_workers()
        try:
            yield 503 if busy else 404
        finally:
            if busy:
                for _ in range(self.server.max_workers):
                    self.server._workers.release()

    def test_refused_post_cannot_parse_body_as_the_next_request(self) -> None:
        for path in ("/nope", "/repair"):
            with self.subTest(path=path), self._refusal_case(path) as expected:
                status, payload, sock = self._exchange(
                    f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n".encode(),
                    b"bodyGET /healthz HTTP/1.1\r\nHost: x\r\n\r\n",
                )
                self.assertEqual(status, expected)
                self.assertEqual(json.loads(payload)["error"]["code"], f"E{expected}")
                # Unread pipelined GET bytes may cause RST instead of FIN, but
                # must never be parsed as bodyGET (501) or answered at all.
                try:
                    extra = sock.recv(65536)
                except (ConnectionResetError, ConnectionAbortedError):
                    extra = b""
                self.assertEqual(extra, b"")

    def test_route_and_worker_refusals_drain_a_late_declared_body(self) -> None:
        for path in ("/nope", "/repair"):
            for length in (4, 65):
                with self.subTest(path=path, length=length), self._refusal_case(path) as expected:
                    # The response precedes body arrival. Even an over-limit
                    # declaration must retain the route/worker status, not 413.
                    status, payload, sock = self._exchange(
                        f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: {length}\r\n\r\n".encode()
                    )
                    self.assertEqual(status, expected)
                    self.assertEqual(json.loads(payload)["error"]["code"], f"E{expected}")
                    sock.sendall(b"x" * length)
                    self.assertEqual(sock.recv(65536), b"")

    def test_refused_post_with_missing_body_closes_within_idle_budget(self) -> None:
        for path in ("/nope", "/repair"):
            with self.subTest(path=path), self._refusal_case(path) as expected:
                started = time.monotonic()
                status, _, sock = self._exchange(
                    f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n".encode()
                )
                self.assertEqual(status, expected)
                self.assertEqual(sock.recv(65536), b"")
                self.assertLess(time.monotonic() - started, 2.0)

    def test_refusal_status_survives_invalid_body_framing(self) -> None:
        for path in ("/nope", "/repair"):
            for framing in (
                b"Content-Length: -1\r\n",
                b"Content-Length: 2\r\nContent-Length: 2\r\n",
                b"Transfer-Encoding: chunked\r\n",
            ):
                with self.subTest(path=path, framing=framing), self._refusal_case(path) as expected:
                    status, payload, sock = self._exchange(
                        f"POST {path} HTTP/1.1\r\nHost: x\r\n".encode() + framing + b"\r\n"
                    )
                    self.assertEqual(status, expected)
                    self.assertEqual(json.loads(payload)["error"]["code"], f"E{expected}")
                    self.assertEqual(sock.recv(65536), b"")

    def test_refused_post_trickle_cannot_extend_the_drain_deadline(self) -> None:
        for path in ("/nope", "/repair"):
            with self.subTest(path=path), self._refusal_case(path) as expected, mock.patch(
                "liwenjson.http._DRAIN_TIMEOUT", 0.3
            ):
                status, _, sock = self._exchange(
                    f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 64\r\n\r\n".encode()
                )
                self.assertEqual(status, expected)
                stop = threading.Event()

                def trickle() -> None:
                    while not stop.is_set():
                        try:
                            sock.sendall(b"x")
                        except OSError:
                            return
                        stop.wait(0.05)  # below the idle timeout, beyond the total budget

                sender = threading.Thread(target=trickle, daemon=True)
                sender.start()
                started = time.monotonic()
                try:
                    sock.settimeout(1.5)
                    try:
                        extra = sock.recv(65536)
                    except (ConnectionResetError, ConnectionAbortedError):
                        extra = b""
                    self.assertEqual(extra, b"")
                    self.assertLess(time.monotonic() - started, 1.5)
                finally:
                    stop.set()
                    sender.join(timeout=1)

    def test_healthz_keeps_the_same_connection_after_success_and_busy(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        self.addCleanup(connection.close)
        connection.request("GET", "/healthz")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        sock = connection.sock
        with self._refusal_case("/repair"):
            connection.request("GET", "/healthz")
            response = connection.getresponse()
            self.assertEqual(response.status, 503)
            self.assertEqual(response.getheader("Retry-After"), "1")
            self.assertIsNone(response.getheader("Connection"))
            response.read()
            self.assertIs(connection.sock, sock)
        connection.request("GET", "/healthz")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        self.assertIs(connection.sock, sock)

    def test_partial_body_then_close_is_400(self) -> None:
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(sock.close)
        sock.sendall(b"POST /repair HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n{\"a\"")
        sock.shutdown(socket.SHUT_WR)
        status, body = self._read_response(sock, 5)
        self.assertEqual(status, 400)
        self.assertIn(b"ended after", body)
