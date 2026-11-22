"""A thin, dependency-free client for the `liwenjson serve` protocol.

The server is a child process speaking one JSON object per line on stdin and
stdout. A reader thread turns stdout into frames and a writer thread owns
stdin, so that neither an engine that stopped answering nor one that stopped
reading can hold a caller longer than the deadline it asked for.
"""

from __future__ import annotations

import json
import math
import os
import queue
import shutil
import subprocess
import threading
import time
from decimal import Decimal, DecimalException
from pathlib import Path
from typing import Any, Iterable

__all__ = [
    "Client",
    "LIWENJSONError",
    "LIWENJSONProtocolError",
    "find_binary",
    "repair",
    "analyze",
    "validate",
]

# The reader puts this on the queue when the connection ends. It carries no
# information of its own: the reason lives in `_fatal`, which every waiter
# reads, so the same error reaches the request in flight and the ones after.
_TERMINATED = object()

# `close()` runs on its own budget. It must not stack a request timeout on
# top of the grace it gives the engine: a close that waits for the request
# timeout is a close that waits for as long as the caller was willing to wait
# for an answer, and the caller is exactly the party that is gone.
_CLOSE_SHUTDOWN_GRACE = 2.0  # the shutdown request's own budget
_CLOSE_EXIT_GRACE = 1.0  # the engine's exit after it answered
_CLOSE_TERM_GRACE = 1.0  # after terminate()
_CLOSE_KILL_GRACE = 1.0  # after kill()
_CLOSE_JOIN_GRACE = 0.5  # per thread


class _JSONFloat(float):
    def __new__(cls, text: str) -> _JSONFloat:
        value = super().__new__(cls, text)
        try:
            value.exact = math.isfinite(value) and Decimal(text) == Decimal(str(float(value)))
        except DecimalException:
            value.exact = False
        return value


def _host_value_exact(value: Any) -> bool:
    pending = [value]
    while pending:
        node = pending.pop()
        if isinstance(node, _JSONFloat) and not node.exact:
            return False
        if isinstance(node, dict):
            pending.extend(node.values())
        elif isinstance(node, list):
            pending.extend(node)
    return True


def _host_payload(payload: dict[str, Any]) -> dict[str, Any]:
    pending: list[Any] = [payload]
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            if "value" in node and not _host_value_exact(node["value"]):
                if not isinstance(node.get("executable"), bool):
                    return {
                        "id": payload.get("id"),
                        "ok": False,
                        "error": {
                            "code": "E070",
                            "message": "The Python host value cannot preserve the exact JSON numbers.",
                            "exit": 5,
                        },
                    }
                message = "The Python host value cannot preserve the exact JSON numbers."
                node.update(
                    decision="invalid",
                    label="REJECT (host value not representable)",
                    exactness="lossy",
                    information_loss=True,
                    execution="blocked",
                    executable=False,
                    value=None,
                    error={"code": "E070", "message": message},
                    refusal={"kind": "host_declaration", "auto_retry": False},
                    retry={
                        "code": "E070",
                        "prompt": message + " Use a representation that preserves the exact JSON text. Do not automatically retry or execute a changed business action.",
                    },
                    business_authorized=False,
                )
            for key, value in node.items():
                if isinstance(value, _JSONFloat):
                    node[key] = float(value)
                elif isinstance(value, (dict, list)):
                    pending.append(value)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                if isinstance(value, _JSONFloat):
                    node[index] = float(value)
                elif isinstance(value, (dict, list)):
                    pending.append(value)
    return payload


class LIWENJSONError(RuntimeError):
    """A structured refusal from the engine (`E010`, `E011`, `E070`, ...)."""

    def __init__(self, error: dict[str, Any]) -> None:
        self.code = str(error.get("code", "E000"))
        self.message = str(error.get("message", ""))
        self.exit_code = int(error.get("exit", 1))
        self.retry_hint = error.get("retry_hint")
        self.offset = error.get("offset")
        super().__init__(f"{self.code} {self.message}")

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"code": self.code, "message": self.message, "exit": self.exit_code}
        if self.retry_hint is not None:
            out["retry_hint"] = self.retry_hint
        if self.offset is not None:
            out["offset"] = self.offset
        return out


