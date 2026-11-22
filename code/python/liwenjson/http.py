"""A dependency-free HTTP facade over the stdio protocol.

This is the integration path for tools that speak HTTP rather than stdio —
n8n, Dify, Coze, a gateway, or a browser page. It is deliberately a thin
translation of one request to one `liwenjson serve` call: no state, no caching,
no retries. A new engine process is used per request and closed afterwards, so
a crash cannot poison the next request; a caller that needs throughput should
use `Client` directly.

The body reader is bounded on purpose: `Content-Length` decides before a byte
is read, a declared or actual body over `max_body` is refused with 413, a body
that does not arrive in full within `read_timeout` is refused with 408 and the
connection is closed. The limit is the server's own; it does not depend on the
engine's `max_input_len`. At most `max_workers` requests are handled (and so at
most `max_workers` engine processes exist) at a time.

    python -m liwenjson.http --port 8080

    POST /repair    {"text": "...", "profile": "agent", "schema_json": {...}}
    POST /analyze   {"text": "...", "profile": "agent", "schema_json": {...}}
    POST /validate  {"text": "...", "schema": "{!query:string}"}
    POST /readiness {"text": "...", "schema": "{!query:string}"}
    GET  /healthz
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from . import __version__
from .client import Client, LIWENJSONError, _JSONFloat, _host_value_exact, find_binary

__all__ = ["LIWENJSONHTTPServer", "create_server", "main"]

_METHODS = {
    "/repair": "repair",
    "/analyze": "analyze",
    "/validate": "validate",
    "/readiness": "readiness",
}

#: The largest body the server will read, independent of the engine's own
#: `max_input_len`: the engine's limit is about the document, this one is about
#: what an unauthenticated HTTP peer may make the process allocate.
DEFAULT_MAX_BODY = 4 * 1024 * 1024
#: The whole body must arrive within this many seconds (not per read).
DEFAULT_READ_TIMEOUT = 5.0
#: Concurrent handlers, and therefore concurrent engine processes.
DEFAULT_MAX_WORKERS = 8

_READ_CHUNK = 64 * 1024
#: A refused body is drained by at most this many bytes before the close: enough
#: to empty the receive queue for an honest peer, bounded for a hostile one.
_DRAIN_CAP = 64 * 1024
#: How long the drain waits for the next byte of a refused body.
_DRAIN_IDLE = 1.0
#: The whole drain is bounded too, even if a peer keeps trickling bytes.
_DRAIN_TIMEOUT = 2.0


class _BodyError(Exception):
    """A request body the server refuses; `status` is the HTTP status to send.

    `declared` and `consumed` describe how much of the announced body the
    server has already taken. The rest is drained before the connection is
    closed, so the peer can read the refusal instead of a connection reset.
    """

    def __init__(
        self,
        status: int,
        message: str,
        code: str | None = None,
        *,
        declared: int = 0,
        consumed: int = 0,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code or {400: "E050", 408: "E408", 413: "E413"}.get(status, "E050")
        self.declared = int(declared)
        self.consumed = int(consumed)

    @property
    def undrained(self) -> int:
        """How many announced body bytes are still on the wire."""
        return max(0, self.declared - self.consumed)


class LIWENJSONHTTPServer(ThreadingHTTPServer):
    """A threaded server that keeps the binary path and the body bounds.

    One request equals one engine process, so `max_workers` is also the bound
    on concurrent engine processes; a request that cannot get a slot is
    refused with 503 instead of forking without limit.
    """

    daemon_threads = True
    request_queue_size = 32

    def __init__(
        self,
        address: tuple[str, int],
        binary: str | None = None,
        *,
        max_body: int = DEFAULT_MAX_BODY,
        read_timeout: float = DEFAULT_READ_TIMEOUT,
        max_workers: int = DEFAULT_MAX_WORKERS,
    ) -> None:
        if max_body < 0:
            raise ValueError("max_body must not be negative")
        if read_timeout <= 0:
            raise ValueError("read_timeout must be positive")
        if max_workers < 1:
            raise ValueError("max_workers must be at least 1")
        super().__init__(address, _Handler)
        self.binary = binary or find_binary()
        self.max_body = int(max_body)
        self.read_timeout = float(read_timeout)
        self.max_workers = int(max_workers)
        self._workers = threading.BoundedSemaphore(self.max_workers)


class _Handler(BaseHTTPRequestHandler):
    server_version = "liwenjson/" + __version__
    protocol_version = "HTTP/1.1"

    # -- helpers ----------------------------------------------------------

    @property
    def _http(self) -> LIWENJSONHTTPServer:
        return self.server  # type: ignore[return-value]

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        close = self.close_connection
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if close:
            self.send_header("Connection", "close")
        if status == 503:
            self.send_header("Retry-After", "1")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            # The peer went away; dropping the connection is the only option.
            self.close_connection = True
            return
        self.close_connection = close

    def _acquire_worker(self) -> bool:
        if self._http._workers.acquire(blocking=False):
            return True
        payload = {"ok": False, "error": {"code": "E503", "message": "too many concurrent requests"}}
        if self.command == "POST":
            self._refuse_post(503, payload)
        else:
            self._send(503, payload)
        return False

    def _refuse_post(self, status: int, payload: dict[str, Any]) -> None:
        """Send the route/worker refusal, then boundedly drain before closing."""
        self.close_connection = True
        self._send(status, payload)
        try:
            length = self._declared_length()
        except _BodyError as error:
            self._drain_body(error)
        else:
            self._drain_body(_BodyError(status, "", declared=length))

    def _release_worker(self) -> None:
        try:
            self._http._workers.release()
        except ValueError:  # pragma: no cover - released twice, defensive
            pass

    # -- body -------------------------------------------------------------

    def _declared_length(self) -> int:
        """The body length, refused before any body byte is read."""
        encodings = self.headers.get_all("Transfer-Encoding") or []
        if encodings:
            raise _BodyError(
                400,
                "Transfer-Encoding is not supported; send a Content-Length body",
            )
        lengths = self.headers.get_all("Content-Length") or []
        if len(lengths) > 1:
            raise _BodyError(400, "duplicate Content-Length header")
        if not lengths:
            return 0
        raw = lengths[0].strip()
        if not raw.isascii() or not raw.isdigit():
            raise _BodyError(400, f"invalid Content-Length {lengths[0]!r}")
        normalized = raw.lstrip("0") or "0"
        if len(normalized) > 20:
            raise _BodyError(
                413,
                f"request body is limited to {self._http.max_body} bytes",
                declared=_DRAIN_CAP,
            )
        length = int(normalized)
        if length > self._http.max_body:
            raise _BodyError(
                413,
                f"request body is limited to {self._http.max_body} bytes, "
                f"Content-Length declares {length}",
                declared=length,
            )
        return length

    def _read_body(self, length: int) -> bytes:
        """Read exactly `length` bytes, within one deadline for the whole body."""
        deadline = time.monotonic() + self._http.read_timeout
        chunks: list[bytes] = []
        remaining = length
        while remaining > 0:
            left = deadline - time.monotonic()
            if left <= 0:
                raise _BodyError(
                    408,
                    f"the request body did not arrive within {self._http.read_timeout:g}s",
                    declared=length,
                    consumed=length - remaining,
                )
            self.connection.settimeout(left)
            try:
                chunk = self.rfile.read1(min(remaining, _READ_CHUNK))
            except (TimeoutError, socket.timeout):
                raise _BodyError(
                    408,
                    f"the request body did not arrive within {self._http.read_timeout:g}s",
                    declared=length,
                    consumed=length - remaining,
                ) from None
            except OSError:
                raise _BodyError(
                    400,
                    "the connection was closed before the request body arrived",
                    declared=length,
                    consumed=length - remaining,
                ) from None
            if not chunk:
                raise _BodyError(
                    400,
                    f"the request body ended after {length - remaining} of {length} bytes",
                    declared=length,
                    consumed=length - remaining,
                )
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _drain_body(self, error: _BodyError) -> None:
        """Take the rest of a refused body off the wire before closing.

        A socket that is closed while data is still queued is reset, not closed:
        Windows sends RST and the peer loses the response it was about to read
        (`ConnectionAbortedError`, WinError 10053). The refusal is already on
        the wire, so the server reads the announced remainder and discards it;
        the close is then a plain FIN and the peer reads the 408 or 413.

        The buffered reader is unusable once a read has timed out -- it raises
        `cannot read from timed out object` from then on -- so the socket
        itself is read once that happens. The buffer is empty at that point,
        so no byte is skipped.
        """
        remaining = min(error.undrained, _DRAIN_CAP)
        if remaining <= 0:
            return
        # Bound both idle reads and the whole drain; trickling bytes must not
        # keep a refused connection (or its worker slot) alive indefinitely.
        deadline = time.monotonic() + _DRAIN_TIMEOUT
        raw = False
        while remaining > 0:
            left = deadline - time.monotonic()
            if left <= 0:
                return
            self.connection.settimeout(min(self._http.read_timeout, _DRAIN_IDLE, left))
            want = min(remaining, _READ_CHUNK)
            chunk = b""
            if not raw:
                try:
                    chunk = self.rfile.read1(want)
                except (TimeoutError, socket.timeout, OSError):
                    raw = True
            if raw:
                left = deadline - time.monotonic()
                if left <= 0:
                    return
                self.connection.settimeout(min(self._http.read_timeout, _DRAIN_IDLE, left))
                try:
                    chunk = self.connection.recv(want)
                except (TimeoutError, socket.timeout, OSError):
                    return
            if not chunk:
                return
            remaining -= len(chunk)

    def _body(self) -> dict[str, Any]:
        """The parsed body; on refusal the response is already sent and it raises."""
        try:
            length = self._declared_length()
            raw = self._read_body(length) if length else b"{}"
        except _BodyError as exc:
            # The unread part of the body (if any) makes keep-alive unsafe; it is
            # drained so the close is graceful and the peer can read the refusal.
            self.close_connection = True
            self._send(exc.status, {"ok": False, "error": {"code": exc.code, "message": str(exc)}})
            self._drain_body(exc)
            raise
        try:
            value = json.loads(raw.decode("utf-8"), parse_float=_JSONFloat, parse_constant=_JSONFloat)
        except (UnicodeDecodeError, ValueError, RecursionError) as exc:
            error = _BodyError(400, f"the request body cannot be decoded as JSON: {exc}")
        else:
            if not isinstance(value, dict):
                error = _BodyError(400, "the request body must be a JSON object")
            elif not _host_value_exact(value):
                error = _BodyError(
                    400,
                    "a request number cannot be represented without changing its value; pass exact numeric constraints in the schema text",
                    code="E070",
                )
            else:
                return value
        self._send(error.status, {"ok": False, "error": {"code": error.code, "message": str(error)}})
        raise error

    # -- routes -----------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/healthz":
            self._send(404, {"ok": False, "error": {"code": "E404", "message": "not found"}})
            return
        if not self._acquire_worker():
            return
        try:
            with Client(binary=self._http.binary) as client:
                hello = client.hello()
            self._send(
                200,
                {"ok": True, "engine": hello.get("engine"), "protocol": hello.get("protocol")},
            )
        except Exception as exc:  # pragma: no cover - health is best effort
            self._send(503, {"ok": False, "error": {"code": "E030", "message": str(exc)}})
        finally:
            self._release_worker()

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        method = _METHODS.get(path)
        if method is None:
            self._refuse_post(404, {"ok": False, "error": {"code": "E404", "message": "not found"}})
            return
        if not self._acquire_worker():
            return
        try:
            try:
                params = self._body()
            except _BodyError:
                return
            try:
                with Client(binary=self._http.binary) as client:
                    result = client.request(method, **params)
                self._send(200, {"ok": True, "result": result})
            except LIWENJSONError as exc:
                self._send(400, {"ok": False, "error": exc.to_dict()})
            except Exception as exc:  # pragma: no cover - defensive
                self._send(500, {"ok": False, "error": {"code": "E030", "message": str(exc)}})
        finally:
            self._release_worker()

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("liwenjson http: " + (fmt % args) + "\n")


def create_server(
    host: str = "127.0.0.1",
    port: int = 8080,
    binary: str | None = None,
    *,
    max_body: int = DEFAULT_MAX_BODY,
    read_timeout: float = DEFAULT_READ_TIMEOUT,
    max_workers: int = DEFAULT_MAX_WORKERS,
) -> LIWENJSONHTTPServer:
    """Bind a server; pass `port=0` to let the OS choose one."""
    return LIWENJSONHTTPServer(
        (host, port),
        binary=binary,
        max_body=max_body,
        read_timeout=read_timeout,
        max_workers=max_workers,
    )


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="liwenjson-http", description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--binary", default=None, help="path to the liwenjson executable")
    parser.add_argument(
        "--max-body",
        type=int,
        default=DEFAULT_MAX_BODY,
        help=f"largest accepted request body in bytes (default {DEFAULT_MAX_BODY})",
    )
    parser.add_argument(
        "--read-timeout",
        type=float,
        default=DEFAULT_READ_TIMEOUT,
        help=f"seconds the whole body may take to arrive (default {DEFAULT_READ_TIMEOUT:g})",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=DEFAULT_MAX_WORKERS,
        help=f"concurrent requests, hence engine processes (default {DEFAULT_MAX_WORKERS})",
    )
    args = parser.parse_args(argv)
    server = create_server(
        args.host,
        args.port,
        args.binary,
        max_body=args.max_body,
        read_timeout=args.read_timeout,
        max_workers=args.max_workers,
    )
    host, port = server.server_address[:2]
    print(f"liwenjson http listening on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
