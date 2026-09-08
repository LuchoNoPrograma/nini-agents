"""SIGTERM a verified profile snapshot using Linux pidfds, never recycled PIDs.

Input contains only process identities and profile markers, never credentials.
No process arguments or environment contents are printed, including on failure.
"""

import json
import os
import signal
import sys


def identity(pid):
    with open(f"/proc/{pid}/stat", "rb") as stream:
        fields = stream.read().rsplit(b") ", 1)[1].split()
    return fields[1], fields[19], fields[0]


def stop(snapshot):
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise RuntimeError("Safe stop requires Python 3.9+ and Linux pidfd support.")
    ancestors = set()
    pid = os.getpid()
    while pid > 0 and pid not in ancestors:
        ancestors.add(pid)
        pid = int(identity(pid)[0])
    markers = {value.encode() for value in snapshot["markers"]}
    handles = []
    try:
        # Complete all checks before sending the first signal.
        for row in snapshot["rows"]:
            pid = int(row["pid"])
            if pid <= 1 or pid in ancestors:
                raise RuntimeError("Refusing to stop this command or its parent session. Run stop from an independent terminal.")
            try:
                fd = os.pidfd_open(pid)
            except ProcessLookupError:
                continue
            handles.append((pid, fd))
            try:
                if os.stat(f"/proc/{pid}").st_uid != os.getuid():
                    raise RuntimeError("Process owner changed; no signals sent.")
                _, start, state = identity(pid)
                if start.decode() != row["start"]:
                    raise RuntimeError("Process identity changed; no signals sent. Inspect again.")
                if state == b"Z":
                    handles.pop()
                    os.close(fd)
                    continue
                with open(f"/proc/{pid}/environ", "rb") as stream:
                    environment = set(stream.read().split(b"\0"))
                if not markers.intersection(environment):
                    raise RuntimeError("Process profile marker changed; no signals sent. Inspect again.")
                if identity(pid)[1] != start:
                    raise RuntimeError("Process identity changed; no signals sent. Inspect again.")
            except (FileNotFoundError, ProcessLookupError):
                handles.pop()
                os.close(fd)
        for pid, fd in handles:
            try:
                signal.pidfd_send_signal(fd, signal.SIGTERM)
                print(f"SIGTERM sent to PID {pid}.")
            except ProcessLookupError:
                pass
    finally:
        for _, fd in handles:
            os.close(fd)


if __name__ == "__main__":
    try:
        stop(json.load(sys.stdin))
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, KeyError, TypeError):
        print("Safe stop failed; inspect again. Some processes may still be running.", file=sys.stderr)
        sys.exit(2)
