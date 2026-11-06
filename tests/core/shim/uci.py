#!/usr/bin/env python3
"""A tiny stand-in for OpenWrt's `uci`, for the takeover/rollback tests.

Only the operations dnswatchd performs are implemented, over a JSON store:

    uci -q get    <pkg>.@<type>[0].<opt>[<n>]
    uci -q set    <pkg>.<sec>.<opt>=<value>
    uci -q add_list <pkg>.<sec>.<opt>=<value>
    uci -q delete <pkg>.<sec>.<opt>
    uci -q commit <pkg>
    uci export   <pkg>

The store is a JSON object keyed by the full option path. List-valued options
store a list; scalars store a string. That is enough to prove that takeover
and rollback put back exactly what they took away.
"""
import json
import os
import sys

STORE = os.environ.get("UCI_SHIM_STORE", "/tmp/uci-shim-store.json")


def load():
    try:
        with open(STORE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save(data):
    tmp = STORE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, STORE)


def split_index(key):
    """"a.b[0].c" -> ("a.b.c", 0) ; no index -> ("a.b.c", None)"""
    if not key.endswith("]"):
        return key, None
    head, _, idx = key.rpartition("[")
    try:
        return head, int(idx[:-1])
    except ValueError:
        return key, None


def main(argv):
    args = [a for a in argv[1:] if a != "-q"]
    if not args:
        return 1

    cmd = args[0]
    data = load()

    if cmd == "get" and len(args) == 2:
        key, idx = split_index(args[1])
        if key not in data:
            return 1
        val = data[key]
        if idx is not None:
            if not isinstance(val, list) or idx >= len(val):
                return 1
            print(val[idx])
            return 0
        if isinstance(val, list):
            print(" ".join(val))
        else:
            print(val)
        return 0

    if cmd in ("set", "add_list") and len(args) == 2:
        key, val = args[1].split("=", 1)
        key, idx = split_index(key)
        if idx is not None:
            cur = data.get(key, [])
            if not isinstance(cur, list):
                cur = [cur]
            while len(cur) <= idx:
                cur.append("")
            cur[idx] = val
            data[key] = cur
        elif cmd == "add_list":
            cur = data.get(key, [])
            if not isinstance(cur, list):
                cur = [cur]
            cur.append(val)
            data[key] = cur
        else:
            data[key] = val
        save(data)
        return 0

    if cmd == "delete" and len(args) == 2:
        key, idx = split_index(args[1])
        # Real uci fails when there is nothing to delete, and dnswatchd relies on
        # that to terminate `while uci delete ...; do :; done`.
        if idx is None:
            if key not in data:
                return 1
            del data[key]
        else:
            cur = data.get(key)
            if not isinstance(cur, list) or idx >= len(cur):
                return 1
            del cur[idx]
            data[key] = cur
        save(data)
        return 0

    if cmd == "commit" and len(args) == 2:
        return 0

    if cmd == "export" and len(args) == 2:
        pkg = args[1]
        print(f"package {pkg}\n")
        for key in sorted(k for k in data if k.startswith(pkg + ".")):
            rest = key[len(pkg) + 1:]
            sec, _, opt = rest.rpartition(".")
            val = data[key]
            if isinstance(val, list):
                for item in val:
                    print(f"list {opt} '{item}'")
            else:
                print(f"option {opt} '{val}'")
        return 0

    print(f"uci-shim: unsupported: {args}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
