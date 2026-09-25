"""Build the training site's 3D models from the manufacturers' STEP files.

  python training/tools/build_models.py <devkit.stp> <thriftiest-cam.step>

Needs: pip install cascadio trimesh; npm i gltfpack (or set GLTFPACK to its path)

Sources (not redistributed as STEP; download them yourself):
  - NVIDIA Jetson Download Center, "Jetson Orin Nano Developer Kit 3D CAD STEP model"
    (P3766-P3768SKU4-P3767ENVELOPE.stp). The module is NVIDIA's envelope model: the right
    outline and height, not every chip.
  - The Thrifty Bot, TTB-0370 Thriftiest Cam (public Onshape document, exported as STEP).

Output: training/assets/models/jetson-devkit.glb and thriftiest-cam.glb. Each part group is a
separate named node (ssd, wifi, module, heatsink, usb_a1 ...) so the page can explode and label
them; the page assigns the colours.
"""
import os, re, shutil, subprocess, sys, tempfile
import numpy as np
import cascadio, trimesh

OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'models')
GLTFPACK = os.environ.get('GLTFPACK') or shutil.which('gltfpack') or 'gltfpack'

# Devkit: node name (regex, full match) -> group. First match wins; unmatched parts under
# the carrier board go to 'carrier_parts'. Connector designators identified from positions
# in the CAD (front I/O edge is y = -18.8 mm).
GROUPS = [
    (r'P3526_WIFI_ANT.*', 'antennas'),
    (r'330-0266-000_M2_WIFI_MODULE', 'wifi'),
    (r'NVME-M-2', 'ssd'),
    (r'375-0137-000', 'base'),
    (r'155-0900-000.*|155-0576-000.*', 'standoffs'),
    (r'155-0899-000.*|155-0901-000.*', 'module_screws'),
    (r'600-13768-0000-A04_1', 'pcb'),
    (r'J16', 'dc_jack'),
    (r'J8', 'displayport'),
    (r'J6', 'usb_a1'),
    (r'J7', 'usb_a2'),
    (r'J15', 'ethernet'),
    (r'J5', 'usb_c'),
    (r'J20|J21', 'csi'),
    (r'J12', 'header40'),
    (r'J2', 'sodimm'),
    (r'J24|J11', 'm2_key_m'),
    (r'J10', 'm2_key_e'),
    (r'3514_ASM_1112', 'fan'),
    (r'095-0180-000-TS1_1|LEAFSPRING-P3767-CG|M1_6_0_35PITX4MM.*', 'heatsink'),
    (r'P3767-GROGU', 'module'),
    (r'095-0180-000-TS1', 'heatsink'),
    (r'P3767', 'module'),
    (r'600-13768-0000-A04', 'carrier_parts'),
]


# NVIDIA's devkit CAD carries PCB-design annotations that aren't physical parts: a lavender
# keep-out box around every connector (the space it needs), flat footprint pads (zero
# thickness, light blue) and red pin-1 markers. Drop them so the ports look like ports.
KEEPOUT = (164, 164, 255)   # lavender keep-out boxes (a few dozen faces; the fan wire is also lavender, so size matters)
PIN1 = (255, 0, 0)          # red pin-1 markers


def is_annotation(m):
    mat = getattr(m.visual, 'material', None)
    col = getattr(mat, 'baseColorFactor', None)
    col = tuple(int(c) for c in col[:3]) if col is not None else None
    if col == KEEPOUT and len(m.faces) <= 150:
        return True
    if col == PIN1:
        return True
    return bool(len(m.faces)) and min(m.extents) < 1e-5  # flat sheets: footprint pads, outlines


def group_meshes(scene, group_of, default=None):
    g = scene.graph
    kids = lambda n: g.transforms.children.get(n, [])
    out = {}

    def walk(node, grp):
        for pat, name in GROUPS if group_of is None else group_of:
            if re.fullmatch(pat, node):
                grp = name
                break
        gn = g.transforms.node_data[node].get('geometry')
        if gn and grp and not is_annotation(scene.geometry[gn]):
            T, _ = g.get(node)
            m = scene.geometry[gn].copy()
            m.apply_transform(T)
            out.setdefault(grp, []).append(m)
        for c in kids(node):
            walk(c, grp)

    for top in kids(g.base_frame):
        walk(top, default)
    return out