class LIWENJSONProtocolError(RuntimeError):
    """The engine's output is not the protocol, so the connection is over.

    The error is sticky: a stream that produced a line which is not JSON, a
    line which is not an object, invalid UTF-8, EOF or a reader exception
    cannot be trusted again. The request that sees it and every request after
    it fail at once, instead of waiting for a timeout that says nothing about
    the cause and never comes.
    """


def _platform_key() -> str | None:
    """The release platform this interpreter can run, or None.

    The wheel carries one binary per release platform, so the choice is made
    here rather than by installing four different wheels: one wheel works on
    every platform the release supports, and the cost is a few unused
    megabytes.

    The keys are the release asset names with the `liwenjson-` prefix removed,
    so a wheel and a release can be compared by eye. There is deliberately no
    Intel-macOS key: the MoonBit toolchain publishes no `darwin-x86_64`
    target, so there is no binary to name.
    """

    import platform as _platform
    import sys

    machine = (_platform.machine() or "").lower()
    if sys.platform == "darwin":
        return "macos-arm64" if machine in ("arm64", "aarch64") else None
    if sys.platform.startswith("linux"):
        if machine in ("x86_64", "amd64"):
            return "linux-x86_64"
        if machine in ("aarch64", "arm64"):
            return "linux-arm64"
        return None
    if sys.platform in ("win32", "cygwin"):
        return "windows-x86_64"
    return None


def _make_executable(path: Path) -> None:
    """The executable bit survives a wheel install on most platforms, not all.

    A binary that is present but not executable turns every call into a
    `PermissionError` that names a file the user did not install by hand, so
    the bit is restored once, quietly, before the path is returned.
    """

    try:
        mode = path.stat().st_mode
        if not mode & 0o111:
            path.chmod(mode | 0o755)
    except OSError:
        pass


def find_binary() -> str:
    """Locate the engine.

    Order: `LIWENJSON_BIN`, `PATH`, the binary this wheel carries for this
    platform, a binary placed directly in `bin/`, then the development build
    inside this repository.

    An explicit path or a `PATH` entry wins over the bundled binary on purpose:
    a caller who has installed a newer CLI should not silently get whichever
    engine happened to be current when the Python package was built.
    """

    env = os.environ.get("LIWENJSON_BIN")
    if env:
        return env
    found = shutil.which("liwenjson")
    if found:
        return found
    here = Path(__file__).resolve().parent
    key = _platform_key()
    if key is not None:
        for name in ("liwenjson", "liwenjson.exe"):
            candidate = here / "bin" / key / name
            if candidate.is_file():
                _make_executable(candidate)
                return str(candidate)
    for name in ("liwenjson", "liwenjson.exe"):
        candidate = here / "bin" / name
        if candidate.is_file():
            _make_executable(candidate)
            return str(candidate)
    # Development checkout: code/python/liwenjson/client.py -> code/
    code_dir = here.parents[1]
    for target in ("native",):
        candidate = (
            code_dir
            / "_build"
            / target
            / "release"
            / "build"
            / "cmd"
            / "liwenjson"
            / "liwenjson.exe"
        )
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(_not_found_message(here, key))


def _not_found_message(here: Path, key: str | None) -> str:
    """Say what is missing in terms of what this installation actually has.

    Three different situations used to produce the same sentence, and only one
    of them was fixed by setting `LIWENJSON_BIN`:

      * a source checkout with no build -- "build it";
      * a wheel installed for a platform the release does not cover, such as
        Intel macOS -- "there is no binary for this platform", which no amount
        of `pip install` will change;
      * a wheel whose bundled directory was stripped by a repackager.
    """

    import platform as _platform
    import sys

    bundled = sorted(
        p.name for p in (here / "bin").iterdir() if p.is_dir()
    ) if (here / "bin").is_dir() else []
    where = f"{_platform.system()} {_platform.machine() or 'unknown'} ({sys.platform})"
    if bundled and key is None:
        return (
            f"the liwenjson engine is not available for {where}: the package "
            f"carries {', '.join(bundled)}. Set LIWENJSON_BIN to a binary built "
            "for this platform, or build one with "
            "`moon build cmd/liwenjson --target native --release`."
        )
    return (
        "the liwenjson engine was not found. Reinstall `liwenjson` from "
        "PyPI to get the bundled binary, or set LIWENJSON_BIN, put `liwenjson` on "
        "PATH, or build it with `moon build cmd/liwenjson --target native --release`"
    )


