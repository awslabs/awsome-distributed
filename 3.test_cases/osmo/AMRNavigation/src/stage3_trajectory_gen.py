#!/usr/bin/env python3
"""Stage 3: Trajectory Generation.

Downloads scene and occupancy map from S3, runs A* path planning on the
occupancy grid, and generates N trajectory JSONs with camera poses.

Usage (inside Isaac Sim container):
    /isaac-sim/python.sh /isaac-sim/scripts/stage3_trajectory_gen.py \
        --s3_bucket my-bucket --run_id run-001 --num_trajectories 10
"""

import argparse
import functools
import heapq
import json
import math
import os
import random
import sys

print = functools.partial(print, flush=True)

# Ensure utils package is importable
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else "/isaac-sim/scripts"
for _p in [_SCRIPTS_DIR, "/isaac-sim/scripts"]:
    if _p not in sys.path:
        sys.path.insert(0, _p)

import numpy as np


def parse_args():
    parser = argparse.ArgumentParser(description="Stage 3: Trajectory Generation")
    parser.add_argument("--s3_bucket", type=str, required=True)
    parser.add_argument("--run_id", type=str, required=True)
    parser.add_argument("--output_dir", type=str, default="/output/trajectories")
    parser.add_argument("--occupancy_dir", type=str, default="/input/occupancy")
    parser.add_argument("--num_trajectories", type=int, default=10)
    parser.add_argument("--num_frames", type=int, default=100, help="Frames per trajectory")
    parser.add_argument("--camera_height", type=float, default=1.0, help="Camera height in meters")
    parser.add_argument("--headless", action="store_true", default=True)
    return parser.parse_args()


def astar(grid, start, goal):
    """A* path planning on a 2D occupancy grid.

    Args:
        grid: 2D numpy array (0=free, 1=occupied)
        start: (row, col) tuple
        goal: (row, col) tuple

    Returns:
        List of (row, col) waypoints from start to goal, or None if no path.
    """
    rows, cols = grid.shape

    def heuristic(a, b):
        return abs(a[0] - b[0]) + abs(a[1] - b[1])

    def neighbors(pos):
        for dr, dc in [(-1, 0), (1, 0), (0, -1), (0, 1),
                        (-1, -1), (-1, 1), (1, -1), (1, 1)]:
            nr, nc = pos[0] + dr, pos[1] + dc
            if 0 <= nr < rows and 0 <= nc < cols and grid[nr, nc] == 0:
                yield (nr, nc)

    open_set = [(0, start)]
    came_from = {}
    g_score = {start: 0}

    while open_set:
        _, current = heapq.heappop(open_set)

        if current == goal:
            path = []
            while current in came_from:
                path.append(current)
                current = came_from[current]
            path.append(start)
            return path[::-1]

        for nb in neighbors(current):
            tentative = g_score[current] + (1.414 if (nb[0] != current[0] and nb[1] != current[1]) else 1.0)
            if tentative < g_score.get(nb, float("inf")):
                came_from[nb] = current
                g_score[nb] = tentative
                heapq.heappush(open_set, (tentative + heuristic(nb, goal), nb))

    return None


def smooth_path(path, num_points):
    """Resample path to num_points using cubic interpolation."""
    if len(path) < 2:
        return path

    path = np.array(path, dtype=float)
    # Compute cumulative distance along path
    diffs = np.diff(path, axis=0)
    distances = np.sqrt((diffs ** 2).sum(axis=1))
    cumulative = np.concatenate([[0], np.cumsum(distances)])
    total = cumulative[-1]

    if total < 1e-6:
        return [tuple(path[0])] * num_points

    # Linearly interpolate at uniform spacing
    target_distances = np.linspace(0, total, num_points)
    smooth = np.zeros((num_points, 2))
    for i, t in enumerate(target_distances):
        idx = np.searchsorted(cumulative, t, side="right") - 1
        idx = max(0, min(idx, len(path) - 2))
        segment_len = cumulative[idx + 1] - cumulative[idx]
        if segment_len < 1e-8:
            smooth[i] = path[idx]
        else:
            alpha = (t - cumulative[idx]) / segment_len
            smooth[i] = path[idx] * (1 - alpha) + path[idx + 1] * alpha

    return [tuple(p) for p in smooth]


def grid_to_world(row, col, metadata):
    """Convert grid cell to world coordinates."""
    x = metadata["origin_x"] + col * metadata["resolution"]
    y = metadata["origin_y"] + row * metadata["resolution"]
    return x, y


