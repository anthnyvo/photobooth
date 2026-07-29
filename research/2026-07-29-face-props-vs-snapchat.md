# Face props vs Snapchat lenses - research brief, 2026-07-29

Feeds the architect. No implementation detail here by design.

Every capability claim carries a URL. Sections marked **[VENDOR]** are the
vendor's own documentation. Sections marked **[INFERENCE]** are my reading and
are not sourced. Where I could not confirm something I have written **not
found** rather than guessing.

## 0. The six limits being measured against

Restating what exists, because the ranking below is scored against these:

| # | Limit | Where it comes from |
|---|---|---|
| L1 | 2D landmark constellation only, no 3D | `VNDetectFaceLandmarksRequest` |
| L2 | Roll only. No yaw, no pitch | roll derived from the eye line |
| L3 | Hand-drawn CoreGraphics. No assets, textures, shading | 11 `draw*` functions |
| L4 | One boolean expression (`hasSmile`) | lip-corner lift vs mouth width |
| L5 | One prop, applied identically to every face | single `PhotoProp` enum |
| L6 | No occlusion. Props always composite on top | flat overlay draw |

## 1. What Snapchat actually does

### Face Mesh and landmarks **[VENDOR]**

Two separate primitives, not one.

- **Face Landmarks: 93 points**, in **screen space**, used to attach objects to
  specific facial locations and to drive interactions based on distance between
  points. https://developers.snap.com/lens-studio/features/ar-tracking/face/face-landmark
- **Face Mesh**: "a 3D mesh that will mimic the user's facial expression in real
  time", with separately toggleable Face, Eye, Mouth, Skull and Ear geometry. A
  custom mesh must share the built-in UV map, and Snap publishes both the UV maps
  and the 3D model for authors to build against.
  https://developers.snap.com/lens-studio/features/ar-tracking/face/face-mesh

**Not found**: the vertex count of the Face Mesh. It is not stated on the Face
Mesh page and I could not locate it in the docs. Do not quote a number for it.

**Not found**: how yaw and pitch are recovered from a monocular frame. Snap
documents the outputs, not the estimator.

### Head attachment and binding **[VENDOR]**

The **Head Binding** component exposes **12 attachment points**: Head Center,
Candide Center, Triangle Barycentric, Face Mesh Center, Left Eyeball, Right
Eyeball, Mouth Center, Chin, Forehead, Left Forehead, Right Forehead, Left
Cheek, Right Cheek. A 3D model is parented under the binding and transforms are
manipulated relative to the binding point.
https://developers.snap.com/lens-studio/features/ar-tracking/face/head-attached-3d-objects

This is the direct analogue of the current `eyeCenter` + `roll` transform, except
it is a full 3D parent transform with a choice of twelve anchors rather than one
2D anchor with one rotation.

### Occluders **[VENDOR]**

Head Binding ships a **Face Occluder child**: a 3D model of a face that "hide[s]
parts of your 3D model as your head turns". Occlusion is a **material**, applied
to any visual, which renders nothing itself but covers other materials.
https://developers.snap.com/lens-studio/features/ar-tracking/face/head-attached-3d-objects
https://developers.snap.com/lens-studio/features/graphics/materials/occluders

This is L6, and note it is only meaningful once L1/L2 are solved: an occluder
needs a depth-sorted 3D scene to sort against.

### Expression triggers **[VENDOR]**

**51 expressions**, each with a continuous **weight** parameter rather than a
boolean. Example given: `EyeBlinkLeft` sits near 0.0 with the eye open and rises
as it closes. Grouped into Brows, Cheeks, Eyes, Jaw, Lips, Mouth, Face. Driven by
blend shape weights, not classifiers. Snap warn against relying on the scale
parameter for large changes because the underlying model keeps changing.
https://developers.snap.com/lens-studio/features/ar-tracking/face/face-templates/face-expressions

That is L4: 51 continuous signals against the current one boolean.

**Not found**: stated latency for expression triggers.

### Face deformation and retouch **[VENDOR]**

