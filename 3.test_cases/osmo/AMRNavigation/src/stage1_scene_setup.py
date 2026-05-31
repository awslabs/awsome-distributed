#!/usr/bin/env python3
"""Stage 1: Warehouse Scene Setup.

Builds a procedural warehouse USD scene with shelves, pallets, floor,
lighting, and semantic labels. Exports the scene to a local directory
and uploads to S3 for downstream stages.

Usage (inside Isaac Sim container):
    /isaac-sim/python.sh /isaac-sim/scripts/stage1_scene_setup.py \
        --s3_bucket my-bucket --run_id run-001 --output_dir /output/scene
"""

import argparse
import functools
import json
import os
import sys

print = functools.partial(print, flush=True)

# Ensure utils package is importable — must happen before any delayed imports
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else "/isaac-sim/scripts"
for _p in [_SCRIPTS_DIR, "/isaac-sim/scripts"]:
    if _p not in sys.path:
        sys.path.insert(0, _p)


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 1: Warehouse Scene Setup")
    parser.add_argument("--s3_bucket", type=str, required=True, help="S3 bucket for pipeline data")
    parser.add_argument("--run_id", type=str, required=True, help="Pipeline run identifier")
    parser.add_argument("--output_dir", type=str, default="/output/scene", help="Local output directory")
    parser.add_argument("--num_aisles", type=int, default=4, help="Number of warehouse aisles")
    parser.add_argument("--aisle_length", type=float, default=20.0, help="Length of each aisle in meters")
    parser.add_argument("--headless", action="store_true", default=True)
    return parser.parse_args()


def main():
    args = parse_args()
    print("[Stage1] Starting warehouse scene setup")

    from isaacsim import SimulationApp
    simulation_app = SimulationApp({"headless": args.headless, "width": 640, "height": 480})

    # Re-add scripts dir — SimulationApp init may reset sys.path
    if "/isaac-sim/scripts" not in sys.path:
        sys.path.insert(0, "/isaac-sim/scripts")

    import omni.usd
    import carb.settings
    import omni.replicator.core as rep

    omni.usd.get_context().new_stage()
    rep.orchestrator.set_capture_on_play(False)
    carb.settings.get_settings().set("rtx/post/dlss/execMode", 2)

    stage = omni.usd.get_context().get_stage()

    from amr_utils.scene_builder import build_warehouse_scene

    scene_config = {
        "num_aisles": args.num_aisles,
        "aisle_length": args.aisle_length,
    }
    prims = build_warehouse_scene(stage, scene_config)

    os.makedirs(args.output_dir, exist_ok=True)
    usd_path = os.path.join(args.output_dir, "warehouse_scene.usd")

    print(f"[Stage1] Exporting scene to {usd_path}")
    stage.GetRootLayer().Export(usd_path)

    # Write metadata
    metadata = {
        "num_aisles": args.num_aisles,
        "aisle_length": args.aisle_length,
        "num_shelves": len(prims["shelves"]),
        "num_pallets": len(prims["pallets"]),
        "num_walls": len(prims["walls"]),
        "usd_file": "warehouse_scene.usd",
    }
    meta_path = os.path.join(args.output_dir, "metadata.json")
    with open(meta_path, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"[Stage1] Scene metadata: {metadata}")

    # Verify prims
    prim_count = 0
    for prim in stage.Traverse():
        prim_count += 1
    print(f"[Stage1] Total prims in scene: {prim_count}")

    # Upload to S3
    from amr_utils.s3_sync import upload_directory, make_stage_path
    s3_path = make_stage_path(args.s3_bucket, args.run_id, "scene")
    print(f"[Stage1] Uploading to {s3_path}")
    upload_directory(args.output_dir, s3_path)

    simulation_app.close()
    print("[Stage1] Done.")


if __name__ == "__main__":
    main()
