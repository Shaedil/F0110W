#!/bin/sh
# Re-exports the Windows window's 3D models from the Mac app's sources, with
# Blender: the board from assets/M0110.blend and the hand from
# Resources/Hand.usdz, both to glTF in WindowsUI/models.
set -e
cd "$(dirname "$0")/.."
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
"$blender" -b assets/M0110.blend --python-expr "
import bpy
bpy.ops.export_scene.gltf(filepath='WindowsUI/models/M0110.glb', export_format='GLB', export_yup=True, export_apply=True)
"
"$blender" -b --factory-startup --python-expr "
import bpy
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath='Resources/Hand.usdz')
bpy.ops.export_scene.gltf(filepath='WindowsUI/models/Hand.glb', export_format='GLB', export_yup=True, export_apply=True)
"
