#!/usr/bin/env python3
"""
ACP Orchestrator — Spawns coding agents via Agent Client Protocol (JSON-RPC 2.0).

Manages the full lifecycle of a single agent session:
  spawn adapter → drain startup → session/new → session/prompt → stream → done

Supports three backends: codex, claude, gemini.

Jerry acts as the orchestrator layer above this — picking which backend to use
and monitoring progress via status files.

Usage:
    python3 acp_orchestrator.py --backend codex --model gpt-5.3-codex \
        --worktree /path/to/worktree --prompt-file .foundry-prompt.md \
        --log-file /path/to/log --done-file /path/to/done \
        --timeout 1800
"""

import argparse
import asyncio
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# Seconds to wait for non-JSON startup output to drain before first JSON-RPC call.
STARTUP_DRAIN_TIMEOUT = 10

# ACP adapter binaries per backend (legacy direct mode)
ACP_ADAPTERS = {
    "claude": "claude-agent-acp",
    "codex": "codex-acp",
    "gemini": "gemini",  # Gemini CLI has native ACP support
}

# OpenClaw gateway password file for native ACPX mode
_OC_PW_FILE = Path.home() / ".openclaw" / ".gw-password"


def get_adapter_args(backend: str, model: str, worktree: str, task_id: str = "") -> list[str]:
    """Build command-line args for the ACP adapter.

    Native mode (FOUNDRY_USE_NATIVE=true): routes through OpenClaw gateway.
    The gateway manages the session, tracks tokens, enables steer/ask/status.

    Legacy mode: starts the agent binary directly (codex-acp, claude-agent-acp).
    """
    use_native = os.environ.get("FOUNDRY_USE_NATIVE", "true")

    if use_native == "true" and _OC_PW_FILE.exists():
        session_key = f"agent:main:acp:foundry-{task_id}" if task_id else "agent:main:acp:foundry"
        return [
            "openclaw", "acp",
            "--session", session_key,
            "--password-file", str(_OC_PW_FILE),
            "--no-prefix-cwd",
        ]

    # Legacy: direct adapter binary
    match backend:
        case "codex":
            return [
                ACP_ADAPTERS["codex"],
                "-c", f'model="{model}"',
                "-c", 'sandbox_mode="danger-full-access"',
            ]
        case "gemini":
            return [ACP_ADAPTERS["gemini"], "--experimental-acp", "--model", model]
        case _:  # claude
            return [ACP_ADAPTERS["claude"], "--model", model]