class _WriteJob:
    """One request line on its way to stdin.

    The writer thread sets `done` when the line is out and `error` when it
    could not be written. The caller waits for `done` with the deadline it
    already has, so an engine that stopped reading its input cannot hold the
    caller past that deadline.
    """

    __slots__ = ("line", "done", "error")

    def __init__(self, line: str) -> None:
        self.line = line
        self.done = threading.Event()
        self.error: BaseException | None = None


class _Frame:
    """One line of stdout, already classified by the reader.

    `attributed` is False for an error the engine could not attach to a
    request id; such a frame belongs to the request that is in flight.
    """

    __slots__ = ("payload", "attributed")

    def __init__(self, payload: dict[str, Any], attributed: bool) -> None:
        self.payload = payload
        self.attributed = attributed


class Client:
    """A long-lived `liwenjson serve` process.

    Use it as a context manager, or call `close()`. One client is not shared
    between threads; a lock serialises requests so a caller that does share one
    still gets correct `id` matching.
    """

    def __init__(
        self,
        binary: str | None = None,
        *,
        args: Iterable[str] = (),
        timeout: float = 30.0,
        stderr: int | None = None,
    ) -> None:
        self.binary = binary or find_binary()
        self.timeout = timeout
        # `_lock` serialises requests; `_state_lock` guards the lifecycle
        # flags, which are read from other threads (a request that arrives
        # while `close()` runs) and therefore cannot be plain attributes.
        self._lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._closing = False
        self._closed = False
        self._fatal: BaseException | None = None
        self._next_id = 0
        self._responses: "queue.Queue[Any]" = queue.Queue()
        # One line in flight at a time: a stalled writer must not make the
        # client buffer an unbounded number of requests.
        self._writer_q: "queue.Queue[Any]" = queue.Queue(maxsize=1)
        self._waiting = False
        self._stderr_lines: list[str] = []
        # `stderr` defaults to a pipe rather than DEVNULL. The engine writes
        # its diagnostics there, and `stderr=DEVNULL` meant that every error
        # message the client raised about a dead or misbehaving process ended
        # with an empty `stderr:` field -- the one piece of evidence that says
        # *why* the engine exited was thrown away by default. Pass
        # `stderr=subprocess.DEVNULL` to opt out.
        self.proc = subprocess.Popen(
            [self.binary, "serve", *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if stderr is None else stderr,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        self._writer = threading.Thread(target=self._write_stdin, daemon=True)
        self._writer.start()
        self._err_reader: threading.Thread | None = None
        if stderr is None:
            self._err_reader = threading.Thread(target=self._read_stderr, daemon=True)
            self._err_reader.start()

    # -- plumbing ---------------------------------------------------------

    def _read_stdout(self) -> None:
        """Turn stdout into frames, and every non-protocol byte into an error.

        A reader that dies quietly is the worst failure mode here: the request
        waits for a timeout that means nothing, and the next request waits
        again. So each abnormal ending -- a line that is not JSON, a line that
        is not an object, a response without the fields the protocol requires,
        invalid UTF-8, EOF, an exception -- ends the connection with one
        sticky error that the request in flight and every request after it
        see at once.
        """
        assert self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                frame = self._classify(line)
                if frame is None:
                    return
                self._responses.put(frame)
        except Exception as exc:
            self._terminate(f"liwenjson stopped answering: {exc}")
            return
        self._terminate("liwenjson closed the stream")

    def _classify(self, line: str) -> _Frame | None:
        """Check one line against the protocol, or end the connection."""
        try:
            payload = json.loads(line, parse_float=_JSONFloat)
        except json.JSONDecodeError:
            self._terminate(f"liwenjson wrote a line that is not JSON: {line[:120]!r}")
            return None
        if not isinstance(payload, dict):
            self._terminate(
                f"liwenjson wrote a JSON {type(payload).__name__}, not an object: {line[:120]!r}"
            )
            return None
        ok = payload.get("ok")
        if not isinstance(ok, bool):
            self._terminate(
                f"liwenjson wrote a response without a boolean `ok`: {line[:120]!r}"
            )
            return None
        if payload.get("id") is None:
            # The engine answers a request it could not attribute -- a line
            # over the protocol's limit, or a line that is not JSON -- with an
            # error that carries no id. Waiting for an answer that will never
            # come is what turned that into a timeout, so the frame goes to
            # the request in flight; with no request in flight the framing
            # cannot be trusted at all.
            if self._waiting:
                return _Frame(payload, False)
            self._terminate(f"liwenjson wrote a response without an id: {line[:120]!r}")
            return None
        if ok and "result" not in payload:
            self._terminate(
                f"liwenjson wrote a successful response without a result: {line[:120]!r}"
            )
            return None
        return _Frame(_host_payload(payload), True)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._stderr_lines.append(line.rstrip())
            if len(self._stderr_lines) > 100:
                del self._stderr_lines[:50]

    def _write_stdin(self) -> None:
        """Own stdin.

        Writing to a pipe whose reader has stopped blocks forever, so the
        write happens here and the caller waits for it with the deadline it
        already has. When that deadline passes the caller gives up and marks
        the connection unusable; the engine is then terminated, which is what
        unblocks this thread.
        """
        assert self.proc.stdin is not None
        while True:
            job = self._writer_q.get()
            if job is None:
                return
            try:
                self.proc.stdin.write(job.line)
                self.proc.stdin.flush()
            except Exception as exc:
                job.error = exc
                self._terminate(f"liwenjson stopped reading its input: {exc}")
            finally:
                job.done.set()

    def _terminate(self, message: str) -> None:
        """End the connection: one sticky error, seen by everyone waiting."""
        with self._state_lock:
            if self._fatal is not None:
                return
            self._fatal = LIWENJSONProtocolError(message)
        # Wake a request that is blocked on the queue: the error itself is in
        # `_fatal`, the marker only says "stop waiting".
        self._responses.put(_TERMINATED)

    def _fatal_error(self) -> BaseException | None:
        with self._state_lock:
            return self._fatal

    def _resync(self) -> None:
        """Drop every buffered answer.

        The reader thread is left alone: starting a second one would let two
        threads feed the same queue, and the answers would interleave. What
        matters is that a *late* answer cannot be mistaken for the next
        request's answer, which `request` handles by matching ids.
        """
        while True:
            try:
                self._responses.get_nowait()
            except queue.Empty:
                break

    def request(self, method: str, **params: Any) -> Any:
        """Send one request and return its `result`, or raise `LIWENJSONError`.

        The timeout covers the whole call. Waiting for the lock, writing the
        request and reading the answer share one deadline, so a caller that
        asked for one second is never kept waiting longer than that -- not
        once per phase, which is what made the timeout mean nothing.
        """
        self._reject_if_closed()
        deadline = time.monotonic() + self.timeout
        if not self._take_lock(deadline):
            raise TimeoutError(
                f"another liwenjson request was still in progress after {self.timeout}s"
            )
        try:
            self._reject_if_closed()
            return self._exchange(method, params, deadline)
        finally:
            self._lock.release()

    def _take_lock(self, deadline: float) -> bool:
        """Wait for the request lock without waiting past the deadline.

        The lock is polled in short slices because `close()` has to be able to
        end the wait: a request queued behind another one must notice that
        the client is closing instead of sitting there until its deadline.
        """
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            if self._lock.acquire(timeout=min(remaining, 0.05)):
                return True
            with self._state_lock:
                closing = self._closing or self._closed
            if closing:
                raise RuntimeError("liwenjson client is closed")

    def _reject_if_closed(self) -> None:
        with self._state_lock:
            closing = self._closing or self._closed
        if closing:
            raise RuntimeError("liwenjson client is closed")

    def _exchange(self, method: str, params: dict[str, Any], deadline: float) -> Any:
        """Write one request and wait for its answer, on the caller's budget."""
        if self.proc.poll() is not None:
            raise RuntimeError(
                f"liwenjson exited with {self.proc.returncode}; "
                f"stderr: {' | '.join(self._stderr_lines[-3:])}"
            )
        self._next_id += 1
        request_id = self._next_id
        payload: dict[str, Any] = {"id": request_id, "method": method}
        if params:
            payload["params"] = params
        line = json.dumps(payload, ensure_ascii=False) + "\n"

        self._waiting = True
        try:
            self._send(line, method, deadline)
            return self._await(request_id, method, deadline)
        finally:
            self._waiting = False

    def _send(self, line: str, method: str, deadline: float) -> None:
        """Hand the request line to the writer and wait for it to go out."""
        job = _WriteJob(line)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"liwenjson did not accept `{method}` within {self.timeout}s"
            )
        try:
            self._writer_q.put(job, timeout=remaining)
        except queue.Full:
            raise TimeoutError(
                f"liwenjson did not accept `{method}` within {self.timeout}s"
            ) from None
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            self._abandon_write(method)
            raise TimeoutError(
                f"liwenjson did not read `{method}` within {self.timeout}s"
            )
        if not job.done.wait(remaining):
            self._abandon_write(method)
            raise TimeoutError(
                f"liwenjson did not read `{method}` within {self.timeout}s"
            )
        error = self._fatal_error()
        if error is not None:
            raise error
        if job.error is not None:
            raise job.error

    def _abandon_write(self, method: str) -> None:
        """Give up on a write that did not finish.

        The request line may be half written, so the next request would be
        appended to it. The connection is therefore marked unusable and every
        later request fails at once, instead of being answered by a garbled
        exchange.
        """
        self._terminate(
            f"the request `{method}` could not be written: liwenjson stopped "
            "reading its input"
        )

    def _await(self, request_id: int, method: str, deadline: float) -> Any:
        """Wait for this request's answer, or fail at once.

        A broken engine is reported as a broken engine: the reader turns
        every abnormal ending of the stream into one sticky error, so the
        wait ends with that error instead of with a timeout that says nothing
        about the cause.
        """
        while True:
            error = self._fatal_error()
            if error is not None:
                raise error
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._resync()
                raise TimeoutError(
                    f"liwenjson did not answer `{method}` in {self.timeout}s"
                )
            try:
                frame = self._responses.get(timeout=remaining)
            except queue.Empty:
                self._resync()
                raise TimeoutError(
                    f"liwenjson did not answer `{method}` in {self.timeout}s"
                )
            if frame is _TERMINATED:
                error = self._fatal_error()
                raise error or LIWENJSONProtocolError("liwenjson closed the stream")
            if not frame.attributed:
                # An error the engine could not attach to an id: it belongs
                # to the request that is in flight.
                raise self._frame_error(frame.payload)
            if frame.payload.get("id") != request_id:
                # The answer to a request that was abandoned earlier. Dropping
                # it is what keeps a late answer from being read as the answer
                # to this one.
                continue
            if frame.payload.get("ok"):
                return frame.payload["result"]
            raise LIWENJSONError(frame.payload.get("error") or {})

    @staticmethod
    def _frame_error(payload: dict[str, Any]) -> BaseException:
        error = payload.get("error")
        if isinstance(error, dict):
            return LIWENJSONError(error)
        return LIWENJSONProtocolError(
            f"liwenjson wrote an error without a body: {payload!r}"[:200]
        )

    # -- methods ----------------------------------------------------------

    def hello(self) -> dict[str, Any]:
        """Handshake: name, engine version, registry version, protocol, capabilities."""
        return self.request("hello")

    def repair(
        self,
        text: str,
        *,
        profile: str | None = None,
        schema: str | None = None,
        schema_json: Any = None,
        skip_prose: bool | None = None,
        max_loss: str | None = None,
    ) -> dict[str, Any]:
        return self.request("repair", **self._params(text, profile, schema, schema_json, skip_prose, max_loss))

    def analyze(
        self,
        text: str,
        *,
        profile: str | None = None,
        schema: str | None = None,
        schema_json: Any = None,
        skip_prose: bool | None = None,
        max_loss: str | None = None,
        with_text: bool | None = None,
    ) -> dict[str, Any]:
        """The decision plan: `decision`, `executable`, `exactness`, `retry`, ...

        The plan carries `value`, the parsed document. `text`, its rendered form,
        is only present when `with_text=True` is asked for, because sending both
        puts two copies of the document on the wire.
        """
        params = self._params(text, profile, schema, schema_json, skip_prose, max_loss)
        if with_text is not None:
            params["with_text"] = with_text
        return self.request("analyze", **params)

    def validate(
        self,
        text: str,
        *,
        schema: str | None = None,
        schema_json: Any = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        return self.request("validate", **params)

    def readiness(
        self,
        text: str,
        *,
        schema: str | None = None,
        schema_json: Any = None,
        step: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if step is not None:
            params["step"] = step
        return self.request("readiness", **params)

    def watch_start(
        self,
        *,
        schema: str | None = None,
        schema_json: Any = None,
        profile: str | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if profile is not None:
            params["profile"] = profile
        return self.request("watch.start", **params)

    def watch_feed(self, chunk: str) -> dict[str, Any]:
        return self.request("watch.feed", chunk=chunk)

    def watch_finish(self) -> dict[str, Any]:
        return self.request("watch.finish")

    def llm_open(self, provider: str = "anthropic") -> dict[str, Any]:
        return self.request("llm.open", provider=provider)

    def llm_feed(self, event: str) -> dict[str, Any]:
        return self.request("llm.feed", event=event)

    def llm_close(self) -> dict[str, Any]:
        return self.request("llm.close")

    @staticmethod
    def _params(
        text: str,
        profile: str | None,
        schema: str | None,
        schema_json: Any,
        skip_prose: bool | None,
        max_loss: str | None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if profile is not None:
            params["profile"] = profile
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if skip_prose is not None:
            params["skip_prose"] = skip_prose
        if max_loss is not None:
            params["max_loss"] = max_loss
        return params

    # -- lifecycle --------------------------------------------------------

    def close(self) -> None:
        """Stop the engine and reclaim everything it held.

        The order matters. The client is marked closing first, so a request
        that arrives from now on is refused instead of waiting for a process
        that is going away. The shutdown request is a courtesy, not a
        requirement: it is only attempted when the request lock is free, and
        it gets its own short budget. An engine that does not answer, or that
        answers and then lingers, is terminated and then killed, each with an
        explicit deadline, so `close()` always ends.
        """
        with self._close_lock:
            with self._state_lock:
                if self._closed:
                    return
                self._closing = True
            try:
                self._stop_engine()
            finally:
                with self._state_lock:
                    self._closed = True
                stuck = self._join_threads()
                self._close_streams(stuck)

    def _stop_engine(self) -> None:
        proc = self.proc
        if proc.poll() is not None:
            return
        if self._fatal_error() is None and self._lock.acquire(blocking=False):
            try:
                deadline = time.monotonic() + min(self.timeout, _CLOSE_SHUTDOWN_GRACE)
                try:
                    self._exchange("shutdown", {}, deadline)
                except Exception:
                    # The engine did not answer the shutdown; the deadlines
                    # below end it anyway.
                    pass
            finally:
                self._lock.release()
        self._wait_for_exit(_CLOSE_EXIT_GRACE)
        if proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
            self._wait_for_exit(_CLOSE_TERM_GRACE)
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass
            self._wait_for_exit(_CLOSE_KILL_GRACE)

    def _wait_for_exit(self, grace: float) -> None:
        try:
            self.proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass

    def _join_threads(self) -> set[str]:
        """Wait for the reader and the writer to stop.

        The engine is dead by now, so both are unblocked: the reader sees EOF
        and the writer's write fails. The join has a deadline anyway, because
        a thread that does not stop must not hold `close()` open -- and a
        stream whose thread is still running must not be closed underneath it.
        """
        try:
            self._writer_q.put_nowait(None)
        except queue.Full:
            pass
        stuck: set[str] = set()
        threads = (
            ("stdout", self._reader),
            ("stdin", self._writer),
            ("stderr", self._err_reader),
        )
        for name, thread in threads:
            if thread is None:
                continue
            thread.join(timeout=_CLOSE_JOIN_GRACE)
            if thread.is_alive():
                stuck.add(name)
        return stuck

    def _close_streams(self, stuck: set[str]) -> None:
        streams = (
            ("stdin", self.proc.stdin),
            ("stdout", self.proc.stdout),
            ("stderr", self.proc.stderr),
        )
        for name, stream in streams:
            if stream is None or name in stuck:
                continue
            try:
                stream.close()
            except Exception:
                pass

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def __del__(self) -> None:  # pragma: no cover - best effort
        try:
            self.close()
        except Exception:
            pass


def repair(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot repair. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.repair(text, **kwargs)


def analyze(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot analyze. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.analyze(text, **kwargs)


def validate(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot validate. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.validate(text, **kwargs)
