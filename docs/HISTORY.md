# Application & plug-in history

[← Current CamOrder Studio plug-in](../README.md)

CamOrder's current focus is **CamOrder Studio AU 0.8.0**, used as one Audio FX instance on **Logic Pro's Stereo Out**. [Download the current build](https://github.com/santismo/CamOrder/releases/tag/au-v0.8.0) or read its [guide](../CamOrderStudio/README-AU.md).

**Older versions are still available, but they are buggy, unsupported historical builds.** They may contain recording, transport, editing or export problems fixed in later versions. Keep a separate copy of your project before opening it with an older version. Their original instructions describe their behavior at the time and do not replace the current guide.

## Studio Audio Unit development builds

The [historical AU archive](https://github.com/santismo/CamOrder/releases/tag/legacy-au-archive) preserves the Intel macOS 13+ component, matching source, installer and original guide for each build. These are locally signed, unnotarized builds. Each installer targets the same **CamOrder Studio.component**, so installing an old version replaces the current one after making a backup. Quit Logic first.

| Version | Development stage | Download |
| --- | --- | --- |
| 0.7.1 | Cross-lane region moves and recorded-position recovery. Superseded by preview reconnection fixes, visible screen-region controls and window capture. | [0.7.1 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.7.1) |
| 0.7.0 | Live multicamera switching, lane reordering, selected-region preview and bottom controls. Superseded by cross-lane region moves and saved recording positions. | [0.7.0 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.7.0) |
| 0.6.0 | Host-tempo snapping, grouped region editing and explicit output layers. Superseded by live multicamera cuts, lane reordering and export status. | [0.6.0 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.6.0) |
| 0.5.2 | Visible Save, draggable region edges and single-region copy/paste. Superseded by host-tempo snapping, grouped editing and explicit output layers. | [0.5.2 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.5.2) |
| 0.5.1 | Built-in millisecond sync calculator. Superseded by visible Save, improved edge trimming and region copy/paste. | [0.5.1 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.5.1) |
| 0.5.0 | Fixed export anchors and independent lane offsets, layered video, framing markers and one host transport. Superseded by the built-in sync calculator. | [0.5.0 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.5.0) |
| 0.4.0 | Multiple camera inputs and shared defaults. Superseded: edited-timeline export could cancel sync offsets; single top-region playback and older editing/transport behavior. | [0.4.0 release](https://github.com/santismo/CamOrder/releases/tag/au-v0.4.0) |
| 0.3.0 | Dark resizable workspace, hidden controls, export ranges and lane/project sync; one live input. | [0.3.0 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.3.0-Intel-macOS-LEGACY.zip) |
| 0.2.5 | Framing, top-region priority, split and trim fixes; older UI and export workflow. | [0.2.5 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.5-Intel-macOS-LEGACY.zip) |
| 0.2.4 | Logic Link fallback, transport keyboard forwarding and canvas corner controls. | [0.2.4 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.4-Intel-macOS-LEGACY.zip) |
| 0.2.3 | Stereo Out workflow and compact window work; transport still under development. | [0.2.3 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.3-Intel-macOS-LEGACY.zip) |
| 0.2.2 | Host transport/input callback fixes. | [0.2.2 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.2-Intel-macOS-LEGACY.zip) |
| 0.2.1 | Early preview and recording reliability work. | [0.2.1 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.1-Intel-macOS-LEGACY.zip) |
| 0.2.0 | Initial native Studio AU conversion, single source and movie export. | [0.2.0 archive](https://github.com/santismo/CamOrder/releases/download/legacy-au-archive/CamOrder-Studio-AU-0.2.0-Intel-macOS-LEGACY.zip) |

Cuts saved before the 0.2.5 fixes may already have an incorrect source start. New versions cannot infer the intended cut; redo affected cuts from the original take. Original media is unchanged.

## Standalone CamOrder Studio

The original native SwiftUI application used a separate window and CoreMIDI/MTC workflow. It is retained for reference, with known rough edges and incomplete work. It is no longer the primary installation path.

- [Last standalone-focused source snapshot](https://github.com/santismo/CamOrder/tree/9d685ac17c01b33980c4fb28976913efa045fa9e/CamOrderStudio)
- [Download that source snapshot](https://github.com/santismo/CamOrder/archive/9d685ac17c01b33980c4fb28976913efa045fa9e.zip)
- [Original native architecture plan](CAMORDER_STUDIO_PLAN.md), [sync strategy](LOGIC_SYNC_STRATEGY.md) and [milestones](MILESTONES.md)

The standalone target also remains in the current source tree (`cd CamOrderStudio && swift run CamOrderStudio`). Changes shared with the AU may affect it; the frozen snapshot above preserves the earlier app. The standalone app and Studio AU use separate application/component bundles.

## Browser CamOrder

The Chrome-based recorder used browser camera/MIDI APIs and exported WebM/FCPXML packages for a separate FFmpeg/DaVinci Resolve workflow. It remains available with its existing bugs and browser limitations.

- [Open the legacy browser app](https://santismo.github.io/CamOrder/legacy/browser/)
- [Preserved browser source](../legacy/browser/index.html)
- [Original browser workflow and native-app quick start](LEGACY_WORKFLOW.md)

The website's main page now introduces the Studio AU. Browser project-folder access and Chrome permissions still apply to the historical browser app; it is not the Logic plug-in.
