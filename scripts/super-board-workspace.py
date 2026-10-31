#!/usr/bin/env python3
"""One Project board, many repos: a workspace of sibling git checkouts.

A workspace config is an ordinary board config plus a `repos` map. Its top-level keys
are defaults; each `repos.<name>` entry overrides them (`path`, `remote`, `base_branch`,
`verify_commands`, `migrations`, ...). This script turns it into one ordinary single-repo
config per repo, so the merge gate, card mover, pre-flight and lanes stay single-repo
and only have to be pointed at the right config and checkout.

  validate  --config C                check the workspace; exit 66 with every problem
  resolve   --config C                write resolved configs; print {name: card fields}
  plan      --config C [--items F] [--deps F]   one wave across every repo
  allowlist --config C [--merge]      absolute permission rules for the session's settings

`plan` runs the single-repo planner once per repo and merges the results, tagging each
card with repo, key (`<name>#<n>`), configPath, repoPath, repoSlug and workspaceRoot.
Issue numbers are only unique inside a repo: `key` is the card's identity.

Exit: 0 ok, 64 usage, 66 invalid workspace; planner and GitHub exits (9, 79) pass through.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
NAME_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")
REMOTE_RE = re.compile(r"(?:github\.com[:/])([^/\s]+/[^/\s]+?)(?:\.git)?/?\Z")
EXCLUDES = [".claude/worktrees/", ".claude/super-board/"]
FLIGHT_ORDER = {"Review": 0, "QA": 1, "Ready": 2}
TAGGED_LISTS = ["cards", "sweep", "resume", "refreshApproval", "flag", "stranded"]
OPEN_ISSUES_QUERY = """query($owner:String!,$repo:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){ issues(states:OPEN,first:100,after:$endCursor){
    pageInfo{ hasNextPage endCursor } nodes{ number } } } }"""


class Invalid(Exception):
    pass


def slug_of(remote):
    match = REMOTE_RE.search(remote or "")
    return match.group(1) if match else None


def merge(base, override):
    """Objects merge key by key; anything else, lists included, is replaced."""
    out = dict(base)
    for key, value in override.items():
        out[key] = merge(out[key], value) if isinstance(out.get(key), dict) and isinstance(value, dict) else value
    return out


def load(config_path):
    path = Path(config_path).resolve()
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise Invalid(f"cannot read {path}: {error}")
    if not isinstance(config, dict) or not isinstance(config.get("repos"), dict) or not config["repos"]:
        raise Invalid(f"{path} has no `repos` map: not a workspace config")
    if path.parent.name != "configs" or path.parents[1].name != "super-board" or path.parents[2].name != ".claude":
        raise Invalid(f"{path} must live at <workspace>/.claude/super-board/configs/<slug>.json")
    return path, config, path.parents[3]


def git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True)


def problems(config, root):
    found = []
    if "repo" in config:
        found.append("top-level `repo` conflicts with `repos`: move it under repos.<name>")
    if config.get("worker_backend", "workflow") != "workflow":
        found.append('workspaces run only on worker_backend "workflow"')
    seen = {}
    for name, entry in config["repos"].items():
        if not NAME_RE.match(name):
            found.append(f"repos.{name}: invalid name")
            continue
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            found.append(f"repos.{name}: needs a `path`")
            continue
        slug = slug_of(entry.get("remote"))
        if not slug:
            found.append(f"repos.{name}: `remote` must be a github.com URL")
            continue
        if slug.lower() in seen:
            found.append(f"repos.{name}: same remote as repos.{seen[slug.lower()]}")
        seen[slug.lower()] = name
        path = (root / entry["path"]).resolve()
        top = git(path, "rev-parse", "--show-toplevel") if path.is_dir() else None
        if top is None or top.returncode or Path(top.stdout.strip()).resolve() != path:
            found.append(f"repos.{name}: {path} is not the root of a git checkout")
            continue
        origin = git(path, "remote", "get-url", "origin").stdout.strip()
        if (slug_of(origin) or "").lower() != slug.lower():
            found.append(f"repos.{name}: origin is {origin or 'unset'}, config says {entry['remote']}")
    return found


def exclude_state(path):
    """Keep the per-repo state out of `git status`, without touching a tracked file."""
    common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    info = Path(common) / "info" / "exclude"
    current = info.read_text() if info.exists() else ""
    missing = [line for line in EXCLUDES if line not in current.splitlines()]
    if missing:
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text(current + ("" if not current or current.endswith("\n") else "\n") + "\n".join(missing) + "\n")


def resolve(config_path):
    path, config, root = load(config_path)
    found = problems(config, root)
    if found:
        raise Invalid("\n".join(found))
    state = root / ".claude/super-board"
    # Marks the workspace for the GitHub halt helper: one quota, so one halt file.
    (state / "workspace").write_text(path.stem + "\n")
    out_dir = state / "resolved" / path.stem
    out_dir.mkdir(parents=True, exist_ok=True)
    shared = {key: value for key, value in config.items() if key != "repos"}
    resolved = {}
    for name, entry in config["repos"].items():
        repo_path = (root / entry["path"]).resolve()
        override = {key: value for key, value in entry.items() if key not in ("path", "remote")}
        single = merge(shared, override)
        single["repo"] = {"path": str(repo_path), "remote": entry["remote"]}
        single["workspace"] = {"root": str(root), "slug": path.stem, "repo": name}
        target = out_dir / f"{name}.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(single, indent=2) + "\n")
        temporary.replace(target)
        exclude_state(repo_path)
        resolved[name] = {"repo": name, "configPath": str(target), "repoPath": str(repo_path),
                          "repoSlug": slug_of(entry["remote"]), "workspaceRoot": str(root)}
    return config, resolved


def run_json(command, cwd):
    env = dict(os.environ, SB_REPO_PATH=str(cwd))
    process = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
    if process.returncode:
        sys.stderr.write(process.stderr)
        sys.exit(process.returncode)
    return json.loads(process.stdout)


def open_refs(resolved):
    """Every open issue in the workspace, as lower-case `owner/name#n`. One point per 100 issues."""
    refs = []
    for info in resolved.values():
        owner, name = info["repoSlug"].split("/")
        pages = run_json([sys.executable, str(HERE / "super-board-github-read.py"), "--kind", "json", "--",
                          "api", "graphql", "--paginate", "--slurp", "-f", "query=" + OPEN_ISSUES_QUERY,
                          "-F", f"owner={owner}", "-F", f"repo={name}"], info["repoPath"])
        for page in pages:
            issues = page["data"]["repository"]["issues"]["nodes"]
            refs += [f"{info['repoSlug'].lower()}#{issue['number']}" for issue in issues]
    return refs


def aliases_of(resolved):
    aliases = {}
    for name, info in resolved.items():
        slug = info["repoSlug"].lower()
        aliases[name.lower()] = aliases[slug] = aliases[slug.split("/")[1]] = slug
    return aliases


def plan(args):
    config, resolved = resolve(args.config)
    root = next(iter(resolved.values()))["workspaceRoot"]
    if args.items:
        items = json.loads(Path(args.items).read_text())
    else:
        project = config["project"]
        items = run_json(["bash", str(HERE / "super-board-card.sh"), "--owner", project["owner"],
                          "--number", str(project["number"]), "items"], root)
    given_deps = json.loads(Path(args.deps).read_text()) if args.deps else None
    aliases = json.dumps(aliases_of(resolved))
    merged = {key: [] for key in TAGGED_LISTS}
    with tempfile.TemporaryDirectory(prefix="super-board-workspace-") as temporary:
        temporary = Path(temporary)
        refs_file = temporary / "open-refs.json"
        if given_deps is None:
            refs_file.write_text(json.dumps(open_refs(resolved)))
        for name, info in resolved.items():
            own = [item for item in items["items"]
                   if str((item.get("content") or {}).get("repository") or "").lower() == info["repoSlug"].lower()]
            items_file, deps_file = temporary / f"{name}.items.json", temporary / f"{name}.deps.json"
            items_file.write_text(json.dumps({"items": own, "totalCount": len(own)}))
            if given_deps is None:
                deps = run_json(["bash", str(HERE / "super-board-deps.sh"), "--repo", info["repoSlug"], "--limit", "300",
                                 "--workspace-open", str(refs_file), "--aliases", aliases], info["repoPath"])
            else:
                deps = given_deps.get(name, {})
            deps_file.write_text(json.dumps(deps))
            part = run_json(["bash", str(HERE / "super-board-wave-plan.sh"), "--config", info["configPath"],
                             "--items", str(items_file), "--deps", str(deps_file), "--no-cap"], info["repoPath"])
            for key in TAGGED_LISTS:
                merged[key] += [dict(card, key=f"{name}#{card['number']}", **info) for card in part.get(key, [])]
    known = {info["repoSlug"].lower() for info in resolved.values()}
    for item in items["items"]:
        content = item.get("content") or {}
        repository = str(content.get("repository") or "")
        if (content.get("type") == "Issue" and repository.lower() not in known
                and item.get("status") in ("Ready", "Building", "QA", "Review", "Blocked")):
            merged["flag"].append({"number": content.get("number"), "title": content.get("title"),
                                   "key": f"{repository}#{content.get('number')}", "repo": repository,
                                   "why": f"{repository} is not in this workspace's `repos`; nothing will run this card"})
    # Downstream-first across repos, so a throttled wave spends slots closest to Done.
    merged["cards"].sort(key=lambda card: FLIGHT_ORDER.get(card["status"], 3))
    cap = config.get("max_workers") or 0
    if cap > 0:
        merged["cards"] = merged["cards"][:cap]
    print(json.dumps(merged))


def allowlist(args):
    _, _, root = load(args.config)
    bin_dir = root / ".claude/bin"
    rules = []
    for script in sorted(bin_dir.glob("super-*")):
        if script.name == "super-board-run.sh" or (script.name == "super-board-merge-gate.sh" and not args.merge):
            continue
        runner = "python3" if script.suffix == ".py" else "bash"
        rules += [f"Bash({runner} {script}:*)", f"Bash({script}:*)"]
    if args.merge:
        rules.append("Bash(gh pr merge:*)")
    print(json.dumps(rules, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["validate", "resolve", "plan", "allowlist"])
    parser.add_argument("--config", required=True)
    parser.add_argument("--items")
    parser.add_argument("--deps")
    parser.add_argument("--merge", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            _, config, root = load(args.config)
            found = problems(config, root)
            if found:
                raise Invalid("\n".join(found))
            print(f"workspace ok: {len(config['repos'])} repos")
        elif args.command == "resolve":
            print(json.dumps(resolve(args.config)[1], indent=2))
        elif args.command == "plan":
            plan(args)
        else:
            allowlist(args)
    except Invalid as error:
        print(f"invalid workspace: {error}", file=sys.stderr)
        return 66
    return 0


if __name__ == "__main__":
    sys.exit(main())
