# DicyaninLabsMoCapRecording

Open-source Swift package for recording ARKit full-body motion capture on iPhone, exporting it as a portable `.arkitbodyanim` file, and playing it back to drive Mixamo-rigged human figures or 2D wireframe skeletons.

## Features

- Record `ARBodyTrackingConfiguration` skeleton data on iPhone (`ARBodyCaptureSession` + `MoCapRecorder`).
- Portable `.arkitbodyanim` file type (versioned JSON, `ARKitBodyAnim`).
- Retarget recorded ARKit joints onto a Mixamo humanoid rig (`MixamoRetargeter`), since the ARKit body rig and Mixamo rig share humanoid topology.
- Drive a RealityKit `ModelEntity` skeleton for playback on existing Mixamo nurse models (`RealityKitSkeletonDriver`).
- Animated 2D wireframe skeleton rendering in SwiftUI (`SkeletonWireView`, `MoCapWirePlayerView`).

## Platforms

- iOS 17+ (live capture)
- visionOS 1+ / macOS 14+ (playback, retargeting, wireframe view)

## Record (iPhone)

```swift
let recorder = MoCapRecorder(frameRate: 60)
let capture = ARBodyCaptureSession(recorder: recorder)
capture.run()
recorder.start(name: "chest-compressions")
// ...perform movement...
let anim = recorder.stop()
try anim.write(to: url) // url.pathExtension == "arkitbodyanim"
```

## Play back on a Mixamo model (RealityKit)

```swift
let anim = try ARKitBodyAnim.read(from: url)
let player = MoCapPlayer(anim: anim)
let driver = RealityKitSkeletonDriver(model: nurseModelEntity)
player.onFrame = { frame in driver.apply(frame) }
player.play()
// in the RealityView update loop: player.tick(delta: dt)
```

## 2D wireframe preview

```swift
MoCapWirePlayerView(anim: anim, projection: .frontXY)
```

## `.arkitbodyanim` format

Versioned JSON document: magic string, version, name, createdAt, frameRate, jointOrder, and per-frame root + parent-relative local joint transforms (4x4 column-major). Joint names match ARKit's `ARSkeleton.JointName` raw strings and map to Mixamo bone names via `ARKitBodyJoint.mixamoBoneName`.
