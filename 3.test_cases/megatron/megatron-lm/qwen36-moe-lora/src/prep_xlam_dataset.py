# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Convert xLAM-60k function-calling dataset to Megatron-Bridge SFT JSONL.

Reads the parsed parquet files from HF hub and emits two JSONL files:
  <output-dir>/training.jsonl
  <output-dir>/validation.jsonl

Each line is:  {"input": "<tools JSON>\\n\\n<user message>", "output": "<tool call JSON>"}

These file names are what Megatron-Bridge's FinetuningDatasetBuilder expects when
the recipe's dataset_type is set to 'llm-finetune-preloaded'.

Usage:
    python prep_xlam_dataset.py --output-dir /fsx/datasets
"""
import argparse
import json
import os
import random
from pathlib import Path

from datasets import load_dataset


HF_DATASET_ID = "minpeter/xlam-function-calling-60k-parsed"
DEFAULT_VAL_RATIO = 0.02   # 98/2 train/val split


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--output-dir", required=True, help="Directory to write training.jsonl and validation.jsonl")
    p.add_argument("--dataset-id", default=HF_DATASET_ID,
                   help=f"HF dataset ID (default: {HF_DATASET_ID})")
    p.add_argument("--val-ratio", type=float, default=DEFAULT_VAL_RATIO,
                   help=f"Validation split ratio (default: {DEFAULT_VAL_RATIO})")
    p.add_argument("--seed", type=int, default=42, help="Shuffle seed")
    p.add_argument("--max-samples", type=int, default=None,
                   help="Optional cap on total samples (for smoke tests)")
    return p.parse_args()


def build_row(row):
    """Convert one xLAM row to {input, output} SFT format.

    xLAM schema:
      row["messages"] = [
          {"role": "system", "content": "..."},   # optional
          {"role": "user", "content": "..."},
          {"role": "assistant", "content": null, "tool_calls": [{...}, ...]},
      ]
      row["tools"] = [{"type":"function","function":{"name":"...","parameters":{...}}}, ...]
    """
    tools = row.get("tools") or []
    messages = row.get("messages") or []

    user_msg = next((m for m in messages if m.get("role") == "user"), None)
    asst_msg = next((m for m in messages if m.get("role") == "assistant"), None)
    if user_msg is None or asst_msg is None:
        return None

    # The assistant message carries tool_calls (content is usually null).
    tool_calls = asst_msg.get("tool_calls") or []
    if not tool_calls:
        return None

    input_text = (
        f"You have access to the following tools:\n"
        f"{json.dumps(tools, separators=(',', ':'))}\n\n"
        f"User: {user_msg['content']}"
    )
    output_text = json.dumps(tool_calls, separators=(',', ':'))
    return {"input": input_text, "output": output_text}


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    print(f"Loading {args.dataset_id}...")
    ds = load_dataset(args.dataset_id, split="train")
    print(f"  Loaded {len(ds)} raw rows")

    rows = []
    for row in ds:
        converted = build_row(row)
        if converted is not None:
            rows.append(converted)
    print(f"  Converted {len(rows)} rows (dropped {len(ds) - len(rows)} with missing/empty assistants)")

    if args.max_samples is not None and args.max_samples < len(rows):
        rows = rows[: args.max_samples]

    random.seed(args.seed)
    random.shuffle(rows)

    n_val = max(1, int(len(rows) * args.val_ratio))
    val_rows = rows[:n_val]
    train_rows = rows[n_val:]

    train_path = Path(args.output_dir) / "training.jsonl"
    val_path = Path(args.output_dir) / "validation.jsonl"
    with open(train_path, "w") as f:
        for r in train_rows:
            f.write(json.dumps(r) + "\n")
    with open(val_path, "w") as f:
        for r in val_rows:
            f.write(json.dumps(r) + "\n")

    print(f"Wrote {len(train_rows)} training rows -> {train_path}")
    print(f"Wrote {len(val_rows)} validation rows -> {val_path}")


if __name__ == "__main__":
    main()
