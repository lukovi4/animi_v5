[17:57:13] MetalRenderer initialized
[17:57:13] AnimiApp initialized, TVECore: 0.1.0, Metal: Apple iOS simulator GPU
[17:57:16] ---
Loading scene package...
[17:57:16] Scene loaded! v0.1, 1080x1920@30fps, 300f, 4 blocks
[17:57:16] SceneValidation: 0E, 0W
[17:57:16] Loaded 4 animations
[17:57:16] AnimValidation: 0E, 4W
[17:57:16] [W] WARNING_ANIM_SIZE_MISMATCH anim(anim-3.json).w — anim 1080x1920 != inputRect 540x960 (contain policy will apply)
[17:57:16] [W] WARNING_ANIM_SIZE_MISMATCH anim(anim-2.json).w — anim 1080x1920 != inputRect 540x960 (contain policy will apply)
[17:57:16] [W] WARNING_ANIM_SIZE_MISMATCH anim(anim-1.json).w — anim 1080x1920 != inputRect 540x960 (contain policy will apply)
[17:57:16] [W] WARNING_ANIM_SIZE_MISMATCH anim(anim-4.json).w — anim 1080x1920 != inputRect 540x960 (contain policy will apply)
[17:57:16] ---
Compiling scene...
[17:57:16] Scene compiled: 1080x1920 @ 30fps, 300 frames, 4 blocks
[17:57:16]   Block 'block_01' z=0 rect=(0,0 540x960)
[17:57:16]   Block 'block_02' z=1 rect=(540,0 540x960)
[17:57:16]   Block 'block_03' z=2 rect=(0,960 540x960)
[17:57:16]   Block 'block_04' z=3 rect=(540,960 540x960)
[17:57:16] Merged assets: 4 textures
[17:57:16] Texture: anim-3.json|image_0 [540x960]
[17:57:16] Texture: anim-1.json|image_0 [540x960]
[17:57:16] Texture: anim-4.json|image_0 [540x960]
[17:57:16] Texture: anim-2.json|image_0 [540x960]
[17:57:16] Ready for playback!
[DEBUG] compositeMaskedQuad params:
  quadIndexCount: 6
  quadIndexBuffer.length: 12
  bbox: x=0, y=0, w=555, h=987
  content texture: 555x987
  mask texture: 555x987
[17:57:16] --- DEVICE DIAGNOSTIC HEADER ---
[17:57:16] view.bounds: 370x657
[17:57:16] safeAreaInsets: T=0.0 B=0.0 L=0.0 R=0.0
[17:57:16] drawableSize: 1110x1973
[17:57:16] texture size: 1110x1973
[17:57:16] canvasSize: 1080x1920
[17:57:16] target.animSize: 1080x1920
[17:57:16] contentScaleFactor: 3.0
[17:57:16] --- END DEVICE HEADER ---
[17:57:16] [DIAG] frame=0, hasMatte=false, drawShapeFrames=[], pathRegistry.count=4
-[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:5970: failed assertion `Draw Errors Validation
Vertex Function(quad_vertex): argument uniforms[0] from Buffer(1) with offset(0) and length(80) has space for 80 bytes, but argument has a length(96).
'
-[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:5970: failed assertion `Draw Errors Validation
Vertex Function(quad_vertex): argument uniforms[0] from Buffer(1) with offset(0) and length(80) has space for 80 bytes, but argument has a length(96).
'
CoreSimulator 1048 - Device: iPhone 17 Pro (439648FD-C739-495F-B189-2718E4635D04) - Runtime: iOS 26.0 (23A8464) - DeviceType: iPhone 17 Pro
