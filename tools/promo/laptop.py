"""The promo's laptop shots, in Blender: Apple's MacBook Air (its AR model
from apple.com, fetched by tools/promo.sh, never kept in the repository)
with the promo's own frames on its display, on a dark glossy floor. The
Windows and Linux shots use Dell's XPS 13 (DX13260) AR model from dell.com
the same way.

    blender -b --factory-startup --python tools/promo/laptop.py -- \
        <model.usdz> <screen frames dir> <out dir> <in|out> <frames>
    blender ... -- <model.usdz> <frames dir> <out dir> pair <frames> \
        <model2.usdz> <frames dir 2>

`in`: the camera swings round from the side and pushes into the display
until it fills the frame (the cut to the close-up). `out`: it pulls back
from the display to a three-quarter view. The display shows
<screen frames dir>/0001.png… one a frame, as the screen would. `pair`:
the second laptop stands to the right of the first, showing its own
frames; the camera holds on both, nearly still, then pushes into the
first's display as `in` does (the opening's hook).
"""
import math
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
model, frames_dir, out_dir, shot, count = args[:5]
count = int(count)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def load(path):
    """Imports a model; its objects."""
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


first = load(model)


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


def models_box(objs):
    boxes = [world_box(o) for o in objs if o.type == "MESH"]
    return (Vector([min(b[0][i] for b in boxes) for i in range(3)]),
            Vector([max(b[1][i] for b in boxes) for i in range(3)]))


def find_display(objs):
    """The display: the lit, textured mesh up in the lid."""
    found = None
    for o in objs:
        if o.type == "MESH" and o.material_slots and feeds_emission(o.material_slots[0].material):
            lo, hi = world_box(o)
            if hi.z > 0.1 and (found is None or (hi - lo).length > sum(world_box(found)[1] - world_box(found)[0])):
                found = o
    assert found, "no display found in the model"
    return found


display = find_display(first)
second = None
if shot == "pair":
    # The second laptop to the right, a hand's width away, on the same
    # floor and level with the first's front.
    second = load(args[5])
    lo1, hi1 = models_box(first)
    lo2, hi2 = models_box(second)
    move = Vector((hi1.x - lo2.x + 0.07, (lo1.y + hi1.y - lo2.y - hi2.y) / 2, lo1.z - lo2.z))
    for o in second:
        if o.parent is None or o.parent not in second:
            o.location += move
    bpy.context.view_layer.update()

lo, hi = world_box(display)
centre = (lo + hi) / 2
mw = display.matrix_world.to_3x3()
normal = Vector()
for p in display.data.polygons:
    normal += mw @ p.normal * p.area
normal.normalize()
if normal.y > 0:  # it faces the keyboard: toward -y
    normal = -normal


def show(disp, frames):
    """The display's picture: the frames, as an image sequence, lit by
    itself and glossy, so the lights glint on it."""
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
    uv.uv_map = disp.data.uv_layers.active.name
    img = bpy.data.images.load(f"{frames}/0001.png")
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
    disp.material_slots[0].material = mat


show(display, frames_dir)
if second:
    show(find_display(second), args[6])
    # Windows' bright desktop lit the floor in front of the XPS into a white
    # pool: the displays still reflect in it, but light nothing.
    for disp in (display, find_display(second)):
        disp.visible_diffuse = False

# A dark floor that reflects, under the laptop's feet, a key, a cool rim
# and a warm kicker.
bottom = min(world_box(o)[0].z for o in bpy.data.objects if o.type == "MESH")
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, bottom))
floor = bpy.context.object
fm = bpy.data.materials.new("Floor")
fb = fm.node_tree.nodes["Principled BSDF"]
fb.inputs["Base Color"].default_value = (0.005, 0.0055, 0.008, 1)
fb.inputs["Roughness"].default_value = 0.42
floor.data.materials.append(fm)

world = bpy.data.worlds.new("Dark")
world.color = (0.001, 0.0012, 0.002)
# A new world draws its nodes' grey background: the pair's wide shot sees
# past the floor to it.
world.use_nodes = True
for n in world.node_tree.nodes:
    if n.type == "BACKGROUND":
        n.inputs["Color"].default_value = (0.001, 0.0012, 0.002, 1)
scene.world = world


# The middle of what is shot: one laptop, or between the two.
mx = 0.0
if second:
    lo_all, hi_all = models_box(first + second)
    mx = (lo_all.x + hi_all.x) / 2


def light(name, loc, power, colour, size, kind="AREA"):
    loc = (loc[0] + mx, loc[1], loc[2])
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
    o.rotation_euler = (Vector((mx, 0.05, 0.08)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()


# A pool of light on the laptop (the floor falls off to black round it),
# a cool rim from high behind, and a warm kicker low at the side.
# (Softer on the pair, whose wide shot shows the floor's pool in front.)
light("Key", (-0.2 if second else -0.55, -0.75, 1.0), 38 if second else 160, (1.0, 0.97, 0.92), 0.25, "SPOT")
light("Rim", (0.1, 1.1, 0.8), 45, (0.45, 0.62, 1.0), 0.4)
if not second:
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
    # The opening, after the titles: from high and off to the right, far
    # back in the dark, the camera arcs down and in until it faces both,
    # settling as their panels open; a beat on them; then into the
    # first's display.
    "pair": [(1, (mx + 0.62, -1.95, 0.78), (mx + 0.05, 0.02, 0.04)),
             (round(count * 0.33), (mx + 0.24, -1.52, 0.45), (mx + 0.02, 0.03, 0.07)),
             (round(count * 0.62), (mx, -1.27, 0.3), (mx, 0.03, 0.08)),
             (round(count * 0.74), (mx, -1.25, 0.3), (mx, 0.03, 0.08)),
             (count, tuple(close), tuple(centre))],
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
