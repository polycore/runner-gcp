#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time


def wait_for_startup(*, project, zone, vm, deployment_id, timeout):
    deadline = time.monotonic() + timeout
    success = f"=== startup complete; deployment={deployment_id} ==="
    failure = f"=== startup failed; deployment={deployment_id}; exit="
    command = [
        "gcloud", "compute", "instances", "get-serial-port-output", vm,
        f"--project={project}", f"--zone={zone}", "--port=1", "--format=json",
    ]
    last_error = "No startup result received."
    print(f"Waiting up to {timeout}s for deployment {deployment_id} on {vm}.", flush=True)
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, check=True,
                timeout=max(0.1, min(30, deadline - time.monotonic())),
            )
            contents = json.loads(result.stdout)["contents"]
            if not isinstance(contents, str):
                raise ValueError("Serial output contents must be a string.")
            if failure in contents:
                print(f"error: VM startup failed for deployment {deployment_id}.", file=sys.stderr)
                return 1
            if success in contents:
                print(f"Runner startup verified for deployment {deployment_id}.")
                return 0
            last_error = "No matching startup result received."
        except subprocess.CalledProcessError as error:
            last_error = f"Serial output request failed (exit {error.returncode})."
        except subprocess.TimeoutExpired:
            last_error = "Serial output request timed out."
        except (ValueError, KeyError, TypeError):
            last_error = "Serial output response was invalid."
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(5, remaining))
    print(
        f"error: deployment {deployment_id} on {vm} did not complete within {timeout}s. "
        f"{last_error} Inspect the VM's /var/log/polycore-runner-startup.log.",
        file=sys.stderr,
    )
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--zone", required=True)
    parser.add_argument("--vm", required=True)
    parser.add_argument("--deployment-id", required=True)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if args.timeout <= 0 or not args.deployment_id:
        parser.error("timeout must be positive and deployment-id must not be empty")
    return wait_for_startup(**vars(args))


if __name__ == "__main__":
    sys.exit(main())
