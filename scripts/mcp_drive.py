#!/usr/bin/env python3
"""Drive an Ontomeme MCP server over stdio, the way an MCP client does.

    python3 -I scripts/mcp_drive.py --vault DIR [--timeout SECS] -- COMMAND [ARG...]

COMMAND serves the vault DIR over stdio, e.g. an exported build:
    Ontomeme.x86_64 --headless -- --mcp-stdio --vault=DIR

The driver sends initialize, notifications/initialized, tools/list,
create_note (a UTF-8 title with an emoji), read_note, update_note with the
hash it read, update_note with the old hash (must be refused), delete_note
with the current hash, then closes stdin. It prints one PASS or FAIL line per
step and exits 0 only when every step passed:

- every stdout line is a JSON-RPC 2.0 message (no banner, no logs);
- the title and body round-trip byte-exact;
- the note lands in DIR and, after delete_note, in DIR/.trash/;
- the server exits with code 0 on stdin EOF, within SECS of starting.

Standard library only, so it runs on any CI runner with Python 3.8+.
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

TITLE = "Café 日本 \U0001f9e0"
BODY = "Written by mcp_drive.py ✓ \U0001f680\nline two: \"quoted\" \\ back"
BODY2 = "Updated \U0001f30d\n- a list item"
TOOLS = ["list_notes", "read_note", "create_note", "update_note", "delete_note", "search_notes"]


class Failed(Exception):
    pass


class Server:
    """One server process: JSON-RPC lines in, JSON-RPC lines out."""

    def __init__(self, cmd, deadline):
        self.deadline = deadline
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.lines = queue.Queue()
        self.stdout_lines = 0
        self.not_jsonrpc = []
        self.stderr = bytearray()
        self.next_id = 1
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for raw in self.proc.stdout:
            self.lines.put(raw)
        self.lines.put(None)

    def _read_stderr(self):
        for raw in self.proc.stderr:
            self.stderr.extend(raw)

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False).encode("utf-8") + b"\n")
        self.proc.stdin.flush()

    def request(self, method, params=None):
        """Send a request; return its reply. Every stdout line is checked."""
        msg_id = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": msg_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        while True:
            left = self.deadline - time.monotonic()
            if left <= 0:
                raise Failed("no reply to %s within the time limit" % method)
            try:
                raw = self.lines.get(timeout=left)
            except queue.Empty:
                continue
            if raw is None:
                raise Failed("the server closed stdout before replying to %s (exit %s)" % (method, self.proc.poll()))
            reply = self._parse(raw)
            if reply is not None and reply.get("id") == msg_id:
                return reply

    def _parse(self, raw):
        self.stdout_lines += 1
        try:
            reply = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            reply = None
        if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0":
            self.not_jsonrpc.append(raw[:200])
            raise Failed("stdout line is not a JSON-RPC message: %r" % raw[:200])
        return reply

    def call(self, tool, args):
        """tools/call: (structuredContent, isError)."""
        reply = self.request("tools/call", {"name": tool, "arguments": args})
        if "result" not in reply:
            raise Failed("%s: JSON-RPC error %s" % (tool, reply.get("error")))
        result = reply["result"]
        return result.get("structuredContent", {}), result.get("isError") is True

    def close(self):
        """Close stdin and wait for the exit. Return the exit code, or None."""
        self.proc.stdin.close()
        try:
            return self.proc.wait(timeout=max(0.1, self.deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            return None

    def drain(self):
        """Check whatever the server wrote after its last reply, up to EOF."""
        while True:
            try:
                raw = self.lines.get(timeout=2.0)
            except queue.Empty:
                raise Failed("stdout did not close after the server exited")
            if raw is None:
                return
            self._parse(raw)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def ok(what):
    print("PASS  " + what, flush=True)


def need(cond, what):
    if not cond:
        raise Failed(what)
    ok(what)


def drive(srv, vault, started, limit):
    init = srv.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "mcp_drive", "version": "1"}})
    info = init.get("result", {}).get("serverInfo", {})
    need(init.get("result", {}).get("protocolVersion") == "2025-06-18",
         "initialize: %s %s" % (info.get("name"), info.get("version")))
    srv.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    names = [t.get("name") for t in srv.request("tools/list").get("result", {}).get("tools", [])]
    need(all(t in names for t in TOOLS), "tools/list: %d tools, including %s" % (len(names), ", ".join(TOOLS)))

    made, err = srv.call("create_note", {"title": TITLE, "markdown": BODY})
    path = made.get("path", "")
    need(not err and path and os.path.isfile(os.path.join(vault, path)),
         "create_note: %s is in the vault" % path)

    note, err = srv.call("read_note", {"path": path})
    need(not err and note.get("title", "").encode("utf-8") == TITLE.encode("utf-8")
         and note.get("markdown", "").encode("utf-8") == BODY.encode("utf-8"),
         "read_note: the UTF-8 and emoji title and body round-trip byte-exact")
    first_hash = note.get("hash", "")

    upd, err = srv.call("update_note", {"path": path, "hash": first_hash, "markdown": BODY2})
    again, _ = srv.call("read_note", {"path": path})
    need(not err and upd.get("hash") not in ("", first_hash) and again.get("markdown") == BODY2,
         "update_note with the read hash: the new body is on disk")

    stale, err = srv.call("update_note", {"path": path, "hash": first_hash, "markdown": "stale"})
    need(err and stale.get("error", {}).get("code") == "conflict",
         "update_note with the old hash is refused with code 'conflict'")

    gone, err = srv.call("delete_note", {"path": path, "hash": upd.get("hash", "")})
    trashed = gone.get("trashed_to", "")
    need(not err and trashed.startswith(".trash/") and os.path.isfile(os.path.join(vault, trashed))
         and not os.path.exists(os.path.join(vault, path)),
         "delete_note with the current hash: the file moved to %s" % trashed)

    code = srv.close()
    took = time.monotonic() - started
    need(code == 0, "exit code 0 on stdin EOF, %.1f s after start (limit %d s; got %s)" % (took, limit, code))
    srv.drain()
    need(not srv.not_jsonrpc, "stdout carried only JSON-RPC lines (%d)" % srv.stdout_lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vault", required=True, help="the vault folder COMMAND serves")
    ap.add_argument("--timeout", type=float, default=20.0, help="seconds from start to exit (default 20)")
    ap.add_argument("command", nargs=argparse.REMAINDER, help="-- COMMAND [ARG...]")
    opts = ap.parse_args()
    cmd = opts.command[1:] if opts.command[:1] == ["--"] else opts.command
    if not cmd:
        ap.error("give the server command after --")
    started = time.monotonic()
    srv = Server(cmd, started + opts.timeout)
    try:
        drive(srv, os.path.abspath(opts.vault), started, opts.timeout)
    except Failed as e:
        print("FAIL  " + str(e), flush=True)
        srv.kill()
        tail = bytes(srv.stderr).decode("utf-8", "replace").strip().splitlines()[-8:]
        for line in tail:
            print("      stderr: " + line)
        return 1
    finally:
        srv.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
