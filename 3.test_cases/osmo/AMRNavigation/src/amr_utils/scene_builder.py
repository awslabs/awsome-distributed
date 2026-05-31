"""Warehouse scene construction helpers for Isaac Sim.

Builds a procedural warehouse environment with shelves in aisle layout,
pallets, floor, lights, and semantic labels.
"""


def build_warehouse_scene(stage, config=None):
    """Build a warehouse scene with aisles, shelves, pallets, and lighting.

    Args:
        stage: USD stage from omni.usd.get_context().get_stage()
        config: Optional dict with scene parameters. Defaults provided.

    Returns:
        dict with prim paths for key objects
    """
    from pxr import Gf, Sdf, UsdGeom, UsdLux
    from isaacsim.core.utils.semantics import add_labels

    cfg = {
        "num_aisles": 4,
        "aisle_length": 20.0,
        "aisle_width": 3.0,
        "shelf_height": 2.5,
        "shelf_depth": 1.0,
        "shelf_spacing": 5.0,
        "num_pallets_per_aisle": 3,
        "pallet_size": 0.8,
    }
    if config:
        cfg.update(config)

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    prims = {"shelves": [], "pallets": [], "walls": []}

    # Floor
    floor = stage.DefinePrim("/World/Floor", "Cube")
    xf = UsdGeom.Xformable(floor)
    xf.AddTranslateOp().Set(Gf.Vec3d(cfg["aisle_length"] / 2, 0, -0.05))
    xf.AddScaleOp().Set(Gf.Vec3d(
        cfg["aisle_length"] / 2 + 2,
        (cfg["num_aisles"] * (cfg["aisle_width"] + cfg["shelf_depth"] * 2)) / 2 + 2,
        0.05,
    ))
    add_labels(floor, labels=["Floor"], instance_name="class")

    # Shelves in aisle layout
    shelf_idx = 0
    for aisle in range(cfg["num_aisles"]):
        aisle_center_y = aisle * (cfg["aisle_width"] + cfg["shelf_depth"] * 2)

        for side in [-1, 1]:
            shelf_y = aisle_center_y + side * (cfg["aisle_width"] / 2 + cfg["shelf_depth"] / 2)
            num_sections = int(cfg["aisle_length"] / cfg["shelf_spacing"])

            for section in range(num_sections):
                shelf_x = section * cfg["shelf_spacing"] + cfg["shelf_spacing"] / 2
                path = f"/World/Shelf_{shelf_idx}"

                shelf = stage.DefinePrim(path, "Cube")
                xf = UsdGeom.Xformable(shelf)
                xf.AddTranslateOp().Set(Gf.Vec3d(
                    shelf_x,
                    shelf_y,
                    cfg["shelf_height"] / 2,
                ))
                xf.AddScaleOp().Set(Gf.Vec3d(
                    cfg["shelf_spacing"] / 2 - 0.1,
                    cfg["shelf_depth"] / 2,
                    cfg["shelf_height"] / 2,
                ))
                add_labels(shelf, labels=["Shelf"], instance_name="class")
                prims["shelves"].append(path)
                shelf_idx += 1

    # Pallets scattered in aisles
    import random
    pallet_idx = 0
    for aisle in range(cfg["num_aisles"]):
        aisle_center_y = aisle * (cfg["aisle_width"] + cfg["shelf_depth"] * 2)

        for _ in range(cfg["num_pallets_per_aisle"]):
            px = random.uniform(1, cfg["aisle_length"] - 1)
            py = aisle_center_y + random.uniform(
                -cfg["aisle_width"] / 4, cfg["aisle_width"] / 4
            )
            path = f"/World/Pallet_{pallet_idx}"

            pallet = stage.DefinePrim(path, "Cube")
            xf = UsdGeom.Xformable(pallet)
            xf.AddTranslateOp().Set(Gf.Vec3d(px, py, cfg["pallet_size"] / 2))
            xf.AddScaleOp().Set(Gf.Vec3d(
                cfg["pallet_size"] / 2,
                cfg["pallet_size"] / 2,
                cfg["pallet_size"] / 2,
            ))
            add_labels(pallet, labels=["Pallet"], instance_name="class")
            prims["pallets"].append(path)
            pallet_idx += 1

    # Boundary walls
    total_width = cfg["num_aisles"] * (cfg["aisle_width"] + cfg["shelf_depth"] * 2)
    wall_specs = [
        ("Wall_North", cfg["aisle_length"] / 2, total_width / 2 + 0.5, cfg["aisle_length"] / 2, 0.1, 1.5),
        ("Wall_South", cfg["aisle_length"] / 2, -total_width / 2 - 0.5, cfg["aisle_length"] / 2, 0.1, 1.5),
        ("Wall_East", cfg["aisle_length"] + 0.5, 0, 0.1, total_width / 2, 1.5),
        ("Wall_West", -0.5, 0, 0.1, total_width / 2, 1.5),
    ]
    for name, wx, wy, sx, sy, sz in wall_specs:
        path = f"/World/{name}"
        wall = stage.DefinePrim(path, "Cube")
        xf = UsdGeom.Xformable(wall)
        xf.AddTranslateOp().Set(Gf.Vec3d(wx, wy, sz))
        xf.AddScaleOp().Set(Gf.Vec3d(sx, sy, sz))
        add_labels(wall, labels=["Wall"], instance_name="class")
        prims["walls"].append(path)

    # Lighting: dome + area lights per aisle
    dome = stage.DefinePrim("/World/DomeLight", "DomeLight")
    dome.CreateAttribute("inputs:intensity", Sdf.ValueTypeNames.Float).Set(300.0)

    for aisle in range(cfg["num_aisles"]):
        aisle_center_y = aisle * (cfg["aisle_width"] + cfg["shelf_depth"] * 2)
        for li, lx in enumerate([cfg["aisle_length"] * 0.25, cfg["aisle_length"] * 0.75]):
            light = stage.DefinePrim(
                f"/World/AreaLight_aisle{aisle}_{li}", "RectLight"
            )
            xf = UsdGeom.Xformable(light)
            xf.AddTranslateOp().Set(Gf.Vec3d(lx, aisle_center_y, cfg["shelf_height"] + 1.0))
            light.CreateAttribute("inputs:intensity", Sdf.ValueTypeNames.Float).Set(1000.0)
            light.CreateAttribute("inputs:width", Sdf.ValueTypeNames.Float).Set(2.0)
            light.CreateAttribute("inputs:height", Sdf.ValueTypeNames.Float).Set(2.0)

    prims["floor"] = "/World/Floor"
    prims["dome_light"] = "/World/DomeLight"
    return prims
