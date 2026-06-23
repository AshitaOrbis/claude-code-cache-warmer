#!/usr/bin/env python3
"""JSONL transcript parsers for cache-warmer.sh.

Extracted from the script so the parsing logic can be exercised directly
against fixtures (see tests/). Each subcommand reads a Claude Code session
JSONL file and prints a small, shell-parseable result. The parsing rules are
byte-for-byte the same as the heredocs they replaced; `submit-confirmed` is the
new deterministic submit-detection predicate added for the PTY/JSONL readiness
refactor (BACKLOG cw-2).

Usage:
  jsonl.py user-activity   <jsonl>          -> "<epoch> <count>"  (or nothing)
  jsonl.py fork-usage      <jsonl> <nonce>  -> "<read> <create> <input>" (or nothing)
  jsonl.py expected-tokens <jsonl>          -> "<int>"
  jsonl.py submit-confirmed <jsonl> <nonce> -> exit 0 if a real user record
                                               carrying the nonce exists, else 1

All subcommands fail soft: a missing/unreadable/garbage file yields the empty
or zero result rather than a traceback, matching the original heredoc behavior.
"""
import datetime
import json
import sys

KEEPALIVE_MARKER = "[cache-warmer keepalive]"


def _iter_records(path):
    """Yield parsed JSON objects from a JSONL file, skipping unparseable lines.

    Never raises on a missing/unreadable file — yields nothing instead.
    """
    try:
        fh = open(path)
    except Exception:
        return
    with fh:
        for line in fh:
            try:
                yield json.loads(line)
            except Exception:
                continue


def _message_text(rec):
    """Flatten a user/assistant record's message content to plain text.

    Returns "" when the content is a tool_result list (caller treats those as
    non-text) or otherwise absent.
    """
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list):
        return " ".join(
            b.get("text", "") for b in content if isinstance(b, dict)
        )
    return content or ""


def _is_real_user_text(rec):
    """True if rec is a real user *text* turn (not meta/tool-result).

    Mirrors the original user_activity filter: type==user, not isMeta, no
    toolUseResult, and content is not a tool_result block list.
    """
    if rec.get("type") != "user" or rec.get("isMeta") or "toolUseResult" in rec:
        return False
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list):
        if any(
            b.get("type") == "tool_result"
            for b in content
            if isinstance(b, dict)
        ):
            return False
    return True


def cmd_user_activity(path):
    """Last real-user-message epoch + count. Real = type=user, not a tool
    result, not meta, not a keepalive. Prints "epoch count" or nothing."""
    last, count = None, 0
    for rec in _iter_records(path):
        if not _is_real_user_text(rec):
            continue
        text = _message_text(rec)
        if KEEPALIVE_MARKER in text:
            continue
        ts = rec.get("timestamp")
        if not ts:
            continue
        try:
            datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except Exception:
            continue
        last, count = ts, count + 1
    if last:
        epoch = int(
            datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp()
        )
        print(epoch, count)


def cmd_fork_usage(path, nonce):
    """Usage of the assistant turn that ANSWERS our nonce-tagged keepalive.
    Prints "read creation input" only when that causal pair exists."""
    seen_nonce = False
    u = None
    for rec in _iter_records(path):
        if not seen_nonce:
            if rec.get("type") != "user" or "toolUseResult" in rec:
                continue
            content = (rec.get("message") or {}).get("content")
            text = content if isinstance(content, str) else " ".join(
                b.get("text", "")
                for b in (content or [])
                if isinstance(b, dict)
            )
            if nonce in (text or ""):
                seen_nonce = True
        else:
            # First real assistant turn after the nonce with usable usage.
            # Skip sidechain turns and usage-less records (e.g. an error turn
            # before a successful retry).
            if rec.get("type") == "assistant" and not rec.get("isSidechain"):
                cand = (rec.get("message") or {}).get("usage") or {}
                if any(
                    cand.get(k)
                    for k in (
                        "cache_read_input_tokens",
                        "cache_creation_input_tokens",
                        "input_tokens",
                    )
                ):
                    u = cand
                    break
    if u:
        print(
            u.get("cache_read_input_tokens", 0) or 0,
            u.get("cache_creation_input_tokens", 0) or 0,
            u.get("input_tokens", 0) or 0,
        )


def cmd_expected_tokens(path):
    """Expected prefix size (tokens) = total input of the LIVE session's last
    assistant turn AFTER the most recent compaction boundary. Prints an int."""
    exp = 0
    for rec in _iter_records(path):
        # Compaction boundary: discard any pre-compaction baseline.
        if rec.get("type") == "user" and rec.get("isCompactSummary"):
            exp = 0
            continue
        # Skip subagent (sidechain) turns: they share the session file but
        # carry small per-subagent contexts that would skew the baseline.
        if rec.get("type") == "assistant" and not rec.get("isSidechain"):
            u = (rec.get("message") or {}).get("usage") or {}
            t = (
                (u.get("cache_read_input_tokens", 0) or 0)
                + (u.get("cache_creation_input_tokens", 0) or 0)
                + (u.get("input_tokens", 0) or 0)
            )
            if t > 0:
                exp = t
    print(exp)


def cmd_submit_confirmed(path, nonce):
    """Deterministic submit proof (BACKLOG cw-2): a real user record carrying
    the nonce means Claude Code accepted the keepalive as a turn and sent it to
    the model — independent of any TUI rendering. Exit 0 if such a record
    exists, 1 otherwise. (The keepalive marker is allowed here, unlike
    user_activity, because this IS our keepalive turn.)"""
    for rec in _iter_records(path):
        if not _is_real_user_text(rec):
            continue
        if nonce in _message_text(rec):
            return 0
    return 1


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    if cmd == "user-activity":
        cmd_user_activity(path)
        return 0
    if cmd == "fork-usage":
        if len(argv) < 4:
            sys.stderr.write("fork-usage requires <jsonl> <nonce>\n")
            return 2
        cmd_fork_usage(path, argv[3])
        return 0
    if cmd == "expected-tokens":
        cmd_expected_tokens(path)
        return 0
    if cmd == "submit-confirmed":
        if len(argv) < 4:
            sys.stderr.write("submit-confirmed requires <jsonl> <nonce>\n")
            return 2
        return cmd_submit_confirmed(path, argv[3])
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
