#!/usr/bin/env python3
"""Run a credential-free Maki TUI smoke test in an isolated HOME."""

import argparse
import fcntl
import http.server
import json
import termios
import threading
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import time


def wait_for_output(process, fd, log, predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"maki exited early with status {process.returncode}")
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data)
        log.flush()
        if predicate(data):
            return
    raise TimeoutError("timed out waiting for Maki output")


def settle(process, fd, log, seconds=1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"maki exited early with status {process.returncode}")
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if data:
                log.write(data)
                log.flush()


def send(fd, text):
    os.write(fd, text.encode())


def resize(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def start_ollama_mock():
    class Handler(http.server.BaseHTTPRequestHandler):
        def respond(self, payload):
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/v1/models":
                self.respond({"data": [{"id": "llama3.2"}]})
            elif self.path == "/api/ps":
                self.respond({"models": []})
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/api/show":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            self.rfile.read(length)
            self.respond({"capabilities": ["completion", "tools"], "model_info": {}, "parameters": ""})

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server.server_address[1]


def dump_view(process, fd, log, dump_path, next_index):
    dump_path.unlink(missing_ok=True)
    send(fd, "\x07")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        settle(process, fd, log, 0.2)
        if dump_path.exists():
            try:
                data = json.loads(dump_path.read_text())
            except json.JSONDecodeError:
                continue
            if data["index"] == next_index:
                return data
    raise TimeoutError(f"viewport dump {next_index} did not arrive")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--maki", required=True, type=Path)
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--mode", choices=["exact", "fallback"], required=True)
    args = parser.parse_args()

    binary = args.maki.resolve()
    package = args.package.resolve()
    work = args.work.resolve()
    if work.exists():
        shutil.rmtree(work)
    home = work / "home"
    project = work / "project"
    config = home / ".config" / "maki"
    data = home / ".local" / "share" / "maki"
    dump_path = work / "view.json"
    log_path = work / f"{args.mode}-tui.log"
    for directory in [home, project, config, data]:
        directory.mkdir(parents=True, exist_ok=True)

    plugin_dir = data / "site" / "pack" / "local" / "start" / "maki-minimap"
    plugin_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(package, plugin_dir, ignore=shutil.ignore_patterns(".git", ".jj", ".upstream", ".tools", ".test-home", "target"))
    if args.mode == "fallback":
        (plugin_dir / "plugin" / "minimap.lua").write_text(
            'require("minimap").setup({ exact = false })\n'
        )

    messages = []
    for turn in range(1, 31):
        messages.append({
            "role": "user",
            "kind": "turn",
            "display_text": f"synthetic prompt {turn}",
            "content": [{"type": "text", "text": f"synthetic prompt {turn}"}],
        })
        answer = "\n".join(f"answer {turn} line {line}" for line in range(1, 9))
        messages.append({
            "role": "assistant",
            "kind": "turn",
            "content": [{"type": "text", "text": answer}],
        })
    transcript = work / "transcript.json"
    transcript.write_text(json.dumps({
        "title": "minimap smoke",
        "model": "ollama/llama3.2",
        "messages": messages,
    }))

    ollama_port = start_ollama_mock()
    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "NO_COLOR": "1",
        "OLLAMA_HOST": f"http://127.0.0.1:{ollama_port}",
    })
    imported = subprocess.run(
        [str(binary), "session", "import", str(transcript)],
        cwd=project,
        env=env,
        text=True,
        capture_output=True,
        check=True,
        timeout=60,
    )
    session_id = imported.stdout.strip().split()[-1]

    lua_path = str(dump_path).replace("\\", "\\\\").replace('"', '\\"')
    (config / "init.lua").write_text(f'''
local dump_count = 0
local function dump_view()
  dump_count = dump_count + 1
  local anchors = {{}}
  if maki.fn.transcript_anchors then
    anchors = maki.fn.transcript_anchors()
  end
  local input = maki.ui.input()
  local view = maki.fn.winsaveview()
  local ok, err = maki.fs.write("{lua_path}", maki.json.encode({{
    index = dump_count,
    view = view,
    anchors = anchors,
    input = input,
    mode = maki.fn.mode(),
  }}))
  assert(ok, err)
end
maki.keymap.set({{ "n", "i" }}, "<C-g>", dump_view, {{ desc = "Write minimap smoke-test state" }})
maki.keymap.set({{ "n", "i" }}, "<F6>", function()
  local ok, err = maki.api.run_command("/reload")
  assert(ok, err)
end, {{ desc = "Reload minimap smoke-test plugins" }})
''')
    (config / "plugin.toml").write_text("[permissions]\nsession_read = true\nfs_write = true\n")

    controller, follower = pty.openpty()
    resize(follower, 100, 30)
    process = subprocess.Popen(
        [str(binary), "--model", "ollama/llama3.2", "--resume", session_id],
        cwd=project,
        env=env,
        stdin=follower,
        stdout=follower,
        stderr=follower,
        close_fds=True,
    )
    os.close(follower)
    checks = []
    with log_path.open("wb") as log:
        try:
            settle(process, fd=controller, log=log, seconds=4)
            send(controller, "\r")
            settle(process, fd=controller, log=log, seconds=2)
            first = dump_view(process, controller, log, dump_path, 1)
            assert first["view"]["topline"] >= 1
            checks.append("load and initial viewport")

            send(controller, "/minimap\r")
            settle(process, controller, log, 0.5)
            send(controller, "/minimap\r")
            settle(process, controller, log, 0.5)
            checks.append("slash toggle")

            send(controller, "/minimap-prev\r")
            settle(process, controller, log, 0.5)
            older = dump_view(process, controller, log, dump_path, 2)
            if args.mode == "exact":
                view = older["view"]
                last_topline = max(1, view["line_count"] - view["height"] + 1)
                valid_toplines = {
                    min(max(anchor["topline"], 1), last_topline)
                    for anchor in older["anchors"]
                    if anchor["role"] == "user"
                }
                assert view["topline"] in valid_toplines, (view, valid_toplines)
                checks.append("exact user-anchor target")
            send(controller, "\x1bp")
            settle(process, controller, log, 0.5)
            oldest = dump_view(process, controller, log, dump_path, 3)
            assert oldest["view"]["topline"] < older["view"]["topline"], (oldest, older)
            assert not oldest["view"]["auto_scroll"]
            checks.append("previous navigation and unpinning")

            send(controller, "\x1bn")
            settle(process, controller, log, 0.5)
            forward = dump_view(process, controller, log, dump_path, 4)
            assert forward["view"]["topline"] == older["view"]["topline"], (forward, older)
            checks.append("next navigation restores the prior prompt")

            send(controller, "draft preserved")
            send(controller, "\x1bm")
            settle(process, controller, log, 0.8)
            toggled_off = dump_view(process, controller, log, dump_path, 5)
            assert toggled_off["input"]["text"] == "draft preserved"
            assert toggled_off["mode"] == "i"
            send(controller, "\x1bm")
            settle(process, controller, log, 0.8)
            toggled_on = dump_view(process, controller, log, dump_path, 6)
            assert toggled_on["input"]["text"] == "draft preserved"
            assert toggled_on["mode"] == "i"
            checks.append("toggle key preserves draft and input focus")

            resize(controller, 72, 24)
            settle(process, controller, log, 1.2)
            resized = dump_view(process, controller, log, dump_path, 7)
            assert resized["view"]["width"] < forward["view"]["width"]
            checks.append("resize and exact layout refresh")

            send(controller, "\x1b[17~")
            settle(process, controller, log, 4)
            reloaded = dump_view(process, controller, log, dump_path, 1)
            assert reloaded["view"]["topline"] >= 1
            checks.append("plugin reload")

            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            os.close(controller)

    log_text = log_path.read_text(errors="replace")
    assert "●" in log_text and "▐" in log_text, "minimap rail glyphs were not painted"
    assert "plugin callback failed" not in log_text
    assert "permission denied" not in log_text
    checks.append("rail glyphs and no plugin errors")

    print(f"{args.mode}: " + ", ".join(checks))
    print(f"log: {log_path}")


if __name__ == "__main__":
    main()
