[MEM-DIAG] editor.boot.before | footprint: 19MB | resident: 83MB | available: 3053MB | metal: n/aMB | 
[MEM-EVENT] bootstrap.prepare.start | requestId=75191E85-E895-4966-AA96-92BBE75832EC sceneTypeId=blank_starter obj=-1537578989955801583
[MEM-EVENT] bootstrap.load.summary | sceneTypeId=blank_starter duration=0.22s
[MEM-EVENT] bootstrap.prepare.loaded | requestId=75191E85-E895-4966-AA96-92BBE75832EC
[MEM-EVENT] bootstrap.prepare.apply | requestId=75191E85-E895-4966-AA96-92BBE75832EC obj=-1537578989955801583
[MEM-EVENT] UserMediaService.init | obj=3788104433619779996
[MEM-EVENT] bootstrap.boot.summary | duration=0.00s
[MEM-DIAG] editor.boot.after | footprint: 54MB | resident: 118MB | available: 3018MB | metal: 11MB | UserMediaService: 1
[MEM-EVENT] bootstrap.apply.summary | duration=0.01s
[MEM-EVENT] bootstrap.prepare.summary | sceneTypeId=blank_starter duration=0.24s outcome=success
[MEM-EVENT] Runtime.create.start | id=D21394F0-3C4D-48C5-8E38-67B680586889 sceneType=blank_starter
[MEM-EVENT] SceneTypeCache.preload.start | id=blank_starter cached=0
[MEM-EVENT] SceneTypeCache.preload.summary | id=blank_starter source=cold io=0.00s provider=0.00s textures=0.04s total=0.05s
[MEM-EVENT] SceneTypeCache.preload.stored | id=blank_starter total=1 ids=blank_starter
[MEM-EVENT] UserMediaService.init | obj=5583119058789140143
[MEM-EVENT] SceneInstanceRuntime.init | obj=-5143935084825434 id=D21394F0-3C4D-48C5-8E38-67B680586889 type=blank_starter
[MEM-EVENT] UMS.cleanupVideo | obj=5583119058789140143 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=1100469336700087693
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-5143935084825434 id=D21394F0-3C4D-48C5-8E38-67B680586889 restored=1
[MEM-EVENT] Runtime.create.complete | id=D21394F0-3C4D-48C5-8E38-67B680586889 outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-5143935084825434 id=D21394F0-3C4D-48C5-8E38-67B680586889 frame=0
[MEM-EVENT] Runtime.create.start | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 sceneType=polaroid_2
[MEM-EVENT] SceneTypeCache.preload.start | id=polaroid_2 cached=1
[MEM-EVENT] Runtime.create.join | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09
[MEM-EVENT] Runtime.create.join | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09
[MEM-EVENT] SceneTypeCache.preload.summary | id=polaroid_2 source=cold io=0.00s provider=0.00s textures=0.13s total=0.14s
[MEM-EVENT] SceneTypeCache.preload.stored | id=polaroid_2 total=2 ids=polaroid_2,blank_starter
[MEM-EVENT] UserMediaService.init | obj=7019449491041433535
[MEM-EVENT] SceneInstanceRuntime.init | obj=-3062050502492999424 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 type=polaroid_2
[MEM-EVENT] UMS.cleanupVideo | obj=7019449491041433535 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-3993144889212132524
[MEM-EVENT] UMS.cleanupVideo | obj=7019449491041433535 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=5889619321219345996
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-3062050502492999424 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 restored=2
[MEM-EVENT] Runtime.create.complete | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 outcome=success total=2
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-3062050502492999424 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 frame=12
[MEM-DIAG] playback.stop.before | footprint: 125MB | resident: 118MB | available: 2946MB | metal: 96MB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 8 (4.7MB) | inUse: 0 (~0.0MB) | total: ~4.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=4.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 316x383 fmt=80 avail=1 inUse=0 MB=0.5
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 316x383 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 2 MB: 0.2
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3993144889212132524 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 125MB | resident: 118MB | available: 2946MB | metal: 96MB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 8 (4.7MB) | inUse: 0 (~0.0MB) | total: ~4.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=4.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 316x383 fmt=80 avail=1 inUse=0 MB=0.5
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 316x383 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 2 MB: 0.2
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-DIAG] editor.close.before | footprint: 126MB | resident: 118MB | available: 2946MB | metal: n/aMB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG] playback.stop.before | footprint: 126MB | resident: 118MB | available: 2946MB | metal: 96MB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 8 (4.7MB) | inUse: 0 (~0.0MB) | total: ~4.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=4.7
[MEM-DIAG]   pool.key | 316x383 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 316x383 fmt=80 avail=1 inUse=0 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 2 MB: 0.2
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3993144889212132524 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 126MB | resident: 118MB | available: 2946MB | metal: 96MB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 8 (4.7MB) | inUse: 0 (~0.0MB) | total: ~4.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=4.7
[MEM-DIAG]   pool.key | 316x383 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 316x383 fmt=80 avail=1 inUse=0 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 2 MB: 0.2
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] EditorViewController.deinit | obj=-1537578989955801583
[MEM-DIAG] editor.close.after | footprint: 121MB | resident: 118MB | available: 2951MB | metal: n/aMB | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-EVENT] UMS.releasePreview | obj=3788104433619779996 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=2 evictCache=true
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=5583119058789140143 videoProviders=1 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=1100469336700087693 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=1100469336700087693 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=1100469336700087693
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3993144889212132524 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=7019449491041433535 videoProviders=2 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-3993144889212132524 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3993144889212132524 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=5889619321219345996 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-3993144889212132524 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3993144889212132524 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-3993144889212132524
[MEM-EVENT] VideoFrameProvider.release | obj=5889619321219345996 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=5889619321219345996
[MEM-EVENT] SceneTypeCache.evictAll | count=2
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-5143935084825434 id=D21394F0-3C4D-48C5-8E38-67B680586889
[MEM-EVENT] UserMediaService.deinit | obj=5583119058789140143 videoProviders=0
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-3062050502492999424 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09
[MEM-EVENT] UserMediaService.deinit | obj=7019449491041433535 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] editor.close.afterTeardown | footprint: 97MB | resident: 112MB | available: 2974MB | metal: 53MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] EditorRuntime.deinit | obj=9052199950239809322
[MEM-EVENT] UserMediaService.deinit | obj=3788104433619779996 videoProviders=0
[MEM-DIAG] editor.boot.before | footprint: 34MB | resident: 111MB | available: 3038MB | metal: n/aMB | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.prepare.start | requestId=9C68F023-D453-4ECC-A2D5-70F26EF65BA3 sceneTypeId=example_4blocks obj=-1537578989955801583
[MEM-EVENT] bootstrap.load.summary | sceneTypeId=example_4blocks duration=0.14s
[MEM-EVENT] bootstrap.prepare.loaded | requestId=9C68F023-D453-4ECC-A2D5-70F26EF65BA3
[MEM-EVENT] bootstrap.prepare.apply | requestId=9C68F023-D453-4ECC-A2D5-70F26EF65BA3 obj=-1537578989955801583
[MEM-EVENT] UserMediaService.init | obj=-1812752082287713456
[MEM-EVENT] bootstrap.boot.summary | duration=0.00s
[MEM-DIAG] editor.boot.after | footprint: 61MB | resident: 115MB | available: 3011MB | metal: 24MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.apply.summary | duration=0.00s
[MEM-EVENT] bootstrap.prepare.summary | sceneTypeId=example_4blocks duration=0.15s outcome=success
[MEM-EVENT] Runtime.create.start | id=68CBD2D2-297C-4AB5-890B-598F709223FE sceneType=example_4blocks
[MEM-EVENT] SceneTypeCache.preload.start | id=example_4blocks cached=0
[MEM-EVENT] SceneTypeCache.preload.summary | id=example_4blocks source=cold io=0.00s provider=0.00s textures=0.13s total=0.14s
[MEM-EVENT] SceneTypeCache.preload.stored | id=example_4blocks total=1 ids=example_4blocks
[MEM-EVENT] UserMediaService.init | obj=1820127553198812747
[MEM-EVENT] SceneInstanceRuntime.init | obj=-6031536972566410306 id=68CBD2D2-297C-4AB5-890B-598F709223FE type=example_4blocks
[MEM-EVENT] UMS.cleanupVideo | obj=1820127553198812747 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-6837026175251260505
[MEM-EVENT] UMS.cleanupVideo | obj=1820127553198812747 blockId=block_03
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=1100469336700087693
[MEM-EVENT] UMS.cleanupVideo | obj=1820127553198812747 blockId=block_04
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=5889619321219345996
[MEM-EVENT] UMS.cleanupVideo | obj=1820127553198812747 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-3491803213610956881
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-6031536972566410306 id=68CBD2D2-297C-4AB5-890B-598F709223FE restored=4
[MEM-EVENT] Runtime.create.complete | id=68CBD2D2-297C-4AB5-890B-598F709223FE outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-6031536972566410306 id=68CBD2D2-297C-4AB5-890B-598F709223FE frame=0
[MEM-DIAG] editor.close.after.2s | footprint: 147MB | resident: 126MB | available: 2925MB | metal: 98MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG] playback.stop.before | footprint: 140MB | resident: 126MB | available: 2932MB | metal: 105MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 9 (2.6MB) | inUse: 0 (~0.0MB) | total: ~2.6MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=39 MB=4.1
[MEM-DIAG]   pool.owner | owner=matte.bbox created=8 MB=2.4
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=6 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=6 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x325 fmt=80 created=2 MB=0.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x206 fmt=80 created=2 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=80 created=1 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=10 created=3 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x53 fmt=80 created=2 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=80 created=1 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=10 created=3 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=80 created=2 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=10 created=6 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-6837026175251260505 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3491803213610956881 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 140MB | resident: 126MB | available: 2932MB | metal: 105MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 9 (2.6MB) | inUse: 0 (~0.0MB) | total: ~2.6MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=39 MB=4.1
[MEM-DIAG]   pool.owner | owner=matte.bbox created=8 MB=2.4
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=6 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=6 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x325 fmt=80 created=2 MB=0.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x206 fmt=80 created=2 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=80 created=1 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=10 created=3 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x53 fmt=80 created=2 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=80 created=1 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=10 created=3 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=80 created=2 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=10 created=6 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-DIAG] editor.close.before | footprint: 140MB | resident: 127MB | available: 2932MB | metal: n/aMB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG] playback.stop.before | footprint: 140MB | resident: 127MB | available: 2932MB | metal: 105MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 9 (2.6MB) | inUse: 0 (~0.0MB) | total: ~2.6MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=39 MB=4.1
[MEM-DIAG]   pool.owner | owner=matte.bbox created=8 MB=2.4
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=6 inUse=0 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=6 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x325 fmt=80 created=2 MB=0.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x206 fmt=80 created=2 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=80 created=1 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=10 created=3 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x53 fmt=80 created=2 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=80 created=1 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=10 created=3 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=80 created=2 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=10 created=6 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-6837026175251260505 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3491803213610956881 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 140MB | resident: 127MB | available: 2932MB | metal: 105MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 9 (2.6MB) | inUse: 0 (~0.0MB) | total: ~2.6MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=39 MB=4.1
[MEM-DIAG]   pool.owner | owner=matte.bbox created=8 MB=2.4
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=6 inUse=0 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=6 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x325 fmt=80 created=2 MB=0.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x206 fmt=80 created=2 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x482 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x325 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x322 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=80 created=1 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x206 fmt=10 created=3 MB=0.2
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x53 fmt=80 created=2 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=80 created=1 MB=0.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x53 fmt=10 created=3 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=80 created=2 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 36x28 fmt=10 created=6 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] EditorViewController.deinit | obj=-1537578989955801583
[MEM-DIAG] editor.close.after | footprint: 136MB | resident: 127MB | available: 2935MB | metal: n/aMB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-EVENT] UMS.releasePreview | obj=-1812752082287713456 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=1 evictCache=true
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-6837026175251260505 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3491803213610956881 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=1820127553198812747 videoProviders=4 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-6837026175251260505 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-6837026175251260505 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=1100469336700087693 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=5889619321219345996 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-3491803213610956881 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3491803213610956881 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-6837026175251260505 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-6837026175251260505 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-6837026175251260505
[MEM-EVENT] VideoFrameProvider.release | obj=1100469336700087693 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=1100469336700087693 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=1100469336700087693
[MEM-EVENT] VideoFrameProvider.release | obj=5889619321219345996 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5889619321219345996 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=5889619321219345996
[MEM-EVENT] VideoFrameProvider.release | obj=-3491803213610956881 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3491803213610956881 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-3491803213610956881
[MEM-EVENT] SceneTypeCache.evictAll | count=1
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-6031536972566410306 id=68CBD2D2-297C-4AB5-890B-598F709223FE
[MEM-EVENT] UserMediaService.deinit | obj=1820127553198812747 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] editor.close.afterTeardown | footprint: 129MB | resident: 118MB | available: 2943MB | metal: 80MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] EditorRuntime.deinit | obj=2879987688391908693
[MEM-EVENT] UserMediaService.deinit | obj=-1812752082287713456 videoProviders=0
[MEM-DIAG] editor.close.after.2s | footprint: 33MB | resident: 116MB | available: 3039MB | metal: 0MB | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-DIAG] editor.boot.before | footprint: 29MB | resident: 115MB | available: 3043MB | metal: n/aMB | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.prepare.start | requestId=DC4510B4-215D-4413-868B-DD2AF9CEE539 sceneTypeId=blank_starter obj=-1537578989955801583
[MEM-EVENT] bootstrap.load.summary | sceneTypeId=blank_starter duration=0.04s
[MEM-EVENT] bootstrap.prepare.loaded | requestId=DC4510B4-215D-4413-868B-DD2AF9CEE539
[MEM-EVENT] bootstrap.prepare.apply | requestId=DC4510B4-215D-4413-868B-DD2AF9CEE539 obj=-1537578989955801583
[MEM-EVENT] UserMediaService.init | obj=5715598751993852537
[MEM-EVENT] bootstrap.boot.summary | duration=0.00s
[MEM-DIAG] editor.boot.after | footprint: 55MB | resident: 131MB | available: 3017MB | metal: 11MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.apply.summary | duration=0.01s
[MEM-EVENT] bootstrap.prepare.summary | sceneTypeId=blank_starter duration=0.05s outcome=success
[MEM-EVENT] Runtime.create.start | id=D21394F0-3C4D-48C5-8E38-67B680586889 sceneType=blank_starter
[MEM-EVENT] SceneTypeCache.preload.start | id=blank_starter cached=0
[MEM-EVENT] SceneTypeCache.preload.summary | id=blank_starter source=cold io=0.00s provider=0.00s textures=0.04s total=0.04s
[MEM-EVENT] SceneTypeCache.preload.stored | id=blank_starter total=1 ids=blank_starter
[MEM-EVENT] UserMediaService.init | obj=911572399531331967
[MEM-EVENT] SceneInstanceRuntime.init | obj=5769848592399663646 id=D21394F0-3C4D-48C5-8E38-67B680586889 type=blank_starter
[MEM-EVENT] UMS.cleanupVideo | obj=911572399531331967 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=316773242358063908
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=5769848592399663646 id=D21394F0-3C4D-48C5-8E38-67B680586889 restored=1
[MEM-EVENT] Runtime.create.complete | id=D21394F0-3C4D-48C5-8E38-67B680586889 outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=5769848592399663646 id=D21394F0-3C4D-48C5-8E38-67B680586889 frame=0
[MEM-DIAG] export.enter.before | footprint: 91MB | resident: 131MB | available: 2981MB | metal: 49MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 1
[MEM-EVENT] export.enter
[MEM-DIAG] playback.stop.before | footprint: 91MB | resident: 131MB | available: 2981MB | metal: 49MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 1
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 1 [blank_starter] loading: 0 | textures: 2 ~9.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 1
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=316773242358063908 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 91MB | resident: 131MB | available: 2981MB | metal: 49MB | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 1
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 1 [blank_starter] loading: 0 | textures: 2 ~9.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 1
[MEM-EVENT] Background.clearAll | keys=0
[MEM-EVENT] UMS.releasePreview | obj=5715598751993852537 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=1 evictCache=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=316773242358063908 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=911572399531331967 videoProviders=1 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=316773242358063908 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=316773242358063908 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=316773242358063908 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=316773242358063908 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=316773242358063908
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=5769848592399663646 id=D21394F0-3C4D-48C5-8E38-67B680586889
[MEM-EVENT] UserMediaService.deinit | obj=911572399531331967 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] export.enter.after | footprint: 86MB | resident: 131MB | available: 2985MB | metal: 49MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=polaroid_2 source=cold io=0.01s provider=0.00s total=0.01s
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=full_image source=cold io=0.00s provider=0.00s total=0.00s
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=polaroid_shared_demo source=cold io=0.00s provider=0.00s total=0.00s
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=example_4blocks source=cold io=0.00s provider=0.00s total=0.00s
[MEM-EVENT] export.prepare.summary | mode=timeline duration=0.12s outcome=success
[MEM-EVENT] export.taskDelay.summary | mode=timeline delay=0.00s
[MEM-EVENT] export.handoff.summary | mode=timeline duration=0.01s
[MEM-EVENT] export.queueDelay.summary | mode=timeline delay=0.00s
[MEM-EVENT] export.writer.init.summary | writerCreate=0.00s videoInput=0.02s adaptor=0.00s audioInput=0.00s pump=0.00s total=0.02s
[MEM-EVENT] export.audioPump.start.summary | readerCreate=0.00s outputSetup=0.00s readerStart=0.08s callback=0.00s total=0.08s
[MEM-EVENT] export.writer.start.summary | writerStart=1.38s session=0.00s videoPump=0.00s audioPump=0.08s total=1.46s
[MEM-EVENT] CVTextureCache.create | owner=TimelineExport
[MEM-EVENT] export.runnerSetup.summary | mode=timeline background=0.00s audio=0.05s writer=1.48s cache=0.00s residency=0.00s other=0.00s total=1.53s
[MEM-DIAG] export.frame.0 | footprint: 77MB | resident: 133MB | available: 2994MB | metal: 46MB | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-4513407401593489797
[MEM-DIAG] playback.stop.after.2s | footprint: 140MB | resident: 151MB | available: 2931MB | metal: 88MB | ExportVideoFrameProvider: 1 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 1 [blank_starter] loading: 0 | textures: 2 ~9.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 0
[MEM-DIAG]   videoProviders: 0
[MEM-EVENT] ExportVideoSlots.finish | slots=1
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-4513407401593489797
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-4513407401593489797
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-1242660204940211421
[MEM-EVENT] ExportVideoFrameProvider.init | obj=1828343695151550458
[MEM-DIAG] export.frame.300 | footprint: 368MB | resident: 146MB | available: 2703MB | metal: 375MB | ExportVideoFrameProvider: 2 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] ExportVideoSlots.finish | slots=2
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-1242660204940211421
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-1242660204940211421
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=1828343695151550458
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=1828343695151550458
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-8864929274601543752
[MEM-EVENT] ExportVideoSlots.finish | slots=1
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-8864929274601543752
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-8864929274601543752
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-7260884868881790517
[MEM-DIAG] export.frame.600 | footprint: 328MB | resident: 155MB | available: 2744MB | metal: 321MB | ExportVideoFrameProvider: 1 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] ExportVideoSlots.finish | slots=1
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-7260884868881790517
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-7260884868881790517
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-7260884868881790517
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-2821001486646128032
[MEM-EVENT] ExportVideoFrameProvider.init | obj=1828343695151550458
[MEM-DIAG] export.frame.900 | footprint: 432MB | resident: 166MB | available: 2640MB | metal: 387MB | ExportVideoFrameProvider: 3 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] export.render.summary | mode=timeline frames=1187/1187 duration=15.73s fps=75.46 renderOutcome=success
[MEM-DIAG] export.render.after | footprint: 452MB | resident: 155MB | available: 2619MB | metal: 435MB | ExportVideoFrameProvider: 3 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] export.finishWriting.summary | duration=0.02s outcome=success
[MEM-EVENT] ExportVideoSlots.finish | slots=3
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-7260884868881790517
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-7260884868881790517
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-2821001486646128032
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-2821001486646128032
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=1828343695151550458
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=1828343695151550458
[MEM-DIAG] export.complete.success | footprint: 452MB | resident: 154MB | available: 2620MB | metal: 328MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] Runtime.create.start | id=D21394F0-3C4D-48C5-8E38-67B680586889 sceneType=blank_starter
[MEM-EVENT] UserMediaService.init | obj=2019934055273331558
[MEM-EVENT] SceneInstanceRuntime.init | obj=4842360135251914619 id=D21394F0-3C4D-48C5-8E38-67B680586889 type=blank_starter
[MEM-EVENT] UMS.cleanupVideo | obj=2019934055273331558 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-1824080468339233072
[MEM-EVENT] ExportWriterPipeline.deinit | obj=-2636218820088479974
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=4842360135251914619 id=D21394F0-3C4D-48C5-8E38-67B680586889 restored=1
[MEM-EVENT] Runtime.create.complete | id=D21394F0-3C4D-48C5-8E38-67B680586889 outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=4842360135251914619 id=D21394F0-3C4D-48C5-8E38-67B680586889 frame=0
[MEM-EVENT] Runtime.create.start | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 sceneType=polaroid_2
[MEM-EVENT] SceneTypeCache.preload.start | id=polaroid_2 cached=1
[MEM-EVENT] SceneTypeCache.preload.summary | id=polaroid_2 source=cold io=0.00s provider=0.00s textures=0.14s total=0.14s
[MEM-EVENT] SceneTypeCache.preload.stored | id=polaroid_2 total=2 ids=polaroid_2,blank_starter
[MEM-EVENT] UserMediaService.init | obj=-3502762687227157767
[MEM-EVENT] SceneInstanceRuntime.init | obj=-2446959417385949931 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 type=polaroid_2
[MEM-EVENT] UMS.cleanupVideo | obj=-3502762687227157767 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-796163346242048408
[MEM-EVENT] UMS.cleanupVideo | obj=-3502762687227157767 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-8178997353207495479
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-2446959417385949931 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 restored=2
[MEM-EVENT] Runtime.create.complete | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 outcome=success total=2
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-2446959417385949931 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 frame=0
[MEM-EVENT] export.previewRestored
[MEM-DIAG] preview.restore.after | footprint: 159MB | resident: 145MB | available: 2912MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-EVENT] export.previewRestore.summary | duration=0.58s outcome=success
[MEM-EVENT] export.delivery.summary | destination=photoLibrary policy=photoLibraryOnly duration=0.23s outcome=success
[MEM-EVENT] export.total.summary | duration=18.23s outcome=savedToPhotos
[MEM-DIAG] playback.stop.before | footprint: 132MB | resident: 138MB | available: 2940MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1824080468339233072 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-796163346242048408 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-8178997353207495479 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 132MB | resident: 138MB | available: 2940MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-DIAG] editor.close.before | footprint: 132MB | resident: 138MB | available: 2939MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG] playback.stop.before | footprint: 132MB | resident: 138MB | available: 2939MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1824080468339233072 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-796163346242048408 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-8178997353207495479 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 132MB | resident: 138MB | available: 2939MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=4 MB=3.9
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=1 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=3 MB=1.7
[MEM-DIAG]   sceneTypeCache | cached: 2 [blank_starter,polaroid_2] loading: 0 | textures: 10 ~33.7MB
[MEM-DIAG]   overlayCache | entries: 1 MB: 0.0
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] EditorViewController.deinit | obj=-1537578989955801583
[MEM-DIAG] editor.close.after | footprint: 128MB | resident: 138MB | available: 2944MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-EVENT] UMS.releasePreview | obj=5715598751993852537 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=2 evictCache=true
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1824080468339233072 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=2019934055273331558 videoProviders=1 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-1824080468339233072 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1824080468339233072 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-1824080468339233072 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1824080468339233072 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-1824080468339233072
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-796163346242048408 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-8178997353207495479 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=-3502762687227157767 videoProviders=2 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-796163346242048408 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-796163346242048408 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-8178997353207495479 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-8178997353207495479 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-796163346242048408 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-796163346242048408 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-796163346242048408
[MEM-EVENT] VideoFrameProvider.release | obj=-8178997353207495479 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-8178997353207495479 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-8178997353207495479
[MEM-EVENT] SceneTypeCache.evictAll | count=2
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=4842360135251914619 id=D21394F0-3C4D-48C5-8E38-67B680586889
[MEM-EVENT] UserMediaService.deinit | obj=2019934055273331558 videoProviders=0
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-2446959417385949931 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09
[MEM-EVENT] UserMediaService.deinit | obj=-3502762687227157767 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] editor.close.afterTeardown | footprint: 77MB | resident: 131MB | available: 2995MB | metal: 30MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] EditorRuntime.deinit | obj=1635699265816870823
[MEM-EVENT] UserMediaService.deinit | obj=5715598751993852537 videoProviders=0
[MEM-DIAG] editor.close.after.2s | footprint: 41MB | resident: 131MB | available: 3030MB | metal: 1MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-DIAG] editor.boot.before | footprint: 41MB | resident: 131MB | available: 3030MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.prepare.start | requestId=5FB759F6-A973-4228-9AC7-4A781EB9A4D3 sceneTypeId=example_4blocks obj=1757509503109158747
[MEM-EVENT] bootstrap.load.summary | sceneTypeId=example_4blocks duration=0.14s
[MEM-EVENT] bootstrap.prepare.loaded | requestId=5FB759F6-A973-4228-9AC7-4A781EB9A4D3
[MEM-EVENT] bootstrap.prepare.apply | requestId=5FB759F6-A973-4228-9AC7-4A781EB9A4D3 obj=1757509503109158747
[MEM-EVENT] UserMediaService.init | obj=-5085893300684760604
[MEM-EVENT] bootstrap.boot.summary | duration=0.00s
[MEM-DIAG] editor.boot.after | footprint: 69MB | resident: 135MB | available: 3003MB | metal: 24MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.apply.summary | duration=0.00s
[MEM-EVENT] bootstrap.prepare.summary | sceneTypeId=example_4blocks duration=0.14s outcome=success
[MEM-EVENT] Runtime.create.start | id=68CBD2D2-297C-4AB5-890B-598F709223FE sceneType=example_4blocks
[MEM-EVENT] SceneTypeCache.preload.start | id=example_4blocks cached=0
[MEM-EVENT] SceneTypeCache.preload.summary | id=example_4blocks source=cold io=0.00s provider=0.00s textures=0.12s total=0.13s
[MEM-EVENT] SceneTypeCache.preload.stored | id=example_4blocks total=1 ids=example_4blocks
[MEM-EVENT] UserMediaService.init | obj=-5036506186503942842
[MEM-EVENT] SceneInstanceRuntime.init | obj=-4715012724127260937 id=68CBD2D2-297C-4AB5-890B-598F709223FE type=example_4blocks
[MEM-EVENT] UMS.cleanupVideo | obj=-5036506186503942842 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-5741448755714888475
[MEM-EVENT] UMS.cleanupVideo | obj=-5036506186503942842 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=3522789144575742641
[MEM-EVENT] UMS.cleanupVideo | obj=-5036506186503942842 blockId=block_03
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-1778336290725308348
[MEM-EVENT] UMS.cleanupVideo | obj=-5036506186503942842 blockId=block_04
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=7412496330747027628
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-4715012724127260937 id=68CBD2D2-297C-4AB5-890B-598F709223FE restored=4
[MEM-EVENT] Runtime.create.complete | id=68CBD2D2-297C-4AB5-890B-598F709223FE outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-4715012724127260937 id=68CBD2D2-297C-4AB5-890B-598F709223FE frame=0
[MEM-DIAG] export.enter.before | footprint: 149MB | resident: 140MB | available: 2922MB | metal: 103MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-EVENT] export.enter
[MEM-DIAG] playback.stop.before | footprint: 149MB | resident: 140MB | available: 2922MB | metal: 103MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-5741448755714888475 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1778336290725308348 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=7412496330747027628 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3522789144575742641 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 149MB | resident: 140MB | available: 2922MB | metal: 103MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] Background.clearAll | keys=0
[MEM-EVENT] UMS.releasePreview | obj=-5085893300684760604 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=1 evictCache=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-5741448755714888475 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1778336290725308348 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=7412496330747027628 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3522789144575742641 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=-5036506186503942842 videoProviders=4 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-5741448755714888475 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-5741448755714888475 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-1778336290725308348 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1778336290725308348 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=7412496330747027628 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=7412496330747027628 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=3522789144575742641 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3522789144575742641 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-5741448755714888475 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-5741448755714888475 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-5741448755714888475
[MEM-EVENT] VideoFrameProvider.release | obj=-1778336290725308348 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1778336290725308348 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-1778336290725308348
[MEM-EVENT] VideoFrameProvider.release | obj=7412496330747027628 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=7412496330747027628 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=7412496330747027628
[MEM-EVENT] VideoFrameProvider.release | obj=3522789144575742641 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3522789144575742641 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=3522789144575742641
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-4715012724127260937 id=68CBD2D2-297C-4AB5-890B-598F709223FE
[MEM-EVENT] UserMediaService.deinit | obj=-5036506186503942842 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] export.enter.after | footprint: 144MB | resident: 140MB | available: 2927MB | metal: 99MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] export.prepare.summary | mode=timeline duration=0.06s outcome=success
[MEM-EVENT] export.taskDelay.summary | mode=timeline delay=0.00s
[MEM-EVENT] export.handoff.summary | mode=timeline duration=0.00s
[MEM-EVENT] export.queueDelay.summary | mode=timeline delay=0.00s
[MEM-EVENT] export.writer.init.summary | writerCreate=0.00s videoInput=0.00s adaptor=0.00s audioInput=0.00s pump=0.00s total=0.00s
[MEM-EVENT] export.audioPump.start.summary | readerCreate=0.00s outputSetup=0.00s readerStart=0.03s callback=0.00s total=0.03s
[MEM-EVENT] export.writer.start.summary | writerStart=0.00s session=0.00s videoPump=0.00s audioPump=0.03s total=0.04s
[MEM-EVENT] CVTextureCache.create | owner=TimelineExport
[MEM-EVENT] export.runnerSetup.summary | mode=timeline background=0.00s audio=0.02s writer=0.04s cache=0.00s residency=0.00s other=0.00s total=0.06s
[MEM-DIAG] export.frame.0 | footprint: 141MB | resident: 140MB | available: 2931MB | metal: 99MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] ExportVideoFrameProvider.init | obj=7122912116676103538
[MEM-EVENT] ExportVideoFrameProvider.init | obj=4567327914306738780
[MEM-EVENT] ExportVideoFrameProvider.init | obj=120334098033682162
[MEM-EVENT] ExportVideoFrameProvider.init | obj=-4429102933466418487
[MEM-DIAG] playback.stop.after.2s | footprint: 573MB | resident: 173MB | available: 2498MB | metal: 521MB | ExportVideoFrameProvider: 4 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 0
[MEM-DIAG]   videoProviders: 0
[MEM-EVENT] export.render.summary | mode=timeline frames=300/300 duration=6.95s fps=43.18 renderOutcome=success
[MEM-DIAG] export.render.after | footprint: 595MB | resident: 188MB | available: 2477MB | metal: 546MB | ExportVideoFrameProvider: 4 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] export.finishWriting.summary | duration=0.01s outcome=success
[MEM-EVENT] ExportVideoSlots.finish | slots=4
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=7122912116676103538
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=7122912116676103538
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=4567327914306738780
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=4567327914306738780
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=120334098033682162
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=120334098033682162
[MEM-EVENT] ExportVideoFrameProvider.finish | obj=-4429102933466418487
[MEM-EVENT] ExportVideoFrameProvider.deinit | obj=-4429102933466418487
[MEM-DIAG] export.complete.success | footprint: 595MB | resident: 188MB | available: 2477MB | metal: 433MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] Runtime.create.start | id=68CBD2D2-297C-4AB5-890B-598F709223FE sceneType=example_4blocks
[MEM-EVENT] UserMediaService.init | obj=1184605077964968352
[MEM-EVENT] SceneInstanceRuntime.init | obj=1939849902280954113 id=68CBD2D2-297C-4AB5-890B-598F709223FE type=example_4blocks
[MEM-EVENT] UMS.cleanupVideo | obj=1184605077964968352 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=3216982793071302789
[MEM-EVENT] UMS.cleanupVideo | obj=1184605077964968352 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-3428808319810313412
[MEM-EVENT] UMS.cleanupVideo | obj=1184605077964968352 blockId=block_03
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] ExportWriterPipeline.deinit | obj=-5426897205864602333
[MEM-EVENT] VideoFrameProvider.init | obj=9183673974538525746
[MEM-EVENT] UMS.cleanupVideo | obj=1184605077964968352 blockId=block_04
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-7226916149286876460
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=1939849902280954113 id=68CBD2D2-297C-4AB5-890B-598F709223FE restored=4
[MEM-EVENT] Runtime.create.complete | id=68CBD2D2-297C-4AB5-890B-598F709223FE outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=1939849902280954113 id=68CBD2D2-297C-4AB5-890B-598F709223FE frame=0
[MEM-EVENT] export.previewRestored
[MEM-DIAG] preview.restore.after | footprint: 152MB | resident: 141MB | available: 2919MB | metal: 104MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-EVENT] export.previewRestore.summary | duration=0.26s outcome=success
[MEM-EVENT] export.delivery.summary | destination=photoLibrary policy=photoLibraryOnly duration=0.11s outcome=success
[MEM-EVENT] export.total.summary | duration=7.45s outcome=savedToPhotos
[MEM-DIAG] playback.stop.before | footprint: 146MB | resident: 141MB | available: 2925MB | metal: 108MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3428808319810313412 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7226916149286876460 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=9183673974538525746 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3216982793071302789 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 146MB | resident: 141MB | available: 2925MB | metal: 108MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-DIAG] editor.close.before | footprint: 146MB | resident: 141MB | available: 2925MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG] playback.stop.before | footprint: 146MB | resident: 141MB | available: 2925MB | metal: 108MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3428808319810313412 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7226916149286876460 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=9183673974538525746 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3216982793071302789 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 146MB | resident: 141MB | available: 2925MB | metal: 108MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-DIAG]   pool | avail: 11 (6.7MB) | inUse: 0 (~0.0MB) | total: ~6.7MB
[MEM-DIAG]   pool.owner | owner=isolatedGroup.fullTarget created=1 MB=4.5
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=1.1
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=8 MB=1.0
[MEM-DIAG]   pool.key | 291x2 fmt=10 avail=3 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=10 avail=3 inUse=0 MB=0.4
[MEM-DIAG]   pool.key | 291x2 fmt=80 avail=1 inUse=0 MB=0.0
[MEM-DIAG]   pool.key | 291x511 fmt=80 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 1170x1017 fmt=80 avail=1 inUse=0 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=isolatedGroup.fullTarget 1170x1017 fmt=80 created=1 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 291x511 fmt=80 created=2 MB=1.1
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=80 created=1 MB=0.6
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x511 fmt=10 created=3 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=80 created=1 MB=0.0
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 291x2 fmt=10 created=3 MB=0.0
[MEM-DIAG]   sceneTypeCache | cached: 1 [example_4blocks] loading: 0 | textures: 11 ~21.8MB
[MEM-DIAG]   overlayCache | entries: 0 MB: 0.0
[MEM-DIAG]   runtimes: 1
[MEM-DIAG]   videoProviders: 4
[MEM-EVENT] EditorViewController.deinit | obj=1757509503109158747
[MEM-DIAG] editor.close.after | footprint: 139MB | resident: 141MB | available: 2932MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 4
[MEM-EVENT] UMS.releasePreview | obj=-5085893300684760604 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=1 evictCache=true
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3428808319810313412 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7226916149286876460 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=9183673974538525746 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3216982793071302789 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=1184605077964968352 videoProviders=4 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-3428808319810313412 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3428808319810313412 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-7226916149286876460 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7226916149286876460 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=9183673974538525746 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=9183673974538525746 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=3216982793071302789 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3216982793071302789 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-3428808319810313412 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-3428808319810313412 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-3428808319810313412
[MEM-EVENT] VideoFrameProvider.release | obj=-7226916149286876460 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7226916149286876460 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-7226916149286876460
[MEM-EVENT] VideoFrameProvider.release | obj=9183673974538525746 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=9183673974538525746 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=9183673974538525746
[MEM-EVENT] VideoFrameProvider.release | obj=3216982793071302789 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=3216982793071302789 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=3216982793071302789
[MEM-EVENT] SceneTypeCache.evictAll | count=1
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=1939849902280954113 id=68CBD2D2-297C-4AB5-890B-598F709223FE
[MEM-EVENT] UserMediaService.deinit | obj=1184605077964968352 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] editor.close.afterTeardown | footprint: 123MB | resident: 134MB | available: 2949MB | metal: 80MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] EditorRuntime.deinit | obj=1308387284967174289
[MEM-EVENT] UserMediaService.deinit | obj=-5085893300684760604 videoProviders=0
[MEM-DIAG] editor.boot.before | footprint: 42MB | resident: 134MB | available: 3029MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.prepare.start | requestId=0CC5E0DA-3D3A-46D5-87D3-5BEDF4DF48A3 sceneTypeId=blank_starter obj=5390609472155833905
[MEM-EVENT] bootstrap.load.summary | sceneTypeId=blank_starter duration=0.04s
[MEM-EVENT] bootstrap.prepare.loaded | requestId=0CC5E0DA-3D3A-46D5-87D3-5BEDF4DF48A3
[MEM-EVENT] bootstrap.prepare.apply | requestId=0CC5E0DA-3D3A-46D5-87D3-5BEDF4DF48A3 obj=5390609472155833905
[MEM-EVENT] UserMediaService.init | obj=-6335824930927430849
[MEM-EVENT] bootstrap.boot.summary | duration=0.00s
[MEM-DIAG] editor.boot.after | footprint: 69MB | resident: 149MB | available: 3003MB | metal: 11MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] bootstrap.apply.summary | duration=0.00s
[MEM-EVENT] bootstrap.prepare.summary | sceneTypeId=blank_starter duration=0.05s outcome=success
[MEM-EVENT] Runtime.create.start | id=D21394F0-3C4D-48C5-8E38-67B680586889 sceneType=blank_starter
[MEM-EVENT] SceneTypeCache.preload.start | id=blank_starter cached=0
[MEM-EVENT] SceneTypeCache.preload.summary | id=blank_starter source=cold io=0.00s provider=0.00s textures=0.04s total=0.04s
[MEM-EVENT] SceneTypeCache.preload.stored | id=blank_starter total=1 ids=blank_starter
[MEM-EVENT] UserMediaService.init | obj=-2307641527296109063
[MEM-EVENT] SceneInstanceRuntime.init | obj=-5716403520155560519 id=D21394F0-3C4D-48C5-8E38-67B680586889 type=blank_starter
[MEM-EVENT] UMS.cleanupVideo | obj=-2307641527296109063 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-7583670660299610766
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-5716403520155560519 id=D21394F0-3C4D-48C5-8E38-67B680586889 restored=1
[MEM-EVENT] Runtime.create.complete | id=D21394F0-3C4D-48C5-8E38-67B680586889 outcome=success total=1
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-5716403520155560519 id=D21394F0-3C4D-48C5-8E38-67B680586889 frame=0
[MEM-DIAG] editor.close.after.2s | footprint: 102MB | resident: 150MB | available: 2969MB | metal: 44MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 1 | UserMediaService: 2 | VideoFrameProvider: 1
[MEM-EVENT] Runtime.create.start | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 sceneType=polaroid_2
[MEM-EVENT] SceneTypeCache.preload.start | id=polaroid_2 cached=1
[MEM-EVENT] SceneTypeCache.preload.summary | id=polaroid_2 source=cold io=0.01s provider=0.00s textures=0.13s total=0.14s
[MEM-EVENT] SceneTypeCache.preload.stored | id=polaroid_2 total=2 ids=polaroid_2,blank_starter
[MEM-EVENT] UserMediaService.init | obj=1029106044995895471
[MEM-EVENT] SceneInstanceRuntime.init | obj=2532609900039247639 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 type=polaroid_2
[MEM-EVENT] UMS.cleanupVideo | obj=1029106044995895471 blockId=block_02
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=2489492149916911162
[MEM-EVENT] UMS.cleanupVideo | obj=1029106044995895471 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=8895955064051431987
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=2532609900039247639 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 restored=2
[MEM-EVENT] Runtime.create.complete | id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 outcome=success total=2
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=2532609900039247639 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09 frame=0
[MEM-EVENT] displayLink.create | obj=2741942790868494483
[MEM-DIAG] playback.start | footprint: 155MB | resident: 150MB | available: 2917MB | metal: 94MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=full_image source=cold io=0.01s provider=0.00s total=0.01s
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=polaroid_shared_demo source=cold io=0.00s provider=0.00s total=0.00s
[MEM-EVENT] SceneTypeCache.preloadMetadata.summary | id=example_4blocks source=cold io=0.00s provider=0.00s total=0.00s
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7583670660299610766 flush=false hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7583670660299610766 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-5716403520155560519 id=D21394F0-3C4D-48C5-8E38-67B680586889
[MEM-EVENT] UserMediaService.deinit | obj=-2307641527296109063 videoProviders=1
[MEM-EVENT] VideoFrameProvider.release | obj=-7583670660299610766 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-7583670660299610766 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-7583670660299610766
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=2489492149916911162 flush=false hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=8895955064051431987 flush=false hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] Runtime.create.start | id=D07FFD44-EF28-4BE1-A55E-40B03290F506 sceneType=full_image
[MEM-EVENT] SceneTypeCache.preload.start | id=full_image cached=2
[MEM-EVENT] Runtime.create.join | id=D07FFD44-EF28-4BE1-A55E-40B03290F506
[MEM-EVENT] Runtime.create.join | id=D07FFD44-EF28-4BE1-A55E-40B03290F506
[MEM-EVENT] SceneTypeCache.preload.summary | id=full_image source=cold io=0.01s provider=0.00s textures=0.06s total=0.06s
[MEM-EVENT] SceneTypeCache.preload.stored | id=full_image total=3 ids=full_image,polaroid_2,blank_starter
[MEM-EVENT] UserMediaService.init | obj=-1066237720123552266
[MEM-EVENT] SceneInstanceRuntime.init | obj=-8331409614829757579 id=D07FFD44-EF28-4BE1-A55E-40B03290F506 type=full_image
[MEM-EVENT] UMS.cleanupVideo | obj=-1066237720123552266 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=5100900467818089326
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-8331409614829757579 id=D07FFD44-EF28-4BE1-A55E-40B03290F506 restored=1
[MEM-EVENT] Runtime.create.complete | id=D07FFD44-EF28-4BE1-A55E-40B03290F506 outcome=success total=2
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-8331409614829757579 id=D07FFD44-EF28-4BE1-A55E-40B03290F506 frame=2
[MEM-DIAG] playback.stop.before | footprint: 426MB | resident: 142MB | available: 2645MB | metal: 383MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=12 MB=8.7
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 3 [blank_starter,full_image,polaroid_2] loading: 0 | textures: 12 ~43.4MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] displayLink.invalidate | obj=2741942790868494483
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=2489492149916911162 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=8895955064051431987 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 266MB | resident: 142MB | available: 2806MB | metal: 224MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=12 MB=8.7
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 3 [blank_starter,full_image,polaroid_2] loading: 0 | textures: 12 ~43.4MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-DIAG] playback.stop.after.2s | footprint: 262MB | resident: 142MB | available: 2809MB | metal: 224MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 3
[MEM-DIAG]   pool | avail: 4 (3.9MB) | inUse: 0 (~0.0MB) | total: ~3.9MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=12 MB=8.7
[MEM-DIAG]   pool.key | 578x1017 fmt=10 avail=3 inUse=0 MB=1.7
[MEM-DIAG]   pool.key | 578x1017 fmt=80 avail=1 inUse=0 MB=2.2
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 3 [blank_starter,full_image,polaroid_2] loading: 0 | textures: 12 ~43.4MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 3
[MEM-EVENT] Runtime.create.start | id=85A76D56-D8FD-4817-A177-ADFF78F0F980 sceneType=polaroid_shared_demo
[MEM-EVENT] SceneTypeCache.preload.start | id=polaroid_shared_demo cached=3
[MEM-EVENT] SceneTypeCache.preload.summary | id=polaroid_shared_demo source=cold io=0.02s provider=0.00s textures=0.08s total=0.10s
[MEM-EVENT] SceneTypeCache.preload.stored | id=polaroid_shared_demo total=4 ids=polaroid_2,full_image,blank_starter,polaroid_shared_demo
[MEM-EVENT] UserMediaService.init | obj=798270507248808991
[MEM-EVENT] SceneInstanceRuntime.init | obj=-3062050502492999424 id=85A76D56-D8FD-4817-A177-ADFF78F0F980 type=polaroid_shared_demo
[MEM-EVENT] UMS.cleanupVideo | obj=798270507248808991 blockId=block_01
[MEM-EVENT] CVTextureCache.create | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.init | obj=-1602163177558599786
[MEM-EVENT] SceneInstanceRuntime.applyState | obj=-3062050502492999424 id=85A76D56-D8FD-4817-A177-ADFF78F0F980 restored=1
[MEM-EVENT] Runtime.create.complete | id=85A76D56-D8FD-4817-A177-ADFF78F0F980 outcome=success total=3
[MEM-EVENT] SceneInstanceRuntime.prepare | obj=-3062050502492999424 id=85A76D56-D8FD-4817-A177-ADFF78F0F980 frame=0
[MEM-EVENT] displayLink.create | obj=2741942790868494483
[MEM-DIAG] playback.start | footprint: 303MB | resident: 152MB | available: 2768MB | metal: 250MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 3 | UserMediaService: 4 | VideoFrameProvider: 4
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=2489492149916911162 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=8895955064051431987 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=2532609900039247639 id=3078B9FE-1E69-4CF5-9E5D-C1B738A24D09
[MEM-EVENT] UserMediaService.deinit | obj=1029106044995895471 videoProviders=2
[MEM-EVENT] VideoFrameProvider.release | obj=2489492149916911162 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=2489492149916911162 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=2489492149916911162
[MEM-EVENT] VideoFrameProvider.release | obj=8895955064051431987 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=8895955064051431987 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=8895955064051431987
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=false hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-DIAG] playback.stop.before | footprint: 345MB | resident: 148MB | available: 2726MB | metal: 297MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-DIAG]   pool | avail: 6 (1.7MB) | inUse: 0 (~0.0MB) | total: ~1.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=16 MB=9.4
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=80 avail=1 inUse=0 MB=0.4
[MEM-DIAG]   pool.key | 308x392 fmt=80 avail=2 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 308x392 fmt=80 created=2 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 4 [blank_starter,full_image,polaroid_2,polaroid_shared_demo] loading: 0 | textures: 16 ~60.1MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 2
[MEM-EVENT] displayLink.invalidate | obj=2741942790868494483
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1602163177558599786 flush=true hasPlaybackTex=true hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 264MB | resident: 148MB | available: 2807MB | metal: 218MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-DIAG]   pool | avail: 6 (1.7MB) | inUse: 0 (~0.0MB) | total: ~1.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=16 MB=9.4
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=0.9
[MEM-DIAG]   pool.key | 308x392 fmt=80 avail=2 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.key | 302x386 fmt=80 avail=1 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 308x392 fmt=80 created=2 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 4 [blank_starter,full_image,polaroid_2,polaroid_shared_demo] loading: 0 | textures: 16 ~60.1MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 2
[MEM-DIAG] editor.close.before | footprint: 261MB | resident: 148MB | available: 2811MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-DIAG] playback.stop.before | footprint: 261MB | resident: 148MB | available: 2811MB | metal: 218MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-DIAG]   pool | avail: 6 (1.7MB) | inUse: 0 (~0.0MB) | total: ~1.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=16 MB=9.4
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.key | 308x392 fmt=80 avail=2 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=80 avail=1 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 308x392 fmt=80 created=2 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 4 [blank_starter,full_image,polaroid_2,polaroid_shared_demo] loading: 0 | textures: 16 ~60.1MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 2
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1602163177558599786 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-DIAG] playback.stop.after | footprint: 174MB | resident: 148MB | available: 2898MB | metal: 130MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-DIAG]   pool | avail: 6 (1.7MB) | inUse: 0 (~0.0MB) | total: ~1.7MB
[MEM-DIAG]   pool.owner | owner=mask.boolean.bbox created=16 MB=9.4
[MEM-DIAG]   pool.owner | owner=matte.bbox created=2 MB=0.9
[MEM-DIAG]   pool.key | 308x392 fmt=80 avail=2 inUse=0 MB=0.9
[MEM-DIAG]   pool.key | 302x386 fmt=10 avail=3 inUse=0 MB=0.3
[MEM-DIAG]   pool.key | 302x386 fmt=80 avail=1 inUse=0 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=80 created=2 MB=4.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 578x1017 fmt=10 created=6 MB=3.4
[MEM-DIAG]   pool.owner.key | owner=matte.bbox 308x392 fmt=80 created=2 MB=0.9
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=80 created=1 MB=0.5
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=80 created=1 MB=0.4
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 316x383 fmt=10 created=3 MB=0.3
[MEM-DIAG]   pool.owner.key | owner=mask.boolean.bbox 302x386 fmt=10 created=3 MB=0.3
[MEM-DIAG]   sceneTypeCache | cached: 4 [blank_starter,full_image,polaroid_2,polaroid_shared_demo] loading: 0 | textures: 16 ~60.1MB
[MEM-DIAG]   overlayCache | entries: 4 MB: 0.5
[MEM-DIAG]   runtimes: 2
[MEM-DIAG]   videoProviders: 2
[MEM-EVENT] EditorViewController.deinit | obj=5390609472155833905
[MEM-DIAG] editor.close.after | footprint: 171MB | resident: 148MB | available: 2900MB | metal: n/aMB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 2 | UserMediaService: 3 | VideoFrameProvider: 2
[MEM-EVENT] UMS.releasePreview | obj=-6335824930927430849 videoProviders=0 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] TCEngine.releasePreview | runtimes=2 evictCache=true
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=-1066237720123552266 videoProviders=1 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=5100900467818089326 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=5100900467818089326 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=5100900467818089326 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=5100900467818089326
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1602163177558599786 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] UMS.releasePreview | obj=798270507248808991 videoProviders=1 setupTasks=0 stillTasks=0 trimTasks=0 activeVideo=0
[MEM-EVENT] VideoFrameProvider.release | obj=-1602163177558599786 hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1602163177558599786 flush=true hasPlaybackTex=false hasStillTex=true hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.release | obj=-1602163177558599786 hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false
[MEM-EVENT] VideoFrameProvider.stopPlayback | obj=-1602163177558599786 flush=true hasPlaybackTex=false hasStillTex=false hasInteractiveTex=false hasHoldTex=false
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] CVTextureCache.flush | owner=UserMediaTextureFactory
[MEM-EVENT] VideoFrameProvider.deinit | obj=-1602163177558599786
[MEM-EVENT] SceneTypeCache.evictAll | count=4
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-8331409614829757579 id=D07FFD44-EF28-4BE1-A55E-40B03290F506
[MEM-EVENT] UserMediaService.deinit | obj=-1066237720123552266 videoProviders=0
[MEM-EVENT] SceneInstanceRuntime.deinit | obj=-3062050502492999424 id=85A76D56-D8FD-4817-A177-ADFF78F0F980
[MEM-EVENT] UserMediaService.deinit | obj=798270507248808991 videoProviders=0
[MEM-EVENT] Background.clearAll | keys=0
[MEM-DIAG] editor.close.afterTeardown | footprint: 94MB | resident: 140MB | available: 2977MB | metal: 37MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 1 | VideoFrameProvider: 0
[MEM-EVENT] EditorRuntime.deinit | obj=2741942790868494483
[MEM-EVENT] UserMediaService.deinit | obj=-6335824930927430849 videoProviders=0
[MEM-DIAG] editor.close.after.2s | footprint: 47MB | resident: 139MB | available: 3025MB | metal: 1MB | ExportVideoFrameProvider: 0 | SceneInstanceRuntime: 0 | UserMediaService: 0 | VideoFrameProvider: 0