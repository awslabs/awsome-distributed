#!/usr/bin/env python3
"""Stage 5: Domain Augmentation.

Downloads raw-v1/ from S3, applies visual domain augmentations, and
uploads augmented-v2/ to S3. The augmentation pipeline is Cosmos
Transfer-compatible: if the cosmos_transfer package is installed in
the container image, it will be used. Otherwise, falls back to
torchvision transforms (ColorJitter, sharpness, blur) which produce
varied appearance while preserving scene structure.

Usage:
    python /scripts/stage5_domain_augment.py \
        --s3_bucket my-bucket --run_id run-001
"""

import argparse
import functools
import json
import os
import sys

print = functools.partial(print, flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 5: Domain Augmentation")
    parser.add_argument("--s3_bucket", type=str, required=True)
    parser.add_argument("--run_id", type=str, required=True)
    parser.add_argument("--input_dir", type=str, default="/input/raw-v1")
    parser.add_argument("--output_dir", type=str, default="/output/augmented-v2")
    parser.add_argument("--num_variants", type=int, default=1, help="Augmented variants per input")
    return parser.parse_args()


def try_cosmos_transfer(input_dir, output_dir):
    """Try to use Cosmos Transfer for domain augmentation."""
    try:
        from cosmos_transfer import CosmosTransfer
        model = CosmosTransfer.load()
        model.transfer(input_dir=input_dir, output_dir=output_dir)
        return True
    except ImportError:
        return False
    except Exception as e:
        print(f"[Stage5] Cosmos Transfer failed: {e}")
        return False


def torchvision_augment(input_dir, output_dir, num_variants=1):
    """Fallback augmentation using torchvision transforms.

    Handles both flat layout (BasicWriter: rgb_XXXX.png in root) and
    subdirectory layout (CosmosWriter: rgb/frame_XXXXXX.png).
    """
    import shutil
    import numpy as np
    from PIL import Image
    from torchvision import transforms

    augment_pipeline = transforms.Compose([
        transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.3, hue=0.1),
        transforms.RandomAdjustSharpness(sharpness_factor=2.0, p=0.5),
        transforms.GaussianBlur(kernel_size=3, sigma=(0.1, 1.0)),
    ])

    # Detect layout: subdirectory (rgb/) or flat (rgb_XXXX.png in root)
    rgb_subdir = os.path.join(input_dir, "rgb")
    flat_layout = not os.path.isdir(rgb_subdir)

    if flat_layout:
        # Flat layout: rgb_XXXX.png, distance_to_image_plane_XXXX.npy, etc.
        print("[Stage5] Detected flat output layout (BasicWriter)")
        os.makedirs(output_dir, exist_ok=True)

        # Copy non-RGB files unchanged
        for fname in os.listdir(input_dir):
            src_file = os.path.join(input_dir, fname)
            if not os.path.isfile(src_file):
                continue
            if not fname.startswith("rgb_"):
                shutil.copy2(src_file, os.path.join(output_dir, fname))

        # Augment RGB files
        rgb_files = sorted([
            f for f in os.listdir(input_dir)
            if f.startswith("rgb_") and f.lower().endswith((".png", ".jpg", ".jpeg"))
        ])
    else:
        # Subdirectory layout: rgb/, depth/, semantic_segmentation/
        print("[Stage5] Detected subdirectory layout")
        rgb_out = os.path.join(output_dir, "rgb")
        os.makedirs(rgb_out, exist_ok=True)

        # Copy depth and segmentation unchanged
        for subdir in ["depth", "semantic_segmentation"]:
            src = os.path.join(input_dir, subdir)
            dst = os.path.join(output_dir, subdir)
            if os.path.exists(src):
                os.makedirs(dst, exist_ok=True)
                for fname in os.listdir(src):
                    shutil.copy2(os.path.join(src, fname), os.path.join(dst, fname))

        rgb_files = sorted([
            f for f in os.listdir(rgb_subdir)
            if f.lower().endswith((".png", ".jpg", ".jpeg"))
        ])

    if not rgb_files:
        print("[Stage5] Warning: No RGB files found in input")
        return 0

    print(f"[Stage5] Found {len(rgb_files)} RGB files to augment")

    frame_count = 0
    for fname in rgb_files:
        src_path = os.path.join(input_dir, fname) if flat_layout else os.path.join(rgb_subdir, fname)
        dst_dir = output_dir if flat_layout else os.path.join(output_dir, "rgb")

        img = Image.open(src_path).convert("RGB")

        for v in range(num_variants):
            augmented = augment_pipeline(img)
            if num_variants > 1:
                base, ext = os.path.splitext(fname)
                out_name = f"{base}_v{v}{ext}"
            else:
                out_name = fname
            augmented.save(os.path.join(dst_dir, out_name))
            frame_count += 1

    return frame_count


def main():
    args = parse_args()
    print("[Stage5] Starting domain augmentation")

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from amr_utils.s3_sync import download_directory, upload_directory, make_stage_path

    # Download raw renders
    raw_s3 = make_stage_path(args.s3_bucket, args.run_id, "raw-v1")
    print(f"[Stage5] Downloading raw data from {raw_s3}")
    download_directory(raw_s3, args.input_dir)

    os.makedirs(args.output_dir, exist_ok=True)

    # Try Cosmos Transfer first, fallback to torchvision
    print("[Stage5] Attempting Cosmos Transfer...")
    if try_cosmos_transfer(args.input_dir, args.output_dir):
        print("[Stage5] Cosmos Transfer completed successfully")
    else:
        print("[Stage5] Using torchvision augmentation fallback")
        count = torchvision_augment(args.input_dir, args.output_dir, args.num_variants)
        print(f"[Stage5] Augmented {count} frames")

    # Count output
    file_count = sum(len(files) for _, _, files in os.walk(args.output_dir))
    print(f"[Stage5] Output: {file_count} files in {args.output_dir}")

    # Upload to S3
    s3_path = make_stage_path(args.s3_bucket, args.run_id, "augmented-v2")
    print(f"[Stage5] Uploading to {s3_path}")
    upload_directory(args.output_dir, s3_path)

    print("[Stage5] Done.")


if __name__ == "__main__":
    main()
