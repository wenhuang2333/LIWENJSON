// Low level stdio for the CLI. The toolchain runtime does not expose a file
// API, so the CLI talks to libc/stdio directly; the package is therefore
// restricted to the native backend (see `moon.pkg`).

///|
extern "C" fn ffi_is_null(p : Int64) -> Int32 = "moonbit_is_null"

///|
extern "C" fn ffi_fclose(f : Int64) -> Int32 = "moonbit_fclose_ffi"

///|
extern "C" fn ffi_fflush(f : Int64) -> Int32 = "fflush"

///|
extern "C" fn ffi_exit(code : Int32) -> Unit = "exit"

///|
#borrow(mode)
extern "C" fn ffi_fdopen(fd : Int32, mode : Bytes) -> Int64 = "fdopen"

///|
#borrow(path, mode)
extern "C" fn ffi_fopen(path : Bytes, mode : Bytes) -> Int64 = "moonbit_fopen_ffi"

///|
/// Windows: the CRT hands out stdio streams in *text* mode. Text mode rewrites
/// every `\n` the CLI writes into `\r\n`, and makes `0x1A` in the input an
/// end-of-file marker, which silently truncates a document that contains it.
/// Both are wrong for a byte-oriented tool, so both standard streams are
/// switched to binary before they are opened. `0x8000` is `_O_BINARY`; the
/// call is idempotent and harmless when it fails.
#cfg(all(target="native", platform="windows"))
extern "C" fn ffi_setmode(fd : Int32, mode : Int32) -> Int32 = "_setmode"

///|
/// Windows: open by UTF-16 path. Narrow `fopen` reads the path bytes in the
/// ANSI code page, so every file name outside ASCII (Chinese, for one) fails
/// with ENOENT; `_wopen` takes the UTF-16 path the runtime already holds.
/// `0x8000` is `_O_BINARY`, `0` the unused `pmode` of `_O_RDONLY`.
#cfg(all(target="native", platform="windows"))
#borrow(path)
extern "C" fn ffi_wopen(path : String, oflag : Int32, pmode : Int32) -> Int32 = "_wopen"

///|
/// Windows: whether `fd` is a console. The output code page below only means
/// anything for a console; a pipe carries bytes and is left alone.
#cfg(all(target="native", platform="windows"))
extern "C" fn ffi_isatty(fd : Int32) -> Int32 = "_isatty"

///|
/// Windows: the code page the console decodes bytes written to it by. It
/// defaults to the ANSI code page (936 on a Chinese system), while everything
/// the CLI prints is UTF-8, so `--help` arrives as mojibake until the console
/// is told what the bytes are. `65001` is `CP_UTF8`.
#cfg(all(target="native", platform="windows"))
extern "C" fn ffi_set_console_cp(cp : Int32) -> Int32 = "SetConsoleOutputCP"

///|
/// Put both standard streams into binary mode, and tell the console that the
/// bytes it is about to receive are UTF-8. Called once from `main`, before any
/// stream is opened, so no code path can miss it.
#cfg(all(target="native", platform="windows"))
fn binary_std_streams() -> Unit {
  ignore(ffi_setmode(0, 0x8000))
  ignore(ffi_setmode(1, 0x8000))
  if ffi_isatty(1) != 0 {
    ignore(ffi_set_console_cp(65001))
  }
}

///|
/// Nothing to do where stdio is already byte-oriented.
#cfg(not(all(target="native", platform="windows")))
fn binary_std_streams() -> Unit {

}

///|
/// Windows: the path `_wopen` should receive. Forward slashes are accepted by
/// `_wopen` only in short paths, so they are normalized; past 260 characters
/// the ANSI APIs refuse the path unless it carries the `\\?\` prefix, which
/// turns off every Win32 path rule (hence only absolute, already normalized
/// paths are prefixed — a relative one has no meaning under that prefix).
#cfg(all(target="native", platform="windows"))
fn wide_path(path : String) -> String {
  let back = path.replace_all(old="/", new="\\")
  let prefixed = back.has_prefix("\\\\?\\")
  let drive = match back.get_char(1) {
    Some(c) => c == ':' && back.get_char(0) is Some(_)
    None => false
  }
  if (prefixed || drive) && back.length() >= 248 {
    "\\\\?\\" + back
  } else {
    back
  }
}

///|
/// The named file on Windows: opened by wide path, then wrapped in a stdio
/// stream so the rest of the CLI keeps seeing a `FILE*`. A `_wfopen` would be
/// the shorter way there, but `fdopen` is the call the other platforms already
/// use and the fd is in binary mode as soon as `_wopen` returns.
#cfg(all(target="native", platform="windows"))
fn open_path(path : String) -> Int64 {
  let fd = ffi_wopen(wide_path(path), 0x8000, 0)
  if fd < 0 {
    return 0L
  }
  let f = ffi_fdopen(fd, b"rb")
  if ffi_is_null(f) != 0 {
    0L
  } else {
    f
  }
}

///|
/// The named file elsewhere: `moonbit_fopen_ffi` is the runtime's `fopen`.
#cfg(not(all(target="native", platform="windows")))
fn open_path(path : String) -> Int64 {
  let f = ffi_fopen(@utf8.encode(path), b"rb")
  if ffi_is_null(f) != 0 {
    0L
  } else {
    f
  }
}

