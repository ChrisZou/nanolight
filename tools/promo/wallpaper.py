"""The wallpaper baked into Apple's MacBook Air model, saved as a PNG: the
promo's desktop, so the laptop's display and the close-ups match.

    blender -b --factory-startup --python tools/promo/wallpaper.py -- <model.usdz> <out.png>
"""
import sys

import bpy

model, out = sys.argv[sys.argv.index("--") + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=model)
for mat in bpy.data.materials:
    nodes = mat.node_tree.nodes if mat.node_tree else []
    lit = any(n.type == "BSDF_PRINCIPLED" and n.inputs["Emission Color"].is_linked for n in nodes)
    images = [n.image for n in nodes if n.type == "TEX_IMAGE" and n.image]
    if lit and len(images) == 1:
        img = images[0]
        img.filepath_raw = out
        img.file_format = "PNG"
        img.save()
        break
else:
    sys.exit("no display texture in the model")
