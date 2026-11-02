"""The promo's laptop shots, in Blender: Apple's MacBook Air (its AR model
from apple.com, fetched by tools/promo.sh, never kept in the repository)
with the promo's own frames on its display, on a dark glossy floor. The
Windows and Linux shots use Dell's XPS 13 (DX13260) AR model from dell.com
the same way.

    blender -b --factory-startup --python tools/promo/laptop.py -- \
        <model.usdz> <screen frames dir> <out dir> <in|out> <frames>

`in`: the camera swings round from the side and pushes into the display
until it fills the frame (the cut to the close-up). `out`: it pulls back
from the display to a three-quarter view. The display shows
<screen frames dir>/0001.png… one a frame, as the screen would.
"""
import math
import sys

import bpy
from mathutils import Vector

model, frames_dir, out_dir, shot, count = sys.argv[sys.argv.index("--") + 1:]
count = int(count)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=model)
scene = bpy.context.scene


def feeds_emission(mat):
    """Whether the material is a display's: an image texture lights it
    (Apple's), or it is textured and named for the screen (Dell's, whose
    picture is its base colour)."""
    if not mat or not mat.node_tree:
        return False
    textured = any(x.type == "TEX_IMAGE" for x in mat.node_tree.nodes)
    if textured and "screen" in mat.name.lower():
        return True
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED" and n.inputs["Emission Color"].is_linked:
            return textured
    return False


def world_box(o):
    pts = [o.matrix_world @ Vector(c) for c in o.bound_box]
    return Vector([min(p[i] for p in pts) for i in range(3)]), Vector([max(p[i] for p in pts) for i in range(3)])


# The display: the lit, textured mesh up in the lid.
display = None
for o in bpy.data.objects:
    if o.type == "MESH" and o.material_slots and feeds_emission(o.material_slots[0].material):
        lo, hi = world_box(o)
        if hi.z > 0.1 and (display is None or (hi - lo).length > sum(world_box(display)[1] - world_box(display)[0])):
            display = o
assert display, "no display found in the model"

lo, hi = world_box(display)
centre = (lo + hi) / 2
mw = display.matrix_world.to_3x3()
normal = Vector()
for p in display.data.polygons:
    normal += mw @ p.normal * p.area
normal.normalize()
if normal.y > 0:  # it faces the keyboard: toward -y
    normal = -normal

# The display's picture: the frames, as an image sequence, lit by itself
# and glossy, so the lights glint on it.
mat = bpy.data.materials.new("NanolightDisplay")
nt = mat.node_tree
for n in list(nt.nodes):
    if n.type != "OUTPUT_MATERIAL":
        nt.nodes.remove(n)
out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
# A matte-ish glass: lights glint softly without washing the picture out.
bsdf.inputs["Roughness"].default_value = 0.35
bsdf.inputs["Specular IOR Level"].default_value = 0.06
bsdf.inputs["Emission Strength"].default_value = 1.0
tex = nt.nodes.new("ShaderNodeTexImage")
uv = nt.nodes.new("ShaderNodeUVMap")
uv.uv_map = display.data.uv_layers.active.name
img = bpy.data.images.load(f"{frames_dir}/0001.png")
img.source = "SEQUENCE"
tex.image = img
tex.image_user.frame_duration = count
tex.image_user.frame_start = 1
tex.image_user.frame_offset = 0
tex.image_user.use_auto_refresh = True
tex.interpolation = "Cubic"
nt.links.new(uv.outputs["UV"], tex.inputs["Vector"])
nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
display.material_slots[0].material = mat

# A dark floor that reflects, under the laptop's feet, a key, a cool rim
# and a warm kicker.
bottom = min(world_box(o)[0].z for o in bpy.data.objects if o.type == "MESH")
bpy.ops.mesh.primitive_plane_add(size=8, location=(0, 0, bottom))
floor = bpy.context.object
fm = bpy.data.materials.new("Floor")
fb = fm.node_tree.nodes["Principled BSDF"]
fb.inputs["Base Color"].default_value = (0.005, 0.0055, 0.008, 1)
fb.inputs["Roughness"].default_value = 0.42
floor.data.materials.append(fm)

world = bpy.data.worlds.new("Dark")
world.color = (0.001, 0.0012, 0.002)
scene.world = world


def light(name, loc, power, colour, size, kind="AREA"):
    d = bpy.data.lights.new(name, kind)
    d.energy = power
    d.color = colour
    if kind == "SPOT":
        d.spot_size = math.radians(38)
        d.spot_blend = 0.7
        d.shadow_soft_size = size
    else:
        d.size = size
    o = bpy.data.objects.new(name, d)
    o.location = loc
    scene.collection.objects.link(o)
    o.rotation_euler = (Vector((0, 0.05, 0.08)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()


# A pool of light on the laptop (the floor falls off to black round it),
# a cool rim from high behind, and a warm kicker low at the side.
light("Key", (-0.55, -0.75, 1.0), 160, (1.0, 0.97, 0.92), 0.25, "SPOT")
light("Rim", (0.1, 1.1, 0.8), 45, (0.45, 0.62, 1.0), 0.4)
light("Kick", (0.9, -0.25, 0.12), 12, (1.0, 0.75, 0.45), 0.3)

# The camera, aimed at a target that moves with it.
target = bpy.data.objects.new("Target", None)
scene.collection.objects.link(target)
cd = bpy.data.cameras.new("Camera")
cd.lens = 50
cd.sensor_width = 36
cd.dof.use_dof = True
cd.dof.focus_object = target
cd.dof.aperture_fstop = 2.8
cam = bpy.data.objects.new("Camera", cd)
scene.collection.objects.link(cam)
scene.camera = cam
track = cam.constraints.new("TRACK_TO")
track.target = target
track.track_axis = "TRACK_NEGATIVE_Z"
track.up_axis = "UP_Y"

# Far enough that the display's width just fills the lens's.
fill = (hi.x - lo.x) / 2 / math.tan(math.atan(18 / cd.lens)) * 1.02
close = centre + normal * fill
keys = {
    # Round from the side, slowing as the display turns to face the lens
    # (Rotato's rule), then through to it.
    "in": [(1, (0.66, -0.62, 0.09), (0, 0.02, 0.05)),
           (round(count * 0.45), (0.2, -0.56, 0.24), (0, 0.07, 0.09)),
           (count, tuple(close), tuple(centre))],
    "out": [(1, tuple(close), tuple(centre)),
            (count, (-0.52, -0.62, 0.3), (0, 0.04, 0.07))],
}[shot]
for f, at, aim in keys:
    cam.location = at
    target.location = aim
    cam.keyframe_insert("location", frame=f)
    target.keyframe_insert("location", frame=f)

scene.frame_start = 1
scene.frame_end = count
scene.render.fps = 60
scene.render.resolution_x = 1920
scene.render.resolution_y = 1080
scene.render.resolution_percentage = 100
scene.render.engine = "BLENDER_EEVEE"
scene.eevee.taa_render_samples = 48
if hasattr(scene.eevee, "use_raytracing"):
    scene.eevee.use_raytracing = True
scene.view_settings.view_transform = "Standard"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGB"
# PROMO_STILLS=1,48,105: those frames alone, as still-<n>.png (to check).
stills = [int(x) for x in __import__("os").environ.get("PROMO_STILLS", "").split(",") if x]
if stills:
    for f in stills:
        scene.frame_set(f)
        scene.render.filepath = f"{out_dir}/still-{f}.png"
        bpy.ops.render.render(write_still=True)
else:
    scene.render.filepath = f"{out_dir}/"
    bpy.ops.render.render(animation=True)
