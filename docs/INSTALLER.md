# Native Mac installer

The main website download is a DMG containing **Install CamOrder Studio.pkg**. A direct PKG is available for people who prefer to download one file and double-click straight into the macOS Installer. The original ZIP remains available as an alternative.

## Install

1. Open the DMG and double-click **Install CamOrder Studio.pkg**.
2. Follow the macOS Installer. It chooses the current account’s Audio Unit directory, `~/Library/Audio/Plug-Ins/Components`, automatically.
3. Fully quit and reopen Logic. On Stereo Out, insert **Audio FX → Audio Units → Santismo → CamOrder Studio → Stereo**.

The package includes the AU and its embedded capture helper. It replaces an older component at that location, skips a newer installed bundle, and does not install copies into the system Library or relocate a bundle to a source/build directory. The native installer uses macOS package upgrade behavior; unlike the ZIP’s command installer, it does not make a separate archived backup. Project folders, recordings and Logic sessions are outside its payload. It does not quit Logic, reset preferences, alter permissions, remove quarantine attributes or disable security controls.

This download is **Intel, macOS 13+**. The installer has a minimum OS requirement and rejects Apple silicon for this Intel-only release. The script can also package an Apple silicon or universal component when such a build has been validated.

## Signing status

The current component is locally signed. The PKG and DMG are **unsigned and not notarized**. A DMG alone does not remove Gatekeeper checks: macOS may require approval in **System Settings → Privacy & Security** after opening the package. Follow [Apple’s guidance](https://support.apple.com/102445) only if you trust the downloaded file. A public release without that extra approval needs Developer ID signing and Apple notarization; the local development identity is not a substitute.

## Build

After building and validating the AU:

```sh
cd CamOrderStudio
python3 Scripts/package-installer.py --output-dir dist/installer
```

The builder verifies the component’s signature, reads its version and CPU architecture, and writes a PKG, DMG and SHA-256 checksums. It refuses to overwrite existing outputs. Installer resources live in `CamOrderStudio/Installer`.

Stable asset names let the website use GitHub’s `/releases/latest/download/…` links without advertising version numbers. Publish the matching DMG and PKG assets when making future releases, along with their checksums. Version metadata remains inside the component, package and release notes.

The package has no shell installation scripts. [Apple’s current-user installation domain](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html) limits installation to the current account. Installer’s built-in upgrade handling replaces bundle contents, with relocation disabled for both the AU and capture helper.

## Verification

Checked on an Intel Mac on September 28, 2026, using the existing validated AU build:

- `hdiutil verify` passed; the read-only mounted DMG contains the exact standalone PKG, start instructions and license.
- `installer -dominfo` lists only `CurrentUserHomeDirectory`; `-showChoicesXML` accepts the package on this supported Mac.
- Expanding the PKG confirms the minimum macOS requirement, architecture check, current-user-only domain, fixed plug-in location and disabled bundle relocation.
- Every payload file, including the embedded capture helper, matches the verified component byte for byte.
- `installer -pkg … -target CurrentUserHomeDirectory` completed successfully, without root. Its receipt identifies the account’s Library/Audio/Plug-Ins/Components location.
- The installed bundle and helper retain their exact contents, current-user ownership and valid deep/strict code signatures. The installed AU also passed `auval -v aufx CmSt Sntm` after package installation.

The installer was exercised through macOS’s installation engine. Download quarantine approval and an Apple silicon rejection were not exercised on separate machines. The binary is unchanged by this packaging update; existing AU feature verification is recorded in [VERIFICATION-0.6.0.md](VERIFICATION-0.6.0.md).