///|
/// Bulk read into a `Bytes` buffer. `moonbit_fread_ffi` is provided by the
/// toolchain runtime, so no C header of our own is needed.
#borrow(buf)
extern "C" fn ffi_fread(
  buf : Bytes,
  size : Int32,
  nitems : Int32,
  f : Int64,
) -> Int64 = "moonbit_fread_ffi"

///|
/// The named file, or standard input when `path` is `None`, as a stdio
/// stream. `0L` means the input could not be opened.
fn open_input(path : String?) -> Int64 {
  match path {
    Some(p) => open_path(p)
    None => {
      let f = ffi_fdopen(0, b"rb")
      if ffi_is_null(f) != 0 {
        0L
      } else {
        f
      }
    }
  }
}

///|
/// The next piece of the stream, at most `cap` bytes; empty at end of stream.
/// One `fread` per chunk: reading byte by byte through `fgetc` capped the CLI
/// at roughly 25 MB/s no matter how fast the engine was.
fn read_chunk(f : Int64, cap : Int32) -> Bytes {
  let buf = Bytes::make(cap, b'\x00')
  let n = ffi_fread(buf, 1, cap, f)
  if n <= 0L {
    Bytes::make(0, b'\x00')
  } else {
    Bytes::makei(n.to_int(), i => buf[i])
  }
}

///|
/// Bulk write of a byte buffer. `fwrite` is used rather than the runtime's
/// `println`, whose output is buffered until the process exits: a line
/// protocol has to reach the reader while the process is still running.
#borrow(buf)
extern "C" fn ffi_fwrite(
  buf : Bytes,
  size : Int32,
  nitems : Int32,
  f : Int64,
) -> Int64 = "moonbit_fwrite_ffi"

///|
/// Standard output as its own stdio stream. `0L` when it cannot be opened.
///
/// The protocol writers use this instead of `println` so that one line is
/// flushed per response; `println`'s buffer is only flushed at exit, which
/// deadlocks an interactive client.
fn open_output() -> Int64 {
  let f = ffi_fdopen(1, b"wb")
  if ffi_is_null(f) != 0 {
    0L
  } else {
    f
  }
}

///|
/// Exit code of a failed standard output stream.
///
/// The output stream is part of the interface: a line that never reached the
/// reader is not a success, whatever the exit code used to be. 70 is the
/// documented "internal error" code and no engine error is involved, so it is
/// the one that says "the program, not the document, failed".
const IO_ERROR_EXIT : Int32 = 70

///|
/// Checked bulk write: true only when every byte was accepted by `fwrite` and
/// the stream was flushed. `fwrite` is allowed to return a short count when the
/// reader went away, and `fflush` reports the write error of the buffer, so
/// both have to be looked at; the old code discarded both return values.
fn write_bytes_checked(f : Int64, bytes : Bytes) -> Bool {
  if f == 0L {
    return false
  }
  let n = ffi_fwrite(bytes, 1, bytes.length(), f)
  if n < 0L || n.to_int() != bytes.length() {
    return false
  }
  ffi_fflush(f) == 0
}

///|
/// Write one line (the trailing LF included) and flush it, reporting whether
/// the reader actually received it.
fn write_line_checked(f : Int64, line : String) -> Bool {
  write_bytes_checked(f, @utf8.encode(line + "\n"))
}

///|
/// Write one line or leave with a diagnostic and a non-zero status. Used by the
/// one-shot and batch paths, which must not report success when stdout is gone.
fn write_line_or_exit(f : Int64, line : String) -> Unit {
  if write_line_checked(f, line) {
    return
  }
  eprintln("liwenjson: cannot write to stdout")
  quit(IO_ERROR_EXIT)
}

///|
/// Write one protocol line and flush it. Kept as the fire-and-forget form the
/// long-lived protocol loops use; the one-shot paths call the checked variant.
fn write_line(f : Int64, line : String) -> Unit {
  ignore(write_line_checked(f, line))
}

///|
/// Read one byte from `f` into the one-byte buffer `buf`; `-1` at end of stream
/// or on error. Reading a byte at a time is what makes a line protocol answer
/// before the producer closes its end: a block read would wait for a full
/// buffer.
fn read_byte(f : Int64, buf : Bytes) -> Int32 {
  let n = ffi_fread(buf, 1, 1, f)
  if n <= 0L {
    -1
  } else {
    buf[0].to_char().to_int()
  }
}

///|
/// Close a stream opened by `open_input`.
fn close_input(f : Int64) -> Unit {
  ignore(ffi_fclose(f))
}

///|
/// Flush stdio and leave with `code`.
fn quit(code : Int32) -> Unit {
  ignore(ffi_fflush(0L))
  ffi_exit(code)
}

///|
/// `signal` from libc. `SIG_IGN` is the value 1 on every POSIX target; the
/// declared signature is looser than the C one on purpose, because the toolchain
/// runtime has no signal binding and the ABI (an int and a pointer-width word)
/// is the same.
extern "C" fn ffi_signal(sig : Int32, handler : Int64) -> Int64 = "signal"

///|
/// Ignore `SIGPIPE` (13 on every POSIX target) so that a reader which closed
/// the pipe becomes a write error the checked writers report, instead of a
/// signal that kills the process before it can say anything. On platforms
/// without `SIGPIPE` the call fails harmlessly.
fn ignore_sigpipe() -> Unit {
  ignore(ffi_signal(13, 1L))
}
