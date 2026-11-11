# CamOrder session follow-up

## Pending reminder — requested November 10, 2026

At the start of the next CamOrder development session, briefly remind the user to revisit the direct-camera ideas in [docs/PHONE_CAMERA.md](docs/PHONE_CAMERA.md#deferred-development-ideas).

The user confirmed that the current USB screen-camera setup works and is giving good results. Keep it as the current approach. The direct-camera ideas are deferred exploration, not an instruction to start implementing them now.

The reminder should cover a browser/WebRTC camera stream into a CamOrder receiver, iPhone Continuity Camera, and whether a future wired alternative can meet the user's constraints. The user wants a free, lasting setup without a paid Apple developer account or weekly app reinstallation; acceptance of Wi-Fi has not been decided.

Also revisit preview playback performance inside the actual CamOrder plug-in. The user suggested lower-quality previews. Evaluate a preview-quality setting and smaller proxy media when decoding is the bottleneck, while keeping original recording/export quality and timing intact. Profile before choosing the implementation: Main Stage currently opens original media through AVPlayer, while the helper's Live Inputs preview already scales frames to at most 960 × 640. Simply shrinking an already-decoded image may not fix decoding cost. Keep this separate from the documented silent-section freezes caused by missing Logic transport callbacks; reduced preview quality does not resolve missing timing information. This remains a development idea, not an implemented setting.

After delivering this reminder in a future session, mark it delivered here so it does not recur automatically.