def name_meshes(path):
    """gltfpack keeps node names but calls the meshes mesh_0, mesh_1...; copy each node's
    name onto its mesh so three.js objects are named after the part."""
    import json, struct
    b = open(path, 'rb').read()
    jlen = struct.unpack_from('<I', b, 12)[0]
    doc = json.loads(b[20:20 + jlen])
    nodes = doc.get('nodes', [])
    for n in nodes:
        if 'name' not in n:
            continue
        # the mesh is on the node itself, or on a child that holds gltfpack's dequantisation transform
        for k in [n] + [nodes[c] for c in n.get('children', [])]:
            if 'mesh' in k:
                doc['meshes'][k['mesh']]['name'] = n['name']
                k.setdefault('name', n['name'] + '_mesh')
    j = json.dumps(doc, separators=(',', ':')).encode()
    j += b' ' * (-len(j) % 4)
    rest = b[20 + jlen:]
    out = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(j) + len(rest)) + struct.pack('<II', len(j), 0x4E4F534A) + j + rest
    open(path, 'wb').write(out)


def build(step, glb_name, groups, default, tol, min_part_mm=0):
    """Tessellate, group by node name, and compress. No mesh decimation: decimating
    CAD meshes broke faces and normals, so the parts no longer looked solid. Size is kept
    down by dropping parts smaller than min_part_mm (resistors, capacitors) and by
    gltfpack's quantisation and meshopt compression (the page decodes it with
    three.js's MeshoptDecoder). In three.js each part is a Group named after it (e.g. 'heatsink')
    holding one Mesh named 'heatsink_mesh'."""
    tmp = os.path.join(tempfile.gettempdir(), glb_name + '.raw.glb')
    cascadio.step_to_glb(step, tmp, tol_linear=tol, tol_angular=0.5)
    scene = trimesh.load(tmp, process=False)  # process=True would merge vertices and smooth sharp edges
    parts = group_meshes(scene, groups, default)
    out = trimesh.Scene()
    for name, ms in parts.items():
        keep = [x for x in ms if len(x.faces) and np.linalg.norm(x.extents) * 1000 >= min_part_mm]
        if not keep:
            continue
        m = trimesh.util.concatenate(keep)
        m.visual = trimesh.visual.ColorVisuals()  # colours come from the page
        # Vertices are NOT merged: cascadio gives each CAD face its own vertices and normals,
        # which keeps sharp edges sharp.
        print(f'{name:14s} {len(m.faces):7d} faces', (m.bounds * 1000).round(1).tolist())
        out.add_geometry(m, node_name=name, geom_name=name)
    raw = os.path.join(tempfile.gettempdir(), glb_name + '.grouped.glb')
    out.export(raw, include_normals=True)
    path = os.path.join(OUT, glb_name)
    # gltfpack: npm i gltfpack. -cc = meshopt compression, -kn = keep node names,
    # -noq off by default (quantised positions/normals are plenty for display).
    subprocess.run([GLTFPACK, '-i', raw, '-o', path, '-cc', '-kn', '-km'], check=True)
    name_meshes(path)
    print('->', path, os.path.getsize(path) // 1024, 'KB')


if __name__ == '__main__':
    devkit, cam = sys.argv[1:3]
    build(devkit, 'jetson-devkit.glb', None, None, 0.2, min_part_mm=2.5)
    # Camera: back housing, front housing, lens holder, screws.
    cam_groups = [(r'TTB-0370-02', 'back'), (r'TTB-0370-03', 'front'), (r'TTB-0370-01', 'lens_mount'), (r'92295A112.*', 'screws')]
    build(cam, 'thriftiest-cam.glb', cam_groups, None, 0.1)
