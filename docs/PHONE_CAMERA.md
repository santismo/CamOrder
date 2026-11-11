# CamOrder Camera

[Open the camera app](https://santismo.github.io/CamOrder/phone-camera/) in **Safari on your iPhone or iPad**.

CamOrder Camera is a static, free Home Screen web app. It displays a camera preview on the device. CamOrder Studio on the Mac captures that **device screen over USB**. The page itself does not transmit video over USB or the network and cannot detect whether the cable or recording is active.

## Set up once

1. In Safari, open the link above. Choose **Share → Add to Home Screen**, turn on **Open as Web App** if shown, and tap **Add**.
2. Open **CamOrder Camera** using its Home Screen icon. Tap **Start camera** and allow camera access. It does not request microphone access.
3. Select front/back camera, rotate the device to landscape, and choose **Clean view**. Tap anywhere to show controls again. **Fit** preserves the entire camera picture with black bars as needed; **Fill** crops it to fill the device screen. **Mirror** changes the picture the Mac captures too.
4. Connect a **data-capable USB cable** to the Mac. Unlock the device and choose **Trust** if prompted. iPhone 14 uses Lightning; the M1 iPad uses USB-C.
5. In CamOrder Studio’s **Live Inputs**, refresh the list and select the iPad/iPhone screen input. The iPhone’s **Continuity Camera** may also appear as a separate device. Select the input showing the web app’s preview.
6. Confirm the live picture, assign that source to a video lane, arm the lane, then record with Logic. **Main Stage** shows recorded regions, while **Live Inputs** shows incoming video.

The installed CamOrder Studio 0.9.2 capture helper already includes wired iOS screen discovery; no new phone app binary or Mac virtual-camera extension is required for this workflow. Older builds may differ.

## If the device appears but no picture arrives

Keep the device unlocked with the web app visible and its camera running. Close other apps using the same input. Reconnect the USB cable, then refresh inputs.

To check the underlying USB screen connection independently, open **QuickTime Player → File → New Movie Recording** on the Mac and select the connected device from the menu beside Record. This should display its screen. You do not need to start a QuickTime recording. Close that preview before trying the direct CamOrder input again.

If direct capture still fails, CamOrder’s **Window (choose…) → Choose window…** input on macOS 14+ can capture the QuickTime preview window instead. That path also captures window contents and may need framing/cropping. See [Apple’s QuickTime guide](https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/10.5/mac/26).

## Keeping it available

The Home Screen app has no iOS provisioning/signing expiration. All assets are self-contained and cached by its service worker. Open **?** and wait for **Offline ready** before relying on offline access. Clearing website data or browser storage eviction can require opening the hosted page online again. Hosting and future browser compatibility still matter.

Keep this app in the foreground and the device unlocked during a take. The app requests a screen wake lock when supported; check its status. If unsupported or denied, temporarily set **Settings → Display & Brightness → Auto-Lock → Never**, then restore the usual setting afterward. A Focus can prevent notification banners from appearing in the screen capture.

## Quality and timing

- 1080p/720p and 30 fps are camera capture targets. The app displays the settings actually delivered by the camera; these are not a measurement of the USB capture or final movie.
- The device screen’s resolution/aspect ratio and the Mac capture path can add scaling, black bars or latency. This is not a guaranteed full-resolution camera output.
- Clean view hides this app’s controls. System indicators, notifications or browser chrome can still appear; check the Mac preview.
- Record a visible/audible clap to measure alignment with Logic audio, then use CamOrder’s lane Sync offset. A constant offset does not correct drift.
- No network video streaming, telemetry, external scripts, paid services, accounts or microphone capture are included. GitHub serves the static assets and has its own hosting access logs.

## Development

The app is buildless and uses relative URLs, so it works below GitHub Pages’ `/CamOrder/phone-camera/` path. Its service-worker scope is restricted to that folder. It does not intercept the main CamOrder website.

Run a local HTTP server from the repository root, then open `/phone-camera/` on `localhost`. A phone needs **HTTPS**, not a LAN HTTP address, for camera access.

```sh
python3 -m http.server 8000 --bind 127.0.0.1
node --test tests/phone-camera/*.test.mjs
```

The service worker caches a coherent asset set. Bump its cache version whenever camera assets change. Updates wait until existing app windows close, rather than replacing an active camera session.

## Verification

- Automated camera lifecycle checks cover camera-only constraints, cancellation while permissions are pending, out-of-order camera requests, releasing the prior lens before switching, permission-denied recovery, stale failures, muted/ended tracks, and invalid streams.
- Browser UI checks cover the setup instructions, responsive controls and cancelling a pending camera request. With the local HTTP server stopped, the page reloaded from its service-worker cache and its camera settings remained interactive and persisted across reloads.
- The local installed CamOrder capture helper discovered the attached iPad and accepted it as an input. The initial probe received **no preview frames**, so that is device-discovery evidence only, not proof of working video.
- Full iPad/iPhone camera-preview → USB → CamOrder capture, delivered frame rate and audio alignment still require a physical-device test with this app open and the device unlocked.
