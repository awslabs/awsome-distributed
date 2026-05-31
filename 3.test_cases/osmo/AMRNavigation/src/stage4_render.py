#!/usr/bin/env python3
"""Stage 4: Multi-Modal Rendering.

Downloads scene USD + trajectories from S3, replays each trajectory
with camera poses, and renders RGB/depth/segmentation data using
CosmosWriter (with BasicWriter fallback). Uploads raw-v1/ to S3.

Usage (inside Isaac Sim container):
    /isaac-sim/python.sh /isaac-sim/scripts/stage4_render.py \
        --s3_bucket my-bucket --run_id run-001
"""

import argparse
import functools
import json
import os
import sys

print = functools.partial(print, flush=True)

# Ensure utils package is importable
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else "/isaac-sim/scripts"
for _p in [_SCRIPTS_DIR, "/isaac-sim/scripts"]:
    if _p not in sys.path:
        sys.path.insert(0, _p)


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 4: Multi-Modal Rendering")
    parser.add_argument("--s3_bucket", type=str, required=True)
    parser.add_argument("--run_id", type=str, required=True)
    parser.add_argument("--output_dir", type=str, default="/output/raw-v1")
    parser.add_argument("--scene_dir", type=str, default="/input/scene")
    parser.add_argument("--trajectory_dir", type=str, default="/input/trajectories")
    parser.add_argument("--image_width", type=int, default=640)
    parser.add_argument("--image_height", type=int, default=480)
    parser.add_argument("--headless", action="store_true", default=True)
    return parser.parse_args()


def setup_writer(output_dir, use_cosmos=False):
    """Set up Replicator writer. Try CosmosWriter, fallback to BasicWriter."""
    import omni.replicator.core as rep

    if use_cosmos:
        try:
            writer = rep.writers.get("CosmosWriter")
            writer.initialize(
                output_dir=output_dir,
                rgb=True,
                depth=True,
                semantic_segmentation=True,
            )
            print("[Stage4] Using CosmosWriter")
            return writer, "cosmos"
        except Exception as e:
            print(f"[Stage4] CosmosWriter not available ({e}), falling back to BasicWriter")

    writer = rep.writers.get("BasicWriter")
    writer.initialize(
        output_dir=output_dir,
        rgb=True,
        distance_to_image_plane=True,
        semantic_segmentation=True,
    )
    print("[Stage4] Using BasicWriter")
    return writer, "basic"


def reorganize_basic_to_cosmos_layout(output_dir):
    """Reorganize BasicWriter output to Cosmos Transfer-compatible layout.

    BasicWriter outputs:
        output_dir/rgb/frame_XXXX.png
        output_dir/distance_to_image_plane/frame_XXXX.npy
        output_dir/semantic_segmentation/frame_XXXX.png

    Cosmos layout expects:
        output_dir/rgb/frame_XXXXXX.png
        output_dir/depth/frame_XXXXXX.npy
        output_dir/semantic_segmentation/frame_XXXXXX.png
    """
    import shutil

    # Rename depth directory
    old_depth = os.path.join(output_dir, "distance_to_image_plane")
    new_depth = os.path.join(output_dir, "depth")
    if os.path.exists(old_depth) and not os.path.exists(new_depth):
        shutil.move(old_depth, new_depth)
        print(f"[Stage4] Renamed distance_to_image_plane -> depth")


def main():
    args = parse_args()
    print("[Stage4] Starting multi-modal rendering")

    from amr_utils.s3_sync import download_directory, upload_directory, make_stage_path

    # Download inputs
    scene_s3 = make_stage_path(args.s3_bucket, args.run_id, "scene")
    traj_s3 = make_stage_path(args.s3_bucket, args.run_id, "trajectories")

    print(f"[Stage4] Downloading scene from {scene_s3}")
    download_directory(scene_s3, args.scene_dir)

    print(f"[Stage4] Downloading trajectories from {traj_s3}")
    download_directory(traj_s3, args.trajectory_dir)

    usd_path = os.path.join(args.scene_dir, "warehouse_scene.usd")

    # Load trajectory files
    traj_files = sorted([
        f for f in os.listdir(args.trajectory_dir)
        if f.startswith("trajectory_") and f.endswith(".json")
    ])
    print(f"[Stage4] Found {len(traj_files)} trajectories to render")

    from isaacsim import SimulationApp
    simulation_app = SimulationApp({
        "headless": args.headless,
        "width": args.image_width,
        "height": args.image_height,
    })

    # Re-add scripts dir — SimulationApp init may reset sys.path
    if "/isaac-sim/scripts" not in sys.path:
        sys.path.insert(0, "/isaac-sim/scripts")

    import omni.replicator.core as rep
    import omni.usd
    import carb.settings

    carb.settings.get_settings().set("rtx/post/dlss/execMode", 2)

    print(f"[Stage4] Opening scene: {usd_path}")
    omni.usd.get_context().open_stage(usd_path)

    rep.orchestrator.set_capture_on_play(False)

    # Create camera
    camera = rep.create.camera(position=(0, 0, 1), look_at=(1, 0, 1))
    render_product = rep.create.render_product(
        camera, (args.image_width, args.image_height)
    )

    os.makedirs(args.output_dir, exist_ok=True)
    writer, writer_type = setup_writer(args.output_dir, use_cosmos=True)
    writer.attach([render_product])

    total_frames = 0

    for traj_file in traj_files:
        traj_path = os.path.join(args.trajectory_dir, traj_file)
        with open(traj_path) as f:
            trajectory = json.load(f)

        frames = trajectory["frames"]
        traj_name = os.path.splitext(traj_file)[0]
        print(f"[Stage4] Rendering {traj_name}: {len(frames)} frames")

        for frame_data in frames:
            pos = frame_data["position"]
            rot = frame_data["rotation"]  # qw, qx, qy, qz

            # Compute look-at point from quaternion (forward direction)
            qw, qx, qy, qz = rot
            # Forward vector from quaternion (assuming forward = +X)
            fx = 1 - 2 * (qy * qy + qz * qz)
            fy = 2 * (qx * qy + qw * qz)
            fz = 2 * (qx * qz - qw * qy)
            look_at = (pos[0] + fx * 2, pos[1] + fy * 2, pos[2] + fz * 2)

            with rep.trigger.on_frame():
                with camera:
                    rep.modify.pose(
                        position=tuple(pos),
                        look_at=look_at,
                    )

            rep.orchestrator.step()
            total_frames += 1

        print(f"[Stage4] {traj_name} complete")

    writer.detach()
    rep.orchestrator.wait_until_complete()

    # Reorganize to Cosmos-compatible layout if using BasicWriter
    if writer_type == "basic":
        reorganize_basic_to_cosmos_layout(args.output_dir)

    # Count output files
    file_count = 0
    for root, _dirs, files in os.walk(args.output_dir):
        for f in files:
            file_count += 1
            if file_count <= 5:
                fpath = os.path.join(root, f)
                size_mb = os.path.getsize(fpath) / (1024 * 1024)
                print(f"  {os.path.relpath(fpath, args.output_dir)} ({size_mb:.1f} MB)")

    print(f"[Stage4] Total: {total_frames} frames rendered, {file_count} files")

    # Upload to S3
    s3_path = make_stage_path(args.s3_bucket, args.run_id, "raw-v1")
    print(f"[Stage4] Uploading to {s3_path}")
    upload_directory(args.output_dir, s3_path)

    simulation_app.close()
    print("[Stage4] Done.")


if __name__ == "__main__":
    main()
