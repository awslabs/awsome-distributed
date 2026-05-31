#!/usr/bin/env python3
"""Stage 2: Occupancy Map Generation.

Downloads the warehouse USD scene from S3, computes a 2D occupancy grid
directly from prim bounding boxes (no rendering required), and uploads.

Usage (inside Isaac Sim container):
    /isaac-sim/python.sh /isaac-sim/scripts/stage2_occupancy_map.py \
        --s3_bucket my-bucket --run_id run-001
"""

import argparse
import functools
import json
import os
import sys

print = functools.partial(print, flush=True)

# Ensure amr_utils package is importable
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else "/isaac-sim/scripts"
for _p in [_SCRIPTS_DIR, "/isaac-sim/scripts"]:
    if _p not in sys.path:
        sys.path.insert(0, _p)


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 2: Occupancy Map Generation")
    parser.add_argument("--s3_bucket", type=str, required=True)
    parser.add_argument("--run_id", type=str, required=True)
    parser.add_argument("--output_dir", type=str, default="/output/occupancy")
    parser.add_argument("--scene_dir", type=str, default="/input/scene")
    parser.add_argument("--resolution", type=float, default=0.1, help="Grid resolution in meters/pixel")
    parser.add_argument("--headless", action="store_true", default=True)
    return parser.parse_args()


def main():
    args = parse_args()
    print("[Stage2] Starting occupancy map generation")

    from amr_utils.s3_sync import download_directory, upload_directory, make_stage_path

    scene_s3 = make_stage_path(args.s3_bucket, args.run_id, "scene")
    print(f"[Stage2] Downloading scene from {scene_s3}")
    download_directory(scene_s3, args.scene_dir)

    usd_path = os.path.join(args.scene_dir, "warehouse_scene.usd")
    meta_path = os.path.join(args.scene_dir, "metadata.json")

    with open(meta_path) as f:
        scene_meta = json.load(f)

    from isaacsim import SimulationApp
    simulation_app = SimulationApp({"headless": args.headless, "width": 640, "height": 480})

    if "/isaac-sim/scripts" not in sys.path:
        sys.path.insert(0, "/isaac-sim/scripts")

    import numpy as np
    import omni.usd

    print(f"[Stage2] Opening scene: {usd_path}")
    omni.usd.get_context().open_stage(usd_path)
    stage = omni.usd.get_context().get_stage()

    from pxr import Gf, UsdGeom

    # Compute scene bounds from metadata
    aisle_length = scene_meta.get("aisle_length", 20.0)
    num_aisles = scene_meta.get("num_aisles", 4)
    aisle_width = 3.0
    shelf_depth = 1.0
    total_width = num_aisles * (aisle_width + shelf_depth * 2)

    # Grid covers the scene with padding
    padding = 2.0
    origin_x = -padding
    origin_y = -(total_width / 2 + padding)
    extent_x = aisle_length + 2 * padding
    extent_y = total_width + 2 * padding

    grid_w = int(extent_x / args.resolution)
    grid_h = int(extent_y / args.resolution)
    occupancy = np.zeros((grid_h, grid_w), dtype=np.uint8)

    print(f"[Stage2] Grid: {grid_w}x{grid_h}, resolution: {args.resolution} m/px")

    # Rasterize each obstacle prim into the occupancy grid
    obstacle_count = 0
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Cube):
            continue
        path = str(prim.GetPath())
        # Skip the floor (large ground plane)
        if "Floor" in path or "Ground" in path:
            continue

        xformable = UsdGeom.Xformable(prim)
        xform_ops = xformable.GetOrderedXformOps()

        translate = Gf.Vec3d(0, 0, 0)
        scale = Gf.Vec3d(1, 1, 1)
        for op in xform_ops:
            if op.GetOpType() == UsdGeom.XformOp.TypeTranslate:
                translate = op.Get()
            elif op.GetOpType() == UsdGeom.XformOp.TypeScale:
                scale = op.Get()

        # Cube default extent is [-1,1] in each axis, so half-size = scale
        min_x = translate[0] - abs(scale[0])
        max_x = translate[0] + abs(scale[0])
        min_y = translate[1] - abs(scale[1])
        max_y = translate[1] + abs(scale[1])

        # Convert to grid coordinates
        col_min = max(0, int((min_x - origin_x) / args.resolution))
        col_max = min(grid_w, int((max_x - origin_x) / args.resolution))
        row_min = max(0, int((min_y - origin_y) / args.resolution))
        row_max = min(grid_h, int((max_y - origin_y) / args.resolution))

        if col_min < col_max and row_min < row_max:
            occupancy[row_min:row_max, col_min:col_max] = 1
            obstacle_count += 1

    print(f"[Stage2] Rasterized {obstacle_count} obstacle prims")
    print(f"[Stage2] Occupancy: {occupancy.sum()} occupied cells, "
          f"{(occupancy == 0).sum()} free cells out of {occupancy.size} total")

    os.makedirs(args.output_dir, exist_ok=True)

    # Save occupancy grid
    np.save(os.path.join(args.output_dir, "occupancy_map.npy"), occupancy)

    # Save visualization PNG
    from PIL import Image
    vis = np.zeros((*occupancy.shape, 3), dtype=np.uint8)
    vis[occupancy == 0] = [255, 255, 255]  # Free = white
    vis[occupancy == 1] = [0, 0, 0]        # Occupied = black
    Image.fromarray(vis).save(os.path.join(args.output_dir, "occupancy_map.png"))

    # Save metadata
    occ_metadata = {
        "width": grid_w,
        "height": grid_h,
        "resolution": args.resolution,
        "origin_x": origin_x,
        "origin_y": origin_y,
        "occupied_cells": int(occupancy.sum()),
        "free_cells": int((occupancy == 0).sum()),
    }
    with open(os.path.join(args.output_dir, "metadata.json"), "w") as f:
        json.dump(occ_metadata, f, indent=2)

    # Upload to S3
    s3_path = make_stage_path(args.s3_bucket, args.run_id, "occupancy")
    print(f"[Stage2] Uploading to {s3_path}")
    upload_directory(args.output_dir, s3_path)

    simulation_app.close()
    print("[Stage2] Done.")


if __name__ == "__main__":
    main()
