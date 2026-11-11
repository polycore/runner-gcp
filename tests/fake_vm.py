#!/usr/bin/env python3

import base64
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
state_file = Path(os.environ["VM_STATE"])
state = json.loads(state_file.read_text())
scenario = os.environ.get("SCENARIO", "success")


def save():
    state_file.write_text(json.dumps(state))


if command == "curl":
    url = args[-1]
    metadata = {
        "deployment-id": "test-deployment",
        "host-project": "acme-prod",
        "runner-image": "registry.example.test/runner:new",
        "control-plane-ws": "wss://cp.example.test/runner",
        "runner-id": "rnr_test",
        "runner-config-path": "/app/polycore.json",
        "polycore-project-slug": "acme",
        "google-cloud-project": "acme-prod",
        "container-name": "polycore-runner",
        "secret-join-token": "join-token",
        "secret-signing-secret": "signing-secret",
        "extra-secrets": "[]",
        "extra-env": "{}",
    }
    if "/attributes/" in url:
        print(metadata[url.rsplit("/", 1)[-1]])
    elif url.endswith("/service-accounts/default/token"):
        print(json.dumps({"access_token": "test-only-token"}))
    elif "/secrets/" in url:
        if scenario == "secret-failure":
            sys.exit(22)
        print(json.dumps({"payload": {"data": base64.b64encode(b"test-only-secret").decode()}}))
    else:
        sys.exit(f"Unexpected URL: {url}")
elif command == "sleep":
    state["checks_elapsed"] += 1
    save()
elif command == "systemctl":
    state["running"] = True
    save()
elif command == "docker":
    operation = args[0]
    if operation in ("image", "container"):
        operation += " " + args[1]
    state["events"].append(operation)
    save()
    if operation == "login":
        sys.stdin.read()
    elif operation == "image prune":
        assert args == ["image", "prune", "-af"]
        if scenario == "cleanup-failure" and state["container"] == "sha256:new":
            sys.exit(1)
        state["images"] = [state["container"]] if state["container"] else []
    elif operation == "pull":
        if scenario == "pull-failure" or len(state["images"]) >= 3:
            print("failed to register layer: no space left on device", file=sys.stderr)
            sys.exit(1)
        state["images"].append("sha256:new")
    elif operation == "image inspect":
        print("sha256:new")
    elif operation == "rm":
        state["container"] = None
    elif operation == "run":
        if scenario == "run-failure":
            sys.exit(125)
        assert args[-1] == "sha256:new"
        state["container"] = "sha256:new"
        state["running"] = True
        print("new-container-id")
    elif operation == "container inspect":
        image = "sha256:old" if scenario == "wrong-image" else state["container"]
        running = "false" if scenario == "exited" else "true"
        restarting = "true" if scenario == "restarting" else "false"
        restarts = 1 if scenario == "restarted" else 0
        if scenario == "late-crash" and state["checks_elapsed"] >= 10:
            running = "false"
        print(f"{image} {running} {restarting} {restarts}")
    else:
        sys.exit(f"Unexpected docker operation: {operation}")
    save()
else:
    sys.exit(f"Unexpected command: {command}")
