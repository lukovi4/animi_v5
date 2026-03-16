Thread 1 Queue : com.apple.main-thread (serial)
#0	0x0000000193729334 in _swift_runtime_on_report ()
#1	0x000000019380e7e0 in _swift_stdlib_reportFatalErrorInFile ()
#2	0x000000019383fbd4 in closure #1 (Swift.UnsafeBufferPointer<Swift.UInt8>) -> () in Swift._assertionFailure(_: Swift.StaticString, _: Swift.String, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never ()
#3	0x000000019383ed40 in _assertionFailure ()
#4	0x000000019381c7e4 in fatalError ()
#5	0x0000000193b92c90 in assertionFailure ()
#6	0x000000010307efd8 in ScenePackageTextureProvider.texture(for:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift:110
#7	0x00000001030812b4 in protocol witness for TextureProvider.texture(for:) in conformance ScenePackageTextureProvider ()
#8	0x000000010304ffc4 in MetalRenderer.drawImage(assetId:opacity:ctx:transform:scissor:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1887
#9	0x0000000103046e6c in MetalRenderer.executeCommand(_:ctx:state:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:1809
#10	0x0000000103040828 in MetalRenderer.renderSegment(_:in:target:textureProvider:commandBuffer:animToViewport:viewportToNDC:assetSizes:pathRegistry:state:renderPassDescriptor:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:628
#11	0x00000001030456d8 in MetalRenderer.drawInternal(commands:in:renderPassDescriptor:target:textureProvider:commandBuffer:assetSizes:pathRegistry:initialState:overrideAnimToViewport:backgroundState:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:451
#12	0x000000010305b89c in MetalRenderer.renderMaskGroupScope(commands:scope:ctx:inheritedState:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskRender.swift:192
#13	0x000000010303f3a0 in MetalRenderer.drawInternal(commands:renderPassDescriptor:target:textureProvider:commandBuffer:assetSizes:pathRegistry:initialState:overrideAnimToViewport:backgroundState:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift:308
#14	0x00000001030610f4 in MetalRenderer.draw(commands:target:textureProvider:commandBuffer:assetSizes:pathRegistry:backgroundState:initialLoadAction:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift:457
#15	0x0000000102e9810c in PlayerViewController.drawWithParams(in:commands:textureProvider:pathRegistry:assetSizes:animSize:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift:3601
#16	0x0000000102e94c2c in PlayerViewController.drawSceneEditMode(in:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift:3517
#17	0x0000000102e9422c in PlayerViewController.draw(in:) at /Users/evgeny/Documents/+Work/Animi/animi_v5/animi/AnimiApp/Sources/Player/PlayerViewController.swift:3216
#18	0x0000000102e94d14 in @objc PlayerViewController.draw(in:) ()
#19	0x00000001ed6f7004 in -[MTKView draw] ()
#20	0x00000001970ce854 in CA::Layer::layout_and_display_if_needed ()
#21	0x000000019708ffe8 in CA::Context::commit_transaction ()
#22	0x00000001970bc0d8 in CA::Transaction::commit ()
#23	0x00000001970c9db8 in CA::Transaction::flush_as_runloop_observer ()
#24	0x000000019c0fa0b8 in _UIApplicationFlushCATransaction ()
#25	0x000000019c0f9fec in __setupUpdateSequence_block_invoke_2 ()
#26	0x000000019c107ee4 in _UIUpdateSequenceRunNext ()
#27	0x000000019c107374 in schedulerStepScheduledMainSectionContinue ()
#28	0x0000000288806560 in UC::DriverCore::continueProcessing ()
#29	0x00000001966714cc in __CFMachPortPerform ()
#30	0x00000001966a10b0 in __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__ ()
#31	0x00000001966a0fd8 in __CFRunLoopDoSource1 ()
#32	0x0000000196678c1c in __CFRunLoopRun ()
#33	0x0000000196677a6c in _CFRunLoopRunSpecificWithOptions ()
#34	0x000000023affd498 in GSEventRunModal ()
#35	0x000000019c127df8 in -[UIApplication _run] ()
#36	0x000000019c0d0e54 in UIApplicationMain ()
#37	0x000000019c1fc938 in ___lldb_unnamed_symbol297654 ()
#38	0x0000000102d8c5d8 in static UIApplicationDelegate.main() ()
#39	0x0000000102d8c54c in static AppDelegate.$main() ()
#40	0x0000000102d8c654 in main ()
#41	0x0000000193652e28 in start ()
