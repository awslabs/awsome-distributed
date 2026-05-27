#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""
auto_label.py — Synthetic Data Generation (SDG) auto-labeling using Cosmos Reason.

Pattern: AV training-data captioning, as adopted by Uber
(https://blogs.nvidia.com/blog/nemotron-cosmos-reasoning-enterprise-physical-ai/).
Each input image gets a structured JSON label plus the model's chain-of-thought
reasoning trace. Useful for filtering implausible Cosmos-Predict outputs in an
SDG critic loop, or for bootstrapping training labels.

Output: one JSON object per line (JSONL).

Example:
    python3 auto_label.py --image-dir ./scenes/ --output labels.jsonl
    python3 auto_label.py --image-dir ./scenes/ --schema custom_schema.json
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional

import requests
import urllib3
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from image_vqa import encode_image, parse_reasoning_response  # reuse helpers


DEFAULT_SCHEMA = {
    "scene": "string — short description",
    "objects": "list[string] — primary visible objects",
    "hazards": "list[string] — identified safety concerns",
    "weather": "string — clear / rain / snow / fog / cloudy / unknown",
    "time_of_day": "string — dawn / day / dusk / night / unknown",
}


def make_session(max_retries: int) -> requests.Session:
    """Build a requests.Session with retry logic for transient HTTP errors."""
    session = requests.Session()
    retry = Retry(
        total=max_retries,
        backoff_factor=1.0,
        status_forcelist=[429, 502, 503, 504],
        allowed_methods=["POST"],
    )
    session.mount("http://", HTTPAdapter(max_retries=retry))
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def extract_json_from_answer(answer: str) -> Optional[dict]:
    """Try hard to pull a JSON object out of the model's <answer> block."""
    if not answer:
        return None
    # JSON inside ```json ... ``` fence
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", answer, re.DOTALL)
    if fence:
        try:
            return json.loads(fence.group(1))
        except json.JSONDecodeError:
            pass
    # Bare JSON object
    bare = re.search(r"\{.*\}", answer, re.DOTALL)
    if bare:
        try:
            return json.loads(bare.group(0))
        except json.JSONDecodeError:
            pass
    return None


def label_image(image_path: Path, endpoint: str, model: str, schema: dict,
                max_tokens: int, session: requests.Session, verify_tls: bool) -> dict:
    image_url = encode_image(str(image_path))

    system = (
        "You are auto-labeling driving scenes for AV training data. "
        "Output your reasoning in <think>...</think>, then output a JSON label "
        f"in <answer>...</answer> matching this schema: {json.dumps(schema)}"
    )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": image_url}},
                {"type": "text", "text": "Label this scene."},
            ]},
        ],
        "max_tokens": max_tokens,
        "temperature": 0.4,
    }

    start = time.monotonic()
    r = session.post(f"{endpoint}/v1/chat/completions",
                     headers={"Content-Type": "application/json"},
                     json=payload,
                     verify=verify_tls,
                     timeout=300)
    elapsed_ms = int((time.monotonic() - start) * 1000)
    r.raise_for_status()
    data = r.json()

    msg = data["choices"][0]["message"]
    reasoning, answer = parse_reasoning_response(msg)
    label = extract_json_from_answer(answer)

    return {
        "image": str(image_path),
        "elapsed_ms": elapsed_ms,
        "completion_tokens": data["usage"]["completion_tokens"],
        "label": label,
        "reasoning": reasoning,
        "raw_answer": answer if not label else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default=os.environ.get("ENDPOINT", "http://localhost:8000"))
    parser.add_argument("--model", default=os.environ.get("MODEL_ID", "nvidia/Cosmos-Reason1-7B"))
    parser.add_argument("--image-dir", required=True, help="Directory containing images to label")
    parser.add_argument("--output", default="labels.jsonl", help="JSONL output path")
    parser.add_argument("--schema", help="Path to a JSON file with the label schema (overrides default)")
    parser.add_argument("--max-tokens", type=int, default=800)
    parser.add_argument("--limit", type=int, default=0,
                        help="Process at most N images (0 = unlimited)")
    parser.add_argument("--max-retries", type=int, default=3,
                        help="Max retries per image on transient HTTP errors (429/502/503/504)")
    parser.add_argument("--insecure", action="store_true",
                        help="Disable TLS certificate verification (for self-signed certs)")
    args = parser.parse_args()

    verify_tls = not args.insecure
    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    session = make_session(args.max_retries)

    schema = DEFAULT_SCHEMA
    if args.schema:
        with open(args.schema) as f:
            schema = json.load(f)

    image_dir = Path(args.image_dir)
    images = sorted([p for p in image_dir.iterdir()
                     if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}])
    if args.limit > 0:
        images = images[:args.limit]

    if not images:
        print(f"No images found in {image_dir}", file=sys.stderr)
        return 1

    print(f"Labeling {len(images)} images against {args.endpoint} ({args.model})...")

    with open(args.output, "w") as out:
        for i, img in enumerate(images, 1):
            try:
                result = label_image(img, args.endpoint, args.model, schema,
                                     args.max_tokens, session, verify_tls)
                out.write(json.dumps(result) + "\n")
                out.flush()
                ok = "OK" if result["label"] else "PARSE_FAILED"
                print(f"  [{i}/{len(images)}] {img.name} {ok} ({result['elapsed_ms']} ms)")
            except Exception as exc:  # noqa: BLE001
                err = {"image": str(img), "error": str(exc)}
                out.write(json.dumps(err) + "\n")
                out.flush()
                print(f"  [{i}/{len(images)}] {img.name} ERROR: {exc}", file=sys.stderr)

    print(f"\nWrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
