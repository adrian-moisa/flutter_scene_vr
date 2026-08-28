// Explicitly audited against example_registry.dart. New registry entries remain
// visible but require an audit instead of silently inheriting VR support.
const galleryVrNotes = <String, String>{
  'VR':
      'Original floor, grid, shapes and lighting. Left stick rotates; right stick moves. Grip a panel to move it; held-hand stick pushes/pulls.',
  'Car':
      'Authored showroom settings; automatic orbit becomes an initial tracked view. Wheel spin is elapsed-time based in both modes.',
  'Animation':
      'Same declarative Dash model, blend controls and loading gate; initial camera replaces orbit.',
  'Flutter Logo':
      'Same generated model, ground texture and scene defaults; initial camera replaces orbit.',
  'Multiplayer':
      'Flat only: network/server clocks and keyboard gameplay need a dedicated XR input and simulation contract.',
  'Configurator':
      'Same declarative product, lights and animation; breathing camera is fixed at its initial pose.',
  'Lights':
      'Authored light rig and scene settings; no gallery-wide lighting preset is imposed.',
  'Area Lights':
      'Authored area lights and animated rim rig; scene settings remain unchanged.',
  'Reflection Probes':
      'Probe captures and re-capture control retained; camera orbit does not move the tracked rig.',
  'Planar Mirror':
      'Mirror capture retained. Renderer currently captures from the first eye and shares it with the other eye; not stereo-correct reflection parity.',
  'Spot Shadow':
      'Authored spot shadows and controls retained, including their own resolution and bias.',
  'Cloth':
      'Same cloth solver and parameters. Panel controls work; viewport cloth dragging and fly-camera keys are not mapped to world rays.',
  'Gameplay Kit':
      'Same scenario widgets and simulation. Panel buttons/joystick retained; camera rigs and viewport picking are not XR controls.',
  'Particles':
      'Same campfire, simulation and cinematic defaults, including shadows and post effects. No quality reduction.',
  'Explosions':
      'Same effects and controls. Automatic orbit becomes an initial tracked view.',
  'Gaussian Splats':
      'Same bundled splats, crop and wandering sphere. Optional source captures must be fetched before APK build; free/orbit camera controls do not move the XR rig.',
  'Geometry LOD':
      'Same LOD geometry and thresholds. Head movement changes eye distance; fly-camera controls remain flat only.',
  'Screen-space Reflections':
      'SSR retained per eye. Screen-space coverage and temporal artifacts need headset comparison; orbit/free camera are not applied to the rig.',
  'Auto Exposure':
      'Exposure settings retained. Authored auto-walk camera does not move the headset; physical movement or Recenter changes the observation point.',
  'Navigation Route':
      'Same road, car and simulation. Navigation marker sizing uses the controls viewport; follow/free camera and screen-space marker parity need special handling.',
  'Toon': 'Same custom shader, rotating Dash and material controls.',
  'Raw shader':
      'Same generated shader bundle and elapsed-time ripple uniforms.',
  'Toon (.fmat)':
      'Same compiled material, rotating Dash and material controls.',
  'Custom vertices (.fmat)':
      'Both authored sub-demos retained, including moving road geometry and shader parameters.',
  'Materialize (.fmat)':
      'Same timeline, environment and cinematic defaults. Environment downloads may be required.',
  'DICOM Volume':
      'Flat only: the volume shader uses one cam_uvw uniform from the authored flat camera. A per-eye material uniform adaptation is required.',
  'Custom Skybox':
      'Same sky shader, environment and elapsed-time shapes. Free/orbit camera controls are flat only.',
  'Audio':
      'Same SoLoud backend, mixer, source and assets; music downloads at runtime. Listener uses the renderer primary eye, not an independently centered XR listener.',
  'Widget Texture':
      'Widget geometry retained. World-widget ray input and recursive flat-swapchain feedback are unavailable; leave Recursive off.',
  'Widget Input (inset view)':
      'Widget geometry retained, but this tests flat viewport-offset input. World-widget interaction requires a separate XR ScenePointer adapter.',
  'External Texture':
      'Flat only: video/camera platform textures and camera permission/activity binding need validation in the NativeActivity engine.',
  'Accessibility':
      'Scene geometry retained. Screen-space semantics debugger, labels and picking are flat-only diagnostics.',
  'Render Targets':
      'All authored auxiliary captures retained, including the minimap and comparison textures. They are intentional workload, not a hidden flat main view.',
  'Physics':
      'Same Rapier world, character and cloth. Panel joystick/buttons retained; third-person camera and screen-space vignette are not XR camera effects.',
  'Physics (box3d)':
      'Same native physics. Viewport tap-to-drop and fly controls are flat only; no controller world-ray input.',
  'Car Physics':
      'Same Rapier car simulation. Keyboard driving and follow-camera navigation are not mapped to Quest sticks.',
  'Shapes':
      'Main physics world retained. Auxiliary 118px spinning preview is explicitly omitted in VR; viewport tap-to-drop is flat only.',
  'fscene': 'Same document realization and generated assets.',
  'fscene (import)': 'Same runtime glTF import and asset corpus.',
  'fscene (animated)': 'Same imported animation clips and scene defaults.',
  'fscene (prefab)': 'Same prefab expansion, geometry and materials.',
  'fscene (stream)': 'Same lazy subtrees; load/unload controls retained.',
  'Split Screen':
      'Flat only: two authored cameras, viewport partitions and different layer masks are not interchangeable with a stereo pair.',
  'Stress Tests':
      'Same case picker, models and defaults; large cases/downloads can exhaust device memory. Focus-lock/fly camera are flat only.',
};

bool galleryVrSupported(String name) =>
    galleryVrNotes.containsKey(name) &&
    !galleryVrNotes[name]!.startsWith('Flat only:');