class ACPOrchestrator:
    """Manages a single agent session via ACP JSON-RPC 2.0."""

    def __init__(
        self,
        backend: str,
        model: str,
        worktree: str,
        prompt_file: str,
        log_file: str,
        done_file: str,
        timeout: int = 1800,
        env_vars: dict | None = None,
        foundry_dir: str | None = None,
    ):
        self.backend = backend
        self.model = model
        self.worktree = worktree
        self.prompt_file = prompt_file
        self.log_file = log_file
        self.done_file = done_file
        self.timeout = timeout
        self.env_vars = env_vars or {}
        self.foundry_dir = foundry_dir or os.environ.get(
            "FOUNDRY_DIR",
            os.path.expanduser("~/.openclaw/workspace/scripts/foundry"),
        )
        self.process: asyncio.subprocess.Process | None = None
        self._request_id = 0
        self._log_fh = None
        self._session_id: str | None = None
        self._steer_pending = False
        self._stdout_reader: asyncio.StreamReader | None = None
        # Status tracking for Jerry's peek command
        self._tools_used: list[str] = []
        self._files_modified = 0
        self._last_tool: str | None = None
        self._phase = "starting"
        self._error: str | None = None

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def _log(self, msg: str):
        """Write to both log file and stderr."""
        line = f"[acp-orchestrator] {msg}\n"
        sys.stderr.write(line)
        if self._log_fh:
            self._log_fh.write(line)
            self._log_fh.flush()

    def _setup_steer_handler(self):
        """Register USR1 signal handler for steer file mechanism."""
        def _on_usr1(signum, frame):
            self._steer_pending = True
        signal.signal(signal.SIGUSR1, _on_usr1)

    def _get_steer_file(self) -> Path:
        """Path to the steer file for this task."""
        return Path(self.done_file).with_suffix(".steer")

    def _get_status_file(self) -> Path:
        """Path to the status file for this task."""
        return Path(self.done_file).with_suffix(".status.json")

    @staticmethod
    def _detect_phase(tool_name: str) -> str | None:
        """Infer agent phase from tool name. Returns None if no phase change."""
        name_lower = tool_name.lower()
        if "gh" in name_lower and "pr" in name_lower:
            return "pr"
        if name_lower in ("bash",):
            return None  # Bash is ambiguous — don't change phase
        if any(k in name_lower for k in ("test", "lint", "check")):
            return "testing"
        if "git" in name_lower and any(k in name_lower for k in ("commit", "push")):
            return "committing"
        if name_lower in ("edit", "write", "read", "glob", "grep"):
            return "coding"
        return None

    def _write_status(self):
        """Write structured status JSON for Jerry's peek command."""
        status = {
            "phase": self._phase,
            "tools_used": sorted(set(self._tools_used)),
            "files_modified": self._files_modified,
            "last_tool": self._last_tool,
            "last_activity_ts": int(time.time()),
            "error": self._error,
        }
        try:
            self._get_status_file().write_text(json.dumps(status))
        except OSError:
            pass  # Non-critical — don't crash the agent

    async def _consume_steer(self) -> str:
        """Read and consume the steer file, returning the message (or empty string)."""
        self._steer_pending = False
        steer_file = self._get_steer_file()
        if not steer_file.exists():
            return ""
        steer_msg = steer_file.read_text().strip()
        steer_file.unlink(missing_ok=True)
        return steer_msg

    async def _check_and_send_steer(self):
        """If a steer file exists and we got USR1, send it as a follow-up prompt."""
        if not self._steer_pending:
            return
        steer_msg = await self._consume_steer()
        if steer_msg and self._session_id:
            self._log(f"Sending steer: {steer_msg[:80]}...")
            try:
                await self._send_request("session/prompt", {
                    "sessionId": self._session_id,
                    "prompt": [{"type": "text", "text": steer_msg}],
                })
            except Exception as e:
                self._log(f"Steer failed: {e}")

    async def _drain_startup(self):
        """Read and discard non-JSON startup output from the adapter.

        Some adapters (notably openclaw) print banners, doctor warnings, or
        a "[acp] ready" marker to stdout before entering JSON-RPC mode.
        We must drain these before sending any JSON-RPC request.
        """
        self._log("Draining adapter startup output...")
        deadline = time.monotonic() + STARTUP_DRAIN_TIMEOUT

        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            try:
                line = await asyncio.wait_for(self._read_line(), timeout=remaining)
            except asyncio.TimeoutError:
                break  # No more startup output — adapter is ready
            if not line:
                continue

            # If the line is valid JSON, it's an early notification — put it back
            # by handling it (don't discard real protocol messages)
            try:
                msg = json.loads(line)
                # Valid JSON — this is a real ACP message, handle it
                await self._handle_message(msg)
                continue
            except (json.JSONDecodeError, ValueError):
                pass  # Not JSON — startup banner, discard

            # Log the discarded line for debugging
            if self._log_fh:
                self._log_fh.write(f"[startup] {line}\n")
                self._log_fh.flush()

            # "[acp] ready" is the definitive signal from --verbose adapters
            if "[acp] ready" in line:
                self._log("Adapter ready (received [acp] ready)")
                return

        self._log("Startup drain complete (timeout or empty)")

    async def _send_notification(self, method: str, params: dict | None = None):
        """Send a JSON-RPC 2.0 notification (no id, no response expected)."""
        notif: dict = {"jsonrpc": "2.0", "method": method}
        if params:
            notif["params"] = params
        payload = json.dumps(notif) + "\n"
        try:
            self.process.stdin.write(payload.encode())
            await self.process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # Best-effort — if pipe is dead, cancel is moot

    async def _send_request(self, method: str, params: dict | None = None) -> dict:
        """Send a JSON-RPC 2.0 request and read the response."""
        req = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
        }
        if params:
            req["params"] = params

        req_id = req["id"]
        payload = json.dumps(req) + "\n"
        try:
            self.process.stdin.write(payload.encode())
            await self.process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            rc = self.process.returncode
            raise ConnectionError(
                f"ACP adapter stdin closed (rc={rc}): {type(e).__name__}: {e}"
            ) from e

        # Track whether we already sent a cancel for this request
        cancel_sent = False

        # Read response (may be preceded by notifications and agent→client requests)
        while True:
            # Mid-turn steer: if USR1 arrived during a session/prompt, cancel the turn
            # so the steer loop can re-prompt with the new direction.
            if (self._steer_pending and not cancel_sent
                    and method == "session/prompt"):
                self._log("Steer received mid-turn — sending session/cancel...")
                await self._send_notification("session/cancel")
                cancel_sent = True

            line = await asyncio.wait_for(
                self._read_line(), timeout=self.timeout
            )
            if not line:
                raise ConnectionError("ACP adapter closed unexpectedly")

            # Skip non-JSON lines (late startup output, debug prints)
            try:
                msg = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                if self._log_fh:
                    self._log_fh.write(f"[skipped] {line}\n")
                    self._log_fh.flush()
                continue

            # Our response: matching id with result/error
            if msg.get("id") == req_id and ("result" in msg or "error" in msg):
                return msg

            # Notification (no id) or agent→client request (different id)
            try:
                await self._handle_message(msg)
            except Exception as e:
                sys.stderr.write(f"[acp-orchestrator] Warning: handler error: {e}\n")
            continue

    async def _read_line(self) -> str:
        """Read a line from the subprocess stdout via asyncio.StreamReader.

        Uses native async I/O — no executor threads. Cancellation actually
        stops the read (unlike run_in_executor which leaks a blocking thread).
        """
        line = await self._stdout_reader.readline()
        return line.decode().strip() if line else ""

    async def _handle_message(self, msg: dict):
        """Handle any ACP message (notification or agent→client request)."""
        method = msg.get("method", "")
        params = msg.get("params", {})
        msg_id = msg.get("id")  # Present for requests (need response), absent for notifications

        if method == "session/update":
            self._handle_session_update(params)
        elif method == "session/request_permission":
            # Agent asks permission to use a tool — auto-approve with allow_always
            tool_call = params.get("toolCall", {})
            tool_name = tool_call.get("title", "") or tool_call.get("kind", "unknown") if isinstance(tool_call, dict) else "unknown"
            options = params.get("options", [])
            # Find allow_always option, fall back to allow_once, then first option
            chosen_id = None
            for opt in options:
                if opt.get("kind") == "allow_always":
                    chosen_id = opt.get("optionId")
                    break
            if not chosen_id:
                for opt in options:
                    if opt.get("kind") == "allow_once":
                        chosen_id = opt.get("optionId")
                        break
            if not chosen_id and options:
                chosen_id = options[0].get("optionId", "")
            if msg_id is not None and chosen_id:
                await self._send_response(msg_id, {
                    "outcome": {"outcome": "selected", "optionId": chosen_id}
                })
            if self._log_fh:
                self._log_fh.write(f"[acp] Auto-approved: {tool_name}\n")
                self._log_fh.flush()
        elif method == "session/finished":
            pass  # Handled in run loop
        elif method == "session/output":
            # Legacy: some adapters might use this
            text = params.get("text", "")
            if text and self._log_fh:
                self._log_fh.write(text)
                self._log_fh.flush()
        else:
            # Unknown method — log it and auto-respond if it's a request
            if self._log_fh:
                self._log_fh.write(f"[acp] {method}: {json.dumps(params)[:300]}\n")
                self._log_fh.flush()
            if msg_id is not None:
                await self._send_response(msg_id, {})

    def _handle_session_update(self, params: dict):
        """Extract readable content from session/update notifications."""
        update = params.get("update", {})
        if not isinstance(update, dict):
            return
        update_type = update.get("sessionUpdate", "")

        if update_type == "agent_message_chunk":
            text = update.get("content", "")
            if isinstance(text, str) and text and self._log_fh:
                self._log_fh.write(text)
                self._log_fh.flush()
        elif update_type == "tool_call":
            name = update.get("name", "")
            if name:
                if self._log_fh:
                    self._log_fh.write(f"\n[tool] {name}\n")
                    self._log_fh.flush()
                # Track for status file
                self._last_tool = name
                if name not in self._tools_used:
                    self._tools_used.append(name)
                if name in ("Edit", "Write", "NotebookEdit"):
                    self._files_modified += 1
                phase = self._detect_phase(name)
                if phase:
                    self._phase = phase
                self._write_status()
        elif update_type == "tool_call_update":
            content = update.get("content", "")
            if content and self._log_fh:
                text = content if isinstance(content, str) else json.dumps(content)[:500]
                self._log_fh.write(text + "\n")
                self._log_fh.flush()
        elif update_type in ("plan", "available_commands_update", "usage_update"):
            pass  # Informational, skip
        elif self._log_fh:
            self._log_fh.write(f"[acp] update/{update_type}: {str(update)[:200]}\n")
            self._log_fh.flush()

    async def _send_response(self, msg_id, result: dict):
        """Send a JSON-RPC response to an agent→client request."""
        resp = {"jsonrpc": "2.0", "id": msg_id, "result": result}
        payload = json.dumps(resp) + "\n"
        self.process.stdin.write(payload.encode())
        await self.process.stdin.drain()

    async def run(self) -> int:
        """Execute the agent and return exit code."""
        # Derive task_id from done_file path (e.g., logs/aura-shopify-issue-946.done → aura-shopify-issue-946)
        task_id = Path(self.done_file).stem if self.done_file else ""
        adapter_cmd = get_adapter_args(self.backend, self.model, self.worktree, task_id)

        # Merge environment
        env = os.environ.copy()
        env.update(self.env_vars)

        # Read prompt
        prompt_path = Path(self.worktree) / self.prompt_file
        if not prompt_path.exists():
            self._log(f"Prompt file not found: {prompt_path}")
            return 1
        prompt = prompt_path.read_text()

        self._log(f"Starting ACP adapter: {' '.join(adapter_cmd)}")
        self._log(f"Backend: {self.backend}, Model: {self.model}")
        self._log(f"Worktree: {self.worktree}")
        self._log(f"Timeout: {self.timeout}s")

        # Setup steer signal handler
        self._setup_steer_handler()

        self._log_fh = open(self.log_file, "w")

        try:
            self.process = await asyncio.create_subprocess_exec(
                *adapter_cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.worktree,
                env=env,
                limit=16 * 1024 * 1024,  # 16MB — ACP responses can be large (tool outputs, diffs)
            )
            self._stdout_reader = self.process.stdout

            self._log(f"ACP adapter PID: {self.process.pid}")

            # Write PID file for liveness checks
            pid_file = Path(self.done_file).with_suffix(".pid")
            pid_file.write_text(str(self.process.pid))

            # Drain non-JSON startup output (banners, doctor warnings, [acp] ready)
            await self._drain_startup()

            # Initialize session
            init_resp = await self._send_request("session/new", {
                "cwd": self.worktree,
                "mcpServers": [],
            })
            if "error" in init_resp:
                self._log(f"Session init failed: {init_resp['error']}")
                return 1

            self._session_id = init_resp.get("result", {}).get("sessionId", "default")
            self._log(f"Session created: {self._session_id}")

            # Send prompt — this blocks until the turn completes,
            # handling all session/update notifications and agent→client
            # requests (like session/request_permission) along the way
            self._log("Sending prompt to agent...")
            prompt_resp = await self._send_request("session/prompt", {
                "sessionId": self._session_id,
                "prompt": [{"type": "text", "text": prompt}],
            })

            exit_code = 0
            if "error" in prompt_resp:
                self._log(f"Prompt failed: {prompt_resp['error']}")
                self._error = str(prompt_resp["error"])
                exit_code = 1
            else:
                stop_reason = prompt_resp.get("result", {}).get("stopReason", "end_turn")
                self._log(f"\nAgent finished (stopReason: {stop_reason})")
                if stop_reason == "refusal":
                    exit_code = 1
                elif stop_reason == "cancelled" and self._steer_pending:
                    # Turn was cancelled by our mid-turn steer — not an error,
                    # the steer loop below will re-prompt with the new direction
                    self._log("Turn cancelled for mid-turn steer redirect")
                elif stop_reason == "cancelled":
                    exit_code = 1  # Cancelled without steer = real cancellation

            # Steer loop: after each turn (or mid-turn cancel), check for pending steers
            # and send as follow-up prompts. Agent keeps full context from prior turns.
            while self._steer_pending:
                steer_msg = await self._consume_steer()
                if not steer_msg:
                    break  # Signal fired but no steer file — spurious
                if steer_msg:
                    self._log(f"Sending steer: {steer_msg[:100]}...")
                    prompt_resp = await self._send_request("session/prompt", {
                        "sessionId": self._session_id,
                        "prompt": [{"type": "text", "text": steer_msg}],
                    })
                    if "error" in prompt_resp:
                        self._log(f"Steer prompt failed: {prompt_resp['error']}")
                        break
                    stop_reason = prompt_resp.get("result", {}).get("stopReason", "end_turn")
                    self._log(f"\nAgent finished after steer (stopReason: {stop_reason})")
                    if stop_reason == "refusal":
                        exit_code = 1
                        break
                    elif stop_reason == "cancelled" and self._steer_pending:
                        # Another steer arrived during this steer turn — loop continues
                        self._log("Steer turn cancelled by newer steer")
                    elif stop_reason == "cancelled":
                        exit_code = 1
                        break

            self._phase = "done" if exit_code == 0 else "failed"
            self._write_status()
            self._log("Phase set, cleaning up adapter process...")

            # Shut down the adapter process.
            # openclaw acp (Node.js) keeps a WebSocket to the gateway and may
            # ignore SIGTERM. Close pipes first (unblocks process.wait), then
            # terminate/kill.
            if self.process.returncode is None:
                self._log("Closing adapter pipes...")
                if self.process.stdin and not self.process.stdin.is_closing():
                    self.process.stdin.close()
                # Drain remaining stdout/stderr to prevent pipe buffer deadlock
                try:
                    if self.process.stdout:
                        await asyncio.wait_for(self.process.stdout.read(), timeout=2)
                except (asyncio.TimeoutError, Exception):
                    pass
                try:
                    if self.process.stderr:
                        await asyncio.wait_for(self.process.stderr.read(), timeout=2)
                except (asyncio.TimeoutError, Exception):
                    pass

                self._log("Sending SIGTERM...")
                self.process.terminate()
                try:
                    await asyncio.wait_for(self.process.wait(), timeout=3)
                except asyncio.TimeoutError:
                    self._log("SIGTERM ignored, sending SIGKILL...")
                    self.process.kill()
                    try:
                        await asyncio.wait_for(self.process.wait(), timeout=3)
                    except asyncio.TimeoutError:
                        self._log("SIGKILL wait timed out, proceeding anyway")
                self._log(f"Adapter exited (rc={self.process.returncode})")
            else:
                self._log(f"Adapter already exited (rc={self.process.returncode})")

            return exit_code

        except Exception as e:
            import traceback
            self._log(f"Error: {type(e).__name__}: {e}")
            if self._log_fh:
                traceback.print_exc(file=self._log_fh)
                self._log_fh.flush()
            return 1
        finally:
            # Don't close _log_fh here — main() still needs it for preflight + write_done
            if self.process and self.process.returncode is None:
                self.process.kill()
                await self.process.wait()
            # Clean up steer file
            self._get_steer_file().unlink(missing_ok=True)

    def run_preflight(self) -> int:
        """Run preflight validation (lint/tests) after agent completes.
        Returns 0 on success, 2 on preflight failure."""
        preflight_script = Path(self.foundry_dir) / "lib" / "preflight_fn.bash"
        if not preflight_script.exists():
            self._log("Preflight script not found, skipping")
            return 0

        preflight_enabled = os.environ.get("PREFLIGHT_ENABLED", "true")
        if preflight_enabled != "true":
            self._log("Preflight disabled via PREFLIGHT_ENABLED")
            return 0

        self._log("Running preflight validation...")
        try:
            result = subprocess.run(
                ["bash", "-c", f'source "{preflight_script}" && _run_preflight "{self.worktree}"'],
                cwd=self.worktree,
                capture_output=True,
                text=True,
                timeout=120,
            )
            if result.returncode != 0:
                self._log(f"Preflight FAILED (exit {result.returncode})")
                if result.stdout:
                    self._log(f"stdout: {result.stdout[-500:]}")
                if result.stderr:
                    self._log(f"stderr: {result.stderr[-500:]}")
                return 2
            self._log("Preflight passed")
            return 0
        except subprocess.TimeoutExpired:
            self._log("Preflight timed out (120s)")
            return 2
        except Exception as e:
            self._log(f"Preflight error: {e}")
            return 0  # Don't fail on preflight infrastructure errors

    def write_done(self, exit_code: int):
        """Write exit code to .done file (backward compat with check loop)."""
        Path(self.done_file).write_text(str(exit_code))
        self._log(f"Wrote exit code {exit_code} to {self.done_file}")

    def close(self):
        """Clean up resources."""
        if self._log_fh:
            self._log_fh.close()
            self._log_fh = None


