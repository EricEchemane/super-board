#!/usr/bin/env python3
"""Read-only verification configuration gate. Exit 9 means repair setup, not code."""
import argparse
import json
import sys


def readiness_error(config):
    """Return a setup error, or None when at least one project command is usable."""
    if not isinstance(config, dict):
        return "config must be a JSON object"
    if isinstance(config.get("repos"), dict):
        for name, entry in config["repos"].items():
            own = entry.get("verify_commands", config.get("verify_commands")) if isinstance(entry, dict) else None
            error = readiness_error({"verify_commands": own})
            if error:
                return f"repos.{name}: {error}"
        return None
    commands = config.get("verify_commands")
    if not isinstance(commands, list) or any(not isinstance(c, str) for c in commands):
        return "verify_commands must be an array of project command strings"
    if any("\x00" in c for c in commands):
        return "verify_commands must not contain NUL bytes (shells cannot preserve them)"
    if not any(c.strip() for c in commands):
        return "verify_commands has no usable project commands"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, help="config file, or - for stdin")
    args = parser.parse_args()
    try:
        if args.config == "-":
            config = json.load(sys.stdin)
        else:
            with open(args.config, encoding="utf-8") as source:
                config = json.load(source)
        error = readiness_error(config)
    except (OSError, ValueError) as exc:
        error = f"cannot read config: {exc}"
    if error:
        print(f"verification-readiness: {error}. Set verify_commands in "
              f"{args.config if args.config != '-' else 'the active config'} "
              "to the owning project's real checks, then restart the board. "
              "No merge or dispatch was authorized.", file=sys.stderr)
        return 9
    return 0


if __name__ == "__main__":
    sys.exit(main())
