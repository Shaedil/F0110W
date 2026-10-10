"""Builds the Gestures pane's hand and writes Resources/Hand.usdz.

The model is z up, in meters, but the file says Y-up because SceneKit flips a
Z-up file on import. "Thumb" is its own mesh so the app can move it.

    uv run --with scikit-image --with numpy tools/make-hand.py
"""
import os
import subprocess
import tempfile

import numpy as np
from skimage import filters, measure

STEP = 0.0008


def capsule(p, a, b, ra, rb):
    a, b = np.array(a), np.array(b)
    ab = b - a
    t = np.clip(((p - a) @ ab) / (ab @ ab), 0, 1)
    closest = a + t[..., None] * ab
    return np.linalg.norm(p - closest, axis=-1) - (ra + (rb - ra) * t)


def rounded_box(p, centre, half, r):
    q = np.abs(p - np.array(centre)) - (np.array(half) - r)
    return np.linalg.norm(np.maximum(q, 0), axis=-1) + np.minimum(q.max(axis=-1), 0) - r


def smin(a, b, k=0.006):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)


# Index finger at -y, pinky at +y. Each entry is y, radius, length scale.
FINGERS = [
    (-0.026, 0.0088, 1.0),
    (-0.0085, 0.0091, 1.05),
    (0.0085, 0.0086, 1.0),
    (0.0245, 0.0076, 0.88),
]
THUMB_BASE = (-0.017, -0.039, -0.012)


def hand(p):
    d = rounded_box(p, (0.004, 0.0, -0.012), (0.014, 0.036, 0.034), 0.011)
    d = smin(d, capsule(p, (0.004, 0, -0.05), (0.006, 0, -0.16), 0.0235, 0.026), 0.012)
    for y, r, s in FINGERS:
        mcp = (0.0, y, 0.022)
        pip = (-0.024 * s, y, 0.024)
        dip = (pip[0] - 0.002, y, 0.024 - 0.022 * s)
        tip = (dip[0] + 0.013 * s, y, dip[2] - 0.006)
        f = capsule(p, mcp, pip, r * 1.08, r)
        f = smin(f, capsule(p, pip, dip, r, r * 0.95), 0.003)
        f = smin(f, capsule(p, dip, tip, r * 0.95, r * 0.88), 0.003)
        d = smin(d, f, 0.009)
    # Fill the gap between the curled fingers and the palm, or the mesh shows a
    # jagged seam there.
    d = smin(d, rounded_box(p, (-0.016, -0.001, 0.006), (0.009, 0.031, 0.013), 0.006), 0.006)
    d = smin(d, capsule(p, (-0.002, -0.026, -0.034), THUMB_BASE, 0.0135, 0.0118), 0.008)
    return d


def thumb(p):
    ip = (-0.025, -0.038, 0.004)
    tip = (-0.026, -0.033, 0.019)
    d = capsule(p, THUMB_BASE, ip, 0.0115, 0.0103)
    return smin(d, capsule(p, ip, tip, 0.0103, 0.0094), 0.003)


def mesh(field, lo, hi):
    axes = [np.arange(l, h, STEP) for l, h in zip(lo, hi)]
    grid = np.stack(np.meshgrid(*axes, indexing="ij"), axis=-1)
    # A light blur smooths out the steps where the fingers meet.
    values = filters.gaussian(field(grid), sigma=1.5, preserve_range=True)
    verts, faces, normals, _ = measure.marching_cubes(values, 0, spacing=(STEP,) * 3)
    verts += np.array([a[0] for a in axes])
    # marching_cubes returns normals that point into the solid, so flip them.
    return verts, faces, -normals


def usda_mesh(name, verts, faces, normals):
    pts = ", ".join(f"({x:.5f}, {y:.5f}, {z:.5f})" for x, y, z in verts)
    nrm = ", ".join(f"({x:.4f}, {y:.4f}, {z:.4f})" for x, y, z in normals)
    idx = ", ".join(str(i) for i in faces.ravel())
    counts = ", ".join("3" for _ in range(len(faces)))
    return f"""    def Mesh "{name}"
    {{
        int[] faceVertexCounts = [{counts}]
        int[] faceVertexIndices = [{idx}]
        point3f[] points = [{pts}]
        normal3f[] normals = [{nrm}] (interpolation = "vertex")
        uniform token subdivisionScheme = "none"
    }}
"""


def main():
    root = os.path.join(os.path.dirname(__file__), "..")
    parts = [("Hand", hand, (-0.05, -0.06, -0.19), (0.04, 0.05, 0.05)),
             ("Thumb", thumb, (-0.045, -0.06, -0.03), (0.0, -0.015, 0.035))]
    body = ""
    for name, field, lo, hi in parts:
        v, f, n = mesh(field, lo, hi)
        print(name, len(v), "vertices", len(f), "faces")
        body += usda_mesh(name, v, f, n)
    text = f'#usda 1.0\n(\n    defaultPrim = "HandModel"\n    metersPerUnit = 1\n    upAxis = "Y"\n)\n\ndef Xform "HandModel"\n{{\n{body}}}\n'
    with tempfile.TemporaryDirectory() as tmp:
        usda = os.path.join(tmp, "Hand.usda")
        usdc = os.path.join(tmp, "Hand.usdc")
        open(usda, "w").write(text)
        subprocess.run(["usdcat", usda, "-o", usdc], check=True)
        out = os.path.join(root, "Resources", "Hand.usdz")
        if os.path.exists(out):
            os.remove(out)
        subprocess.run(["usdzip", out, "Hand.usdc"], check=True, cwd=tmp)
    print("wrote", os.path.normpath(out))


main()