async def main():
    parser = argparse.ArgumentParser(description="ACP Agent Orchestrator")
    parser.add_argument("--backend", required=True, choices=["claude", "codex", "gemini"])
    parser.add_argument("--model", required=True)
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--prompt-file", default=".foundry-prompt.md")
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--done-file", required=True)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--foundry-dir", default=None)
    args = parser.parse_args()

    orchestrator = ACPOrchestrator(
        backend=args.backend,
        model=args.model,
        worktree=args.worktree,
        prompt_file=args.prompt_file,
        log_file=args.log_file,
        done_file=args.done_file,
        timeout=args.timeout,
        foundry_dir=args.foundry_dir,
    )

    exit_code = await orchestrator.run()

    # Run preflight validation on success
    if exit_code == 0:
        preflight_result = orchestrator.run_preflight()
        if preflight_result != 0:
            exit_code = preflight_result

    orchestrator.write_done(exit_code)

    # Safety net: trigger `foundry check` after completion.
    # If the agent finished without pushing, no CI/gate event fires and the
    # task status stays stuck on "running". This async check closes the gap.
    foundry_bin = os.path.join(orchestrator.foundry_dir, "foundry")
    if os.path.isfile(foundry_bin):
        try:
            orchestrator._log("Triggering post-completion foundry check...")
            subprocess.Popen(
                ["bash", foundry_bin, "check"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as e:
            orchestrator._log(f"Post-completion check failed to launch: {e}")

    orchestrator.close()

    sys.exit(exit_code)


if __name__ == "__main__":
    asyncio.run(main())