From the effects overview
(https://developers.snap.com/lens-studio/features/ar-tracking/face/face-effects-overview):

- **Face Stretch** - "allows you to stretch points of the user's face"
- **Face Liquify** - "spherically warps the face"
- **Face Inset** - "map a feature of your face ... to other areas of your face"
- **Face Retouch** - Soft Skin, Teeth Whitening, Eye Sharpening, Eye Whitening
- **Face Image** - "attaches a 2D textured plane to your head"

**Face Image is worth noting**: even Snapchat's own stack has a flat-plane-on-head
primitive. Not everything is a mesh.

### Multi-face **[VENDOR]**

Head Binding has a **Face Index** setting: 0 for the first detected face, 1 for
the second. Different faces can therefore carry different content.
https://developers.snap.com/lens-studio/features/ar-tracking/face/head-attached-3d-objects

That is L5, and it is a cheap fix conceptually: index the props array by face.

### SnapML **[VENDOR]**

Custom neural networks in **.ONNX** or **.TFLite**, with author control over
whether the model runs every frame, on user action, or on another thread.
Covers both computer vision (detecting glasses) and visual effects (style
transfer).
https://developers.snap.com/lens-studio/features/snap-ml/ml-overview
https://developers.snap.com/lens-studio/features/snap-ml/ml-component/ml-component-overview

**[INFERENCE]** SnapML is an extensibility escape hatch, not the thing that makes
stock lenses look good. It is not on the critical path here.

## 2. Engines that work from a plain RGB frame

### Google MediaPipe Face Landmarker **[VENDOR]**

Capability, and it is the strongest match on paper:

- **478 3-dimensional face landmarks**
- **52 blendshape scores**
- **Facial transformation matrixes**, which "transform the face landmarks from a
  canonical face model to the detected face, so users can apply effects on the
  detected landmarks"
- Models: FaceDetector 192x192 float16, FaceMesh-V2 256x256 float16, Blendshape
  1x146x2 float16, shipped as one bundle
- Running modes IMAGE, VIDEO, LIVE_STREAM
- Accepts **UIImage**, CVPixelBuffer or CMSampleBuffer via `MPImage`, so an
  arbitrary decoded JPEG is a supported input, not just a capture session
- Code samples Apache 2.0

https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker
https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/ios

**Not found**: model bundle file size in MB. **Not found**: any latency benchmark,
on iPad or otherwise. Both pages are silent.

**Not found**: whether the transformation matrix is documented anywhere as
yielding Euler yaw/pitch directly. The docs describe it as a canonical-to-detected
transform and stop there.

#### The blocker

iOS install is **CocoaPods only**:

> "Add the `MediaPipeTasksVision` pod in the `Podfile` using the following code:
> target 'MyFaceLandmarkerApp' do use_frameworks! pod 'MediaPipeTasksVision' end"

https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/ios

Swift Playgrounds cannot run CocoaPods. The only Playgrounds-compatible route
would be a Swift Package, and Playgrounds is reported to fail on packages
containing binary xcframework targets: the importer "spins for a bit and then
nothing happens", with "Failed to resolve package graph" in the device logs.
https://developer.apple.com/forums/thread/698119

**Verdict: hard blocker under the stated build constraint.** MediaPipe is the
right engine and cannot be reached from Swift Playgrounds. This is the single
most important finding in this brief, because MediaPipe was the brief's most
promising lead and it does not survive constraint two.

**[INFERENCE]** There are only two ways past this, and both are decisions rather
than tasks: move the build to Xcode on a Mac, or reimplement the model runner
against Core ML / TFLite in pure Swift, which is a research project of its own.

### Apple Vision **[VENDOR / secondary]**

The important finding, and it is the one that matters most:

`VNDetectFaceRectanglesRequestRevision3` reports **roll, pitch and yaw in
continuous space**, where revision 2 gave roll and yaw in **discrete bins** only.
Apple's WWDC21 session "Detect people, faces, and poses using Vision" covers
"the latest continuous metrics for tracking pitch, yaw, and the roll of the human
head". https://developer.apple.com/videos/play/wwdc2021/10040/

Secondary confirmation of the revision 2 vs 3 difference:
https://www.kodeco.com/29023965-vision-tutorial-for-ios-what-s-new-with-face-detection/page/2

Apple's own API reference pages render as a JavaScript shell and could not be
fetched, so the revision-3 wording above is sourced from Apple's WWDC session plus
one secondary tutorial rather than from the API reference. Flagged deliberately.

**This means L2 is already solved in a framework the app has imported.** The code
derives roll from the eye line and takes nothing else. Yaw and pitch are sitting
on `VNFaceObservation` unread.

**Not found, and it is the key open question**: whether `VNFaceObservation`
instances produced by `VNDetectFaceLandmarksRequest` carry populated `yaw` and
`pitch`, or whether those are only populated by `VNDetectFaceRectanglesRequest`.
The revisions are numbered per request type. This needs a device check, not more
reading. See section 7.

### Commercial SDKs

**Banuba, DeepAR and similar are paid**, and I could not verify their pricing from
a primary source. deepar.ai/pricing returned **HTTP 404**. The figures circulating
(free to 10 MAU with watermark, from about $25/mo at 1,000 MAU, custom above) come
from **Banuba's own competitor-comparison blog**, which is a rival vendor
characterising DeepAR, and should not be treated as DeepAR's terms.
https://www.banuba.com/blog/banuba-vs-deepar-face-mask-sdk-comparison

**[INFERENCE]** Both are distributed as binary iOS frameworks, so they inherit the
same Swift Playgrounds blocker as MediaPipe, on top of being paid and MAU-metered.
MAU metering is also a poor fit for a booth: guests are not accounts, and a busy
event could produce hundreds of "users" per night. Not recommended, and not
because of price.

## 3. The quality gap that is not tracking

**[INFERENCE]** This whole section is my reading. I found no vendor documentation
that states what makes a prop read as premium, and the academic 2.5D material I
found is about game rendering and light-field displays rather than face filters,
so I am not citing it as support.

The honest observation: even with perfect 3D tracking, `cg.fillEllipse` will still
look like `cg.fillEllipse`. The current props have no texture, no gradient, no
shadow, no material response, and no contact shading against the face. That is L3,
and L3 is independent of L1, L2 and L6. Solving tracking does not touch it.

Snapchat's own stack includes **Face Image**, "a 2D textured plane attached to
your head" (vendor, cited above). A textured plane is not a mesh. That is
evidence, from Snap's own documentation, that flat textured geometry is a
legitimate primitive in a premium lens system rather than a compromise.

**[INFERENCE]** The cheapest large step is therefore replacing drawn paths with
authored PNG art with real alpha, soft shadows and painted shading, still drawn as
a flat layer at the same anchor. That changes nothing about tracking and addresses
the limit that tracking cannot fix.

## 4. Ranked by perceived impact per unit of effort

| Rank | Change | Limits addressed | Achievable under all three constraints |
|---|---|---|---|
| 1 | Authored PNG/texture art in place of drawn paths | L3 | **Yes.** Bundled assets, no dependency, no build change, nothing leaves the device. |
| 2 | Read `yaw` and `pitch` off the existing observation and drive perspective/parallax on the prop | L2, partly L1 | **Partly.** Depends on the revision-3 question in section 7. |
| 3 | Per-face prop assignment, indexed like Snap's Face Index | L5 | **Yes.** Pure application logic. |
| 4 | Continuous expression weights instead of one boolean | L4 | **Partly.** Vision exposes landmark geometry, so more continuous signals can be derived by hand, but nothing approaching 51 blendshapes without a new model. |
| 5 | A crude occluder using the existing face contour landmarks | L6 | **Partly.** A 2D contour mask can hide a prop behind a face edge. Real head-turn occlusion needs the 3D mesh from rank 6. |
| 6 | True 3D mesh with 478 landmarks and 52 blendshapes | L1, L4, L6 fully | **No.** MediaPipe is CocoaPods-only and Playgrounds cannot resolve binary targets. Blocked by constraint two, not by effort. |

**[INFERENCE]** The ranking is mine. The ordering logic is that rank 1 is the only
item that is simultaneously the largest visible change, fully unblocked, and
independent of every unresolved technical question.

## 5. Recommended minimum change

**Replace the hand-drawn CoreGraphics props with authored texture assets, keeping
the existing anchor and roll transform exactly as it is.**

One thing, deliberately. Reasoning:

- It attacks **L3**, which is the limit that no amount of tracking work fixes and
  the one a guest actually sees in a printed strip.
- It is **unblocked**: no dependency, no CocoaPods, no Playgrounds problem, no
  model, no cloud, nothing leaves the iPad.
- It is **independent of every open question** in section 7. It does not care
  whether yaw is populated.
- The existing anchor maths already gives eye centre, eye distance, mouth and
  face width, so an asset can be placed and scaled with what is already computed.
- **[INFERENCE]** It is also the change most likely to survive a later tracking
  upgrade: better art stays better art when yaw arrives.

Explicitly **not** recommending "add yaw" as the minimum, despite it ranking
second and looking free, because it is gated on an unverified assumption about
which Vision request populates the field.

## 6. What not to chase

- **ARKit, ARFaceAnchor, the 52 ARKit blendshapes.** Ruled out by the brief and
  correctly: the capture device is a tethered DSLR, and there is no TrueDepth data
  in that pipeline at all.
- **MediaPipe, under the current build setup.** It is the technically correct
  answer and it is unreachable from Swift Playgrounds. Revisit only if the build
  moves to Xcode, and treat that as the decision it is.
- **Commercial face SDKs.** Same binary-framework blocker, plus MAU pricing that
  fits a booth badly, plus unverifiable published terms.
- **Face deformation (Stretch, Liquify, Inset).** **[INFERENCE]** These need dense
  mesh warping, which is L1, which is blocked. They are also the effects most
  likely to be unflattering in a printed keepsake that a guest takes home, which
  is a different product from a disappearing social post.
- **Chasing 51 expression triggers.** The booth's interaction model is a countdown
  and a shutter, not continuous live puppetry. **[INFERENCE]** More than a handful
  of expression signals has nowhere to be spent here.
- **SnapML equivalents.** Extensibility for a platform with third-party authors.
  There are no third-party authors here.

## 7. Open questions needing a device benchmark

These cannot be resolved by more reading, and each one changes the ranking above.

1. **Does `VNDetectFaceLandmarksRequest` populate `yaw` and `pitch` on its
   `VNFaceObservation`, or only `VNDetectFaceRectanglesRequest`?** Revisions are
   numbered per request type. If landmarks does not populate them, rank 2 costs a
   second Vision request per frame, which changes its position in the ranking.
2. **What is the actual per-frame cost of revision 3** against whatever revision
   the request currently defaults to, at the 1024px detection size, on the booth's
   real iPad? The live loop runs at roughly 11 scans/sec and that budget is
   already spent.
3. **How stable are yaw and pitch frame to frame** at booth distance and booth
   lighting? The existing smoother is tuned for positional jitter at alpha 0.45.
   Angular jitter on an unsmoothed axis would read as a prop swinging.
4. **What does yaw do at the edges?** A guest turning to talk to someone mid-strip
   is the common case. Whether Vision degrades gracefully or snaps is a visual
   judgement, not a spec question.
5. **Does texture asset drawing hold the frame budget?** Drawing a bundled PNG per
   face per frame is not obviously cheaper or dearer than the current path fills.
   Needs measuring before rank 1 is committed, and it is the only risk to the
   recommendation.
6. **Does any of this survive the print?** Props are burned into the saved file.
   A soft-shadowed PNG that reads well on the iPad may look muddy at print DPI on
   the printer being sold with the booth. **[INFERENCE]** This is the one that
   could invalidate the whole recommendation, and it is answerable in the hardware
   dry run rather than by a separate benchmark.
