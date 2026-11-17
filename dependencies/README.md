# Shared sources

These are snapshots of the locally modified working copies, not Git submodules.
The imported ImGui/ImGuizmo/ImPlot sources are included, so a recursive clone is
not needed. Original component licenses and source headers are retained.

| Directory | Source/version |
| --- | --- |
| dear-imgui | Local fork 2.1.1, upstream HEAD 9dac0f9fbef9f58527148b773ee07d40e43e96f3 |
| dear-imgui/imgui | Local working tree, upstream HEAD 9aae45eb4a05a5a1f96be1ef37eb503a12ceb889 |
| dear-imgui/ImGuizmo | Local ImGuizmo C++ sources, license in that directory |
| dear-imgui/implot-0.16 | Local ImPlot 0.16 C++ sources |
| glm | GLM 1.0.0 headers used by the modified ImGui binding |
| haskell-opencv | Local opencv-0.0.2.1 fork, parent HEAD 14dfed08572f8fe125b601c8cce4a60f08b582b9 |
| husk-scheme | Local husk-scheme 3.20 with camera, vision, projector and motion extensions |
| vision-native | Local controller reconstruction, FFP, codec/projector/triangulation sources required by Husk |
| modbuspp | Local modified header-only Modbus/TCP library, upstream license retained |

Native OpenCV, Open3D, DIPlib, Eigen, CGAL, Ceres, ZBar, ZeroMQ and system graphics
libraries are development prerequisites, not copied vendor binaries. Hackage
packages are pinned by the application's Stack resolver, extra-deps and lockfile.
Camera wrapper source is included in Husk; the MindVision and Hikvision SDK
headers/libraries must be installed separately. The ZMotion API headers/wrappers
are included, but the vendor libzmotion.so must also be installed separately.

The complete Husk device API currently links reconstruction/projector/motion
libraries even for OCR-only clients. Keeping that source closure preserves the
existing interpreter API. Non-OCR 3D/calibration operations retain historical
site-specific data paths; do not invoke them without their original calibration
and data. The five OCR applications' build paths are relative to this repository.

See ../docs/import-manifest.json for original file locations and pre-import
SHA-256 hashes. Imported build/test paths are adjusted after copying. Local
modifications are included even when their upstream commit is older.
