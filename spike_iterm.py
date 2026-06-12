#!/usr/bin/env python3
"""
SnippAI de-risking spike: prove the iTerm2 API can do the full tunnel loop.

Legs verified:
  1. ENUMERATE  - list every session with id + working directory (for the picker)
  2. SEND       - inject "message + screenshot path" text into a CHOSEN session
  3. STREAM     - read that session's screen back live and confirm the round trip

Safety: never touches the user's live sessions except to read them. The
send/stream test runs in a fresh throwaway window that is closed at the end.
"""
import asyncio
import random
import string
import time

import iterm2

TOKEN = "SNIPPAI_" + "".join(random.choices(string.ascii_uppercase + string.digits, k=8))
FAKE_SHOT = "/tmp/snippai_spike_shot.png"  # stands in for a real screenshot path
results = {"enumerate": False, "send": False, "stream": False, "latency_ms": None}


async def main(connection):
    app = await iterm2.async_get_app(connection)

    # ---- LEG 1: ENUMERATE -------------------------------------------------
    found = []
    for window in app.windows:
        for tab in window.tabs:
            for session in tab.sessions:
                try:
                    cwd = await session.async_get_variable("path")
                except Exception:
                    cwd = "?"
                try:
                    title = await session.async_get_variable("autoName")
                except Exception:
                    title = "?"
                found.append((session.session_id, cwd, title))
    print(f"[LEG 1] ENUMERATE: {len(found)} live session(s)")
    for sid, cwd, title in found:
        print(f"          - {sid}  cwd={cwd!r}  title={title!r}")
    results["enumerate"] = len(found) > 0

    # ---- isolated test target (do NOT clobber the user's sessions) --------
    test_window = await iterm2.Window.async_create(connection)
    if test_window is None:
        print("[FAIL] could not create isolated test window")
        return
    test = test_window.current_tab.current_session
    print(f"[setup] isolated test session = {test.session_id}")
    await asyncio.sleep(0.6)  # let the shell prompt settle

    # ---- LEG 2: SEND ------------------------------------------------------
    # Mimics what the real app sends: a message that references a local file path.
    payload = f'echo "{TOKEN} :: please look at {FAKE_SHOT}"\n'
    await test.async_send_text(payload)
    print(f"[LEG 2] SEND: injected {payload!r}")

    # ---- LEG 3: STREAM ----------------------------------------------------
    saw_command = False   # the typed line echoed back
    saw_output = False    # the EXECUTED result line (proves it actually ran)
    t0 = time.monotonic()
    deadline = 8.0
    async with test.get_screen_streamer() as streamer:
        while time.monotonic() - t0 < deadline:
            try:
                contents = await asyncio.wait_for(streamer.async_get(), timeout=deadline)
            except asyncio.TimeoutError:
                break
            lines = [contents.line(i).string for i in range(contents.number_of_lines)]
            for ln in lines:
                if TOKEN in ln and FAKE_SHOT in ln:
                    if "echo" in ln:
                        saw_command = True
                    else:
                        saw_output = True
                        if results["latency_ms"] is None:
                            results["latency_ms"] = (time.monotonic() - t0) * 1000.0
            if saw_output:
                break

    results["send"] = saw_command or saw_output
    results["stream"] = saw_output
    lat = results["latency_ms"]
    print(f"[LEG 3] STREAM: command-echoed={saw_command} executed-output={saw_output}"
          + (f"  (round-trip {lat:.0f}ms)" if lat else ""))

    # ---- cleanup ----------------------------------------------------------
    await test_window.async_close(force=True)
    print("[cleanup] closed isolated test window")


def run():
    try:
        iterm2.run_until_complete(main)
    except Exception as exc:  # noqa: BLE001 - spike wants the raw failure
        print(f"[CONNECT-ERROR] {type(exc).__name__}: {exc}")
        print("  -> Likely the iTerm2 Python API is not enabled, or permission was denied.")
        return

    print("\n==================== SPIKE RESULT ====================")
    legs = [
        ("ENUMERATE sessions (picker)", results["enumerate"]),
        ("SEND text+path to a session", results["send"]),
        ("STREAM screen back live",     results["stream"]),
    ]
    for name, ok in legs:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    overall = all(ok for _, ok in legs)
    print(f"  ---> {'ALL GREEN — tunnel is real' if overall else 'INCOMPLETE'}")
    print("======================================================")


if __name__ == "__main__":
    run()