def compute_orientation(current_pos, next_pos):
    """Compute quaternion (qw, qx, qy, qz) facing from current to next position."""
    dx = next_pos[0] - current_pos[0]
    dy = next_pos[1] - current_pos[1]
    yaw = math.atan2(dy, dx)

    # Convert yaw to quaternion (rotation around Z axis)
    qw = math.cos(yaw / 2)
    qx = 0.0
    qy = 0.0
    qz = math.sin(yaw / 2)
    return [qw, qx, qy, qz]


def main():
    args = parse_args()
    print("[Stage3] Starting trajectory generation")

    from amr_utils.s3_sync import download_directory, upload_directory, make_stage_path

    # Download occupancy map
    occ_s3 = make_stage_path(args.s3_bucket, args.run_id, "occupancy")
    print(f"[Stage3] Downloading occupancy from {occ_s3}")
    download_directory(occ_s3, args.occupancy_dir)

    occupancy = np.load(os.path.join(args.occupancy_dir, "occupancy_map.npy"))
    with open(os.path.join(args.occupancy_dir, "metadata.json")) as f:
        occ_meta = json.load(f)

    print(f"[Stage3] Occupancy grid: {occupancy.shape}, "
          f"free cells: {(occupancy == 0).sum()}")

    # Find free cells for start/end sampling
    free_cells = list(zip(*np.where(occupancy == 0)))
    if len(free_cells) < 2:
        print("[Stage3] ERROR: Not enough free cells for path planning")
        sys.exit(1)

    # Add margin: only use cells at least 3 cells from any obstacle
    from scipy.ndimage import binary_dilation
    dilated = binary_dilation(occupancy, iterations=3)
    safe_cells = list(zip(*np.where((occupancy == 0) & (~dilated))))

    # Fall back to all free cells if safe set is too small
    if len(safe_cells) < 100:
        print("[Stage3] Warning: Few safe cells, using all free cells")
        safe_cells = free_cells

    os.makedirs(args.output_dir, exist_ok=True)

    trajectories_generated = 0
    max_attempts = args.num_trajectories * 5

    for attempt in range(max_attempts):
        if trajectories_generated >= args.num_trajectories:
            break

        # Sample random start/end
        start = random.choice(safe_cells)
        goal = random.choice(safe_cells)

        # Ensure minimum distance
        dist = math.sqrt((start[0] - goal[0])**2 + (start[1] - goal[1])**2)
        if dist < 20:  # At least 20 cells apart
            continue

        path = astar(occupancy, start, goal)
        if path is None or len(path) < 5:
            continue

        # Smooth and resample
        smooth = smooth_path(path, args.num_frames)

        # Convert to world coordinates with camera poses
        frames = []
        for frame_idx, (row, col) in enumerate(smooth):
            wx, wy = grid_to_world(row, col, occ_meta)

            # Look ahead for orientation
            if frame_idx < len(smooth) - 1:
                next_row, next_col = smooth[frame_idx + 1]
                nwx, nwy = grid_to_world(next_row, next_col, occ_meta)
                orientation = compute_orientation((wx, wy), (nwx, nwy))
            else:
                orientation = frames[-1]["rotation"] if frames else [1, 0, 0, 0]

            frames.append({
                "frame": frame_idx,
                "position": [wx, wy, args.camera_height],
                "rotation": orientation,
            })

        traj_path = os.path.join(args.output_dir, f"trajectory_{trajectories_generated:04d}.json")
        with open(traj_path, "w") as f:
            json.dump({"frames": frames, "num_frames": len(frames)}, f, indent=2)

        trajectories_generated += 1
        print(f"[Stage3] Trajectory {trajectories_generated}/{args.num_trajectories}: "
              f"{len(frames)} frames, path length {len(path)} cells")

    if trajectories_generated < args.num_trajectories:
        print(f"[Stage3] Warning: Only generated {trajectories_generated}/{args.num_trajectories} trajectories")

    # Write summary
    summary = {
        "num_trajectories": trajectories_generated,
        "num_frames_per_trajectory": args.num_frames,
        "camera_height": args.camera_height,
    }
    with open(os.path.join(args.output_dir, "metadata.json"), "w") as f:
        json.dump(summary, f, indent=2)

    # Upload to S3
    s3_path = make_stage_path(args.s3_bucket, args.run_id, "trajectories")
    print(f"[Stage3] Uploading to {s3_path}")
    upload_directory(args.output_dir, s3_path)

    print(f"[Stage3] Done. Generated {trajectories_generated} trajectories.")


if __name__ == "__main__":
    main()
