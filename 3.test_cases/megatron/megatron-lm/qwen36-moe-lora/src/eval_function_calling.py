# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Two-gate evaluation of a deployed Qwen3.6-35B xLAM LoRA vs its base.

Gate 1  — 10 hand-crafted prompts covering function-calling edge cases (single
          tool, nested objects, enums, multi-tool, array args, typed args,
          ambiguous "no tool"). Passes if predicted tool name matches expected
          AND the call is parseable.

Gate 2  — 50 held-out xLAM validation prompts scored by Claude Opus 4.7 as an
          LLM-as-judge. Position-randomized A/B presentation to remove bias.

Usage:
    python eval_function_calling.py \\
        --endpoint http://qwen-inference.qwen-moe-lora.svc.cluster.local:8000 \\
        --base-model Qwen/Qwen3.6-35B-A3B \\
        --lora-alias tools \\
        --val-file /fsx/datasets/validation.jsonl \\
        --gate 1
    python eval_function_calling.py --gate 2 --val-file ... --n 50
    python eval_function_calling.py --gate all ...

Gate 2 requires AWS credentials resolvable via boto3's default chain (IRSA on the
pod's ServiceAccount, or AWS_* env vars), and bedrock:InvokeModel on the Claude
Opus 4.7 inference profile in the chosen region.
"""
import argparse
import json
import random
import re
from typing import Any

import requests


# ---------------------------------------------------------------------------
# Tool-call output parser — Qwen3+ family emits Qwen-Agent XML form:
#   <tool_call><function=name><parameter=key>value</parameter>...</function></tool_call>
# vLLM's built-in --tool-call-parser hermes expects JSON-in-XML instead, so we
# parse the XML ourselves rather than relying on msg.tool_calls being populated.
# ---------------------------------------------------------------------------
_TOOL_CALL_RE = re.compile(r"<function=(\w+)>(.*?)</function>", re.S)
_PARAM_RE = re.compile(r"<parameter=(\w+)>\s*(.*?)\s*</parameter>", re.S)


def parse_qwen_tool_call(content: str) -> dict | None:
    if not content or "<tool_call>" not in content:
        return None
    m = _TOOL_CALL_RE.search(content)
    if not m:
        return None
    name = m.group(1)
    args: dict[str, Any] = {}
    for pm in _PARAM_RE.finditer(m.group(2)):
        k, v = pm.group(1), pm.group(2).strip()
        # best-effort type coercion
        try:
            args[k] = int(v)
            continue
        except ValueError:
            pass
        try:
            args[k] = float(v)
            continue
        except ValueError:
            pass
        if v.lower() == "true":
            args[k] = True
        elif v.lower() == "false":
            args[k] = False
        else:
            args[k] = v
    return {"name": name, "arguments": args}


def chat_tools(endpoint: str, model: str, messages: list, tools: list | None = None,
               max_tokens: int = 512, timeout: int = 180) -> dict:
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.1,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if tools is not None:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    r = requests.post(
        f"{endpoint}/v1/chat/completions",
        json=payload,
        timeout=timeout,
    )
    r.raise_for_status()
    return r.json()


def score_response(resp: dict, expected_tool: str | None) -> dict:
    msg = resp["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    name = None
    args: dict = {}
    if calls:
        name = calls[0].get("function", {}).get("name")
        try:
            args = json.loads(calls[0].get("function", {}).get("arguments", "{}"))
        except (json.JSONDecodeError, TypeError):
            args = {}
    else:
        parsed = parse_qwen_tool_call(msg.get("content", "") or "")
        if parsed:
            name = parsed["name"]
            args = parsed["arguments"]

    if name is None:
        return {"valid": True,
                "right_name": expected_tool is None,
                "has_args": expected_tool is None}
    return {"valid": True,
            "right_name": name == expected_tool,
            "has_args": bool(args)}


# ---------------------------------------------------------------------------
# Gate 1 — hand-crafted edge-case prompts
# ---------------------------------------------------------------------------
GATE1_PROMPTS = [
    ("Simple single tool",
     [{"type": "function", "function": {"name": "search_flights", "description": "Search flights",
        "parameters": {"type": "object",
            "properties": {"origin": {"type": "string"}, "destination": {"type": "string"},
                           "departure_date": {"type": "string"}, "passengers": {"type": "integer"}},
            "required": ["origin", "destination", "departure_date"]}}}],
     "Find flights from JFK to SFO on 2026-05-10 for 2 passengers.",
     "search_flights"),
    ("camelCase schema",
     [{"type": "function", "function": {"name": "getUserProfile", "description": "Fetch user profile",
        "parameters": {"type": "object",
            "properties": {"userId": {"type": "integer"}, "includeOrders": {"type": "boolean"}},
            "required": ["userId"]}}}],
     "Get the profile for user 42 and include their orders.",
     "getUserProfile"),
    ("Nested object",
     [{"type": "function", "function": {"name": "create_event", "description": "Create calendar event",
        "parameters": {"type": "object",
            "properties": {"title": {"type": "string"},
                           "time": {"type": "object",
                                    "properties": {"start": {"type": "string"},
                                                   "end": {"type": "string"}},
                                    "required": ["start", "end"]}},
            "required": ["title", "time"]}}}],
     'Schedule a meeting "Team sync" from 2026-05-12T10:00 to 11:00.',
     "create_event"),
    ("Enum argument",
     [{"type": "function", "function": {"name": "get_weather", "description": "Get weather",
        "parameters": {"type": "object",
            "properties": {"location": {"type": "string"},
                           "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}},
            "required": ["location"]}}}],
     "What is the weather in Seattle in fahrenheit?",
     "get_weather"),
    ("Multi-tool required",
     [{"type": "function", "function": {"name": "search_flights",
        "parameters": {"type": "object",
            "properties": {"origin": {"type": "string"}, "destination": {"type": "string"},
                           "departure_date": {"type": "string"}},
            "required": ["origin", "destination", "departure_date"]}}},
      {"type": "function", "function": {"name": "book_hotel",
        "parameters": {"type": "object",
            "properties": {"city": {"type": "string"}, "nights": {"type": "integer"}},
            "required": ["city", "nights"]}}}],
     "Book me a flight from JFK to SFO on 2026-05-10 and a 3-night hotel in San Francisco.",
     "search_flights"),
    ("Array argument",
     [{"type": "function", "function": {"name": "send_emails",
        "parameters": {"type": "object",
            "properties": {"recipients": {"type": "array", "items": {"type": "string"}},
                           "subject": {"type": "string"}, "body": {"type": "string"}},
            "required": ["recipients", "subject", "body"]}}}],
     'Email alice@x.com and bob@y.com with subject "Meeting" and body "Tomorrow 10am".',
     "send_emails"),
    ("Integer type",
     [{"type": "function", "function": {"name": "cart_add",
        "parameters": {"type": "object",
            "properties": {"sku": {"type": "string"},
                           "quantity": {"type": "integer", "minimum": 1}},
            "required": ["sku", "quantity"]}}}],
     "Add 3 of item ABC-123 to the cart.",
     "cart_add"),
    ("Boolean flag",
     [{"type": "function", "function": {"name": "subscribe",
        "parameters": {"type": "object",
            "properties": {"email": {"type": "string"},
                           "marketing_consent": {"type": "boolean"}},
            "required": ["email"]}}}],
     "Subscribe user@example.com, they have consented to marketing.",
     "subscribe"),
    ("Ambiguous - no tool",
     [{"type": "function", "function": {"name": "play_music",
        "parameters": {"type": "object",
            "properties": {"song": {"type": "string"}},
            "required": ["song"]}}}],
     "What is the capital of France?",
     None),
    ("Decimal + currency",
     [{"type": "function", "function": {"name": "transfer",
        "parameters": {"type": "object",
            "properties": {"from": {"type": "string"}, "to": {"type": "string"},
                           "amount": {"type": "number"}, "currency": {"type": "string"}},
            "required": ["from", "to", "amount", "currency"]}}}],
     "Transfer $1,234.56 from acct-A to acct-B.",
     "transfer"),
]


def run_gate_1(endpoint: str, model: str) -> tuple[int, list]:
    results = []
    passed = 0
    for i, (desc, tools, user, expected) in enumerate(GATE1_PROMPTS, 1):
        try:
            resp = chat_tools(endpoint, model, [{"role": "user", "content": user}], tools=tools)
            s = score_response(resp, expected)
            ok = s["valid"] and s["right_name"]
            err = ""
        except Exception as e:
            s = {"valid": False, "right_name": False, "has_args": False}
            ok = False
            err = f"  ERR: {type(e).__name__}: {str(e)[:80]}"
        if ok:
            passed += 1
        results.append({"idx": i, "desc": desc, "passed": ok, **s})
        print(f"  [{model[:24]:<24}] {i:2d} {desc[:30]:<30}  pass={ok}  right_name={s['right_name']}{err}")
    return passed, results


# ---------------------------------------------------------------------------
# Gate 2 — LLM-as-judge via Bedrock
# ---------------------------------------------------------------------------
JUDGE_PROMPT_TEMPLATE = (
    "You are an impartial judge of function-calling quality. The user prompt "
    "includes tool schemas and a user request. Compare two model outputs on: "
    "(1) valid JSON / valid tool-call format, (2) correct tool name and args, "
    "(3) no extraneous prose. Respond with EXACTLY one token: A, B, or TIE. "
    "No explanation.\n\n"
    "USER PROMPT:\n{user}\n\n"
    "OUTPUT A:\n{a}\n\n"
    "OUTPUT B:\n{b}\n\n"
    "Which is better? Answer A, B, or TIE only."
)


def run_gate_2(endpoint: str, base_model: str, lora_alias: str,
               val_file: str, n: int, bedrock_region: str,
               judge_model: str) -> tuple[int, int, int, int]:
    import boto3
    bedrock = boto3.client("bedrock-runtime", region_name=bedrock_region)

    def judge(user_prompt, out_a, out_b):
        body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 8,
            "messages": [{"role": "user",
                          "content": JUDGE_PROMPT_TEMPLATE.format(
                              user=user_prompt, a=out_a, b=out_b)}],
        }
        # NOTE: Claude Opus 4.7+ deprecated the `temperature` parameter — do not
        # pass it. Older judges (Sonnet 4.6 etc.) still accept it.
        resp = bedrock.invoke_model(
            modelId=judge_model,
            body=json.dumps(body),
            contentType="application/json",
            accept="application/json",
        )
        text = json.loads(resp["body"].read())["content"][0]["text"].strip().upper()
        for tok in ("TIE", "A", "B"):
            if text.startswith(tok):
                return tok
        return "TIE"

    # Load validation rows.
    rows = []
    with open(val_file) as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
            if len(rows) >= n:
                break
    if not rows:
        raise SystemExit(f"No rows loaded from {val_file}")

    random.seed(42)
    wins, ties, losses, errors = 0, 0, 0, 0
    for i, row in enumerate(rows, 1):
        user = row["input"]
        try:
            base_resp = chat_tools(endpoint, base_model,
                                   [{"role": "user", "content": user}], max_tokens=400)
            lora_resp = chat_tools(endpoint, lora_alias,
                                   [{"role": "user", "content": user}], max_tokens=400)
            base_msg = base_resp["choices"][0]["message"]
            lora_msg = lora_resp["choices"][0]["message"]
            base_out = base_msg.get("content") or str(base_msg.get("tool_calls"))
            lora_out = lora_msg.get("content") or str(lora_msg.get("tool_calls"))

            swap = random.random() < 0.5
            if swap:
                raw = judge(user, lora_out, base_out)
                verdict = {"A": "LORA", "B": "BASE", "TIE": "TIE"}[raw]
            else:
                raw = judge(user, base_out, lora_out)
                verdict = {"A": "BASE", "B": "LORA", "TIE": "TIE"}[raw]

            if verdict == "LORA":
                wins += 1
            elif verdict == "BASE":
                losses += 1
            else:
                ties += 1
            print(f"  [{i:2d}/{n}] {verdict:<4}  {user[:60]}...")
        except Exception as e:
            errors += 1
            print(f"  [{i:2d}/{n}] ERR: {type(e).__name__}: {str(e)[:80]}")

    return wins, losses, ties, errors


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--endpoint", required=True,
                   help="Base URL of the vLLM OpenAI-compatible endpoint")
    p.add_argument("--base-model", default="Qwen/Qwen3.6-35B-A3B")
    p.add_argument("--lora-alias", default="tools",
                   help="Name used in vLLM's --lora-modules <name>=<path>")
    p.add_argument("--gate", choices=["1", "2", "all"], default="all")
    p.add_argument("--val-file", default="/fsx/datasets/validation.jsonl",
                   help="Gate 2 validation JSONL path")
    p.add_argument("--n", type=int, default=50, help="Gate 2 sample count")
    p.add_argument("--bedrock-region", default="us-west-2")
    p.add_argument("--judge-model", default="us.anthropic.claude-opus-4-7",
                   help="Bedrock inference profile ID")
    return p.parse_args()


def main():
    args = parse_args()
    gates = ("1", "2") if args.gate == "all" else (args.gate,)

    summary: dict = {}
    if "1" in gates:
        print("=== Gate 1 - Base model ===")
        base_pass, _ = run_gate_1(args.endpoint, args.base_model)
        print("\n=== Gate 1 - LoRA ===")
        lora_pass, _ = run_gate_1(args.endpoint, args.lora_alias)
        summary["gate1_base"] = f"{base_pass}/10"
        summary["gate1_lora"] = f"{lora_pass}/10"

    if "2" in gates:
        print(f"\n=== Gate 2 - Judge ({args.judge_model}), {args.n} samples ===")
        wins, losses, ties, errs = run_gate_2(
            args.endpoint, args.base_model, args.lora_alias,
            args.val_file, args.n, args.bedrock_region, args.judge_model,
        )
        total = wins + losses + ties
        win_rate = wins / total if total else 0.0
        summary["gate2_lora_wins"] = f"{wins}/{total}"
        summary["gate2_win_rate"] = f"{win_rate:.0%}"
        summary["gate2_errors"] = errs

    print("\n=== Summary ===")
    for k, v in summary.items():
        print(f"  {k:<22} {v}")


if __name__ == "__main__":
    main()
