#!/usr/bin/env python3
"""Build a per-user macOS Installer package and DMG from an already verified AU."""
import argparse
import hashlib
import html
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


PACKAGE_ID = 'com.santismo.camorder-studio.au.installer'
INSTALL_LOCATION = '/Library/Audio/Plug-Ins/Components'


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def distribution(version, arch):
    # Evaluate natively on either CPU so an Intel package cannot silently select
    # Rosetta and look compatible with an unvalidated Apple silicon installation.
    check = {
        'Intel': ('isAppleSilicon', 'This download requires an Intel Mac. Apple silicon builds are available from source.'),
        'Apple-silicon': ('!isAppleSilicon', 'This download requires a Mac with Apple silicon.'),
        'Universal': ('false', ''),
    }[arch]
    return f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>CamOrder Studio</title>
  <welcome file="Welcome.html" mime-type="text/html"/>
  <conclusion file="Conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" allow-external-scripts="no" hostArchitectures="x86_64,arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <installation-check script="checkHost()"/>
  <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
  <script><![CDATA[
    function checkHost() {{
      var isAppleSilicon = system.sysctl('hw.optional.arm64') == 1;
      if ({check[0]}) {{
        my.result.type = 'Fatal';
        my.result.message = '{check[1]}';
        return false;
      }}
      return true;
    }}
  ]]></script>
  <choices-outline><line choice="camorder"/></choices-outline>
  <choice id="camorder" title="CamOrder Studio" description="Video editor and capture helper" visible="false">
    <pkg-ref id="{PACKAGE_ID}"/>
  </choice>
  <pkg-ref id="{PACKAGE_ID}" version="{html.escape(version, quote=True)}" onConclusion="none">CamOrderComponent.pkg</pkg-ref>
</installer-gui-script>
'''


def build(component, output):
    project = Path(__file__).resolve().parents[1]
    run('codesign', '--verify', '--deep', '--strict', component)
    info = plistlib.loads((component / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    binary = component / 'Contents/MacOS/CamOrderStudioAU'
    archs = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
    if archs == {'x86_64'}:
        arch = 'Intel'
    elif archs == {'arm64'}:
        arch = 'Apple-silicon'
    elif archs == {'x86_64', 'arm64'}:
        arch = 'Universal'
    else:
        raise ValueError(f'Unsupported architectures: {sorted(archs)}')
    output.mkdir(parents=True, exist_ok=True)
    # Stable release asset names keep the website independent of version numbers.
    package = output / f'CamOrder-Studio-Installer-{arch}.pkg'
    dmg = output / f'CamOrder-Studio-{arch}.dmg'
    for path in (package, dmg, package.with_suffix('.pkg.sha256'), dmg.with_suffix('.dmg.sha256')):
        if path.exists():
            raise FileExistsError(f'Refusing to overwrite {path}')
    with tempfile.TemporaryDirectory(prefix='camorder-installer-') as directory:
        stage = Path(directory)
        payload = stage / 'payload'
        payload.mkdir()
        run('ditto', '--norsrc', '--noextattr', '--noqtn', component, payload / component.name)
        run('codesign', '--verify', '--deep', '--strict', payload / component.name)
        config = stage / 'components.plist'
        run('pkgbuild', '--analyze', '--root', payload, config)
        components = plistlib.loads(config.read_bytes())

        def configure(bundles):
            for bundle in bundles:
                # Never relocate the AU/helper to a build folder or merge stale
                # executable files into an update. Keep newer installed versions.
                bundle['BundleIsRelocatable'] = False
                bundle['BundleIsVersionChecked'] = True
                bundle['BundleOverwriteAction'] = 'upgrade'
                configure(bundle.get('ChildBundles', []))

        configure(components)
        config.write_bytes(plistlib.dumps(components))
        run('pkgbuild', '--root', payload, '--component-plist', config,
            '--identifier', PACKAGE_ID, '--version', version,
            '--install-location', INSTALL_LOCATION, stage / 'CamOrderComponent.pkg')
        definition = stage / 'Distribution.xml'
        definition.write_text(distribution(version, arch))
        run('productbuild', '--distribution', definition, '--resources', project / 'Installer',
            '--package-path', stage, package)
        image_root = stage / 'disk'
        image_root.mkdir()
        shutil.copy2(package, image_root / 'Install CamOrder Studio.pkg')
        (image_root / 'Start Here.txt').write_text(f'''CAMORDER STUDIO — A VIDEO EDITOR INSIDE LOGIC PRO

1. Double-click Install CamOrder Studio.pkg and follow the installer.
2. Fully quit and reopen Logic Pro.
3. On Stereo Out, choose Audio FX > Audio Units > Santismo > CamOrder Studio > Stereo.

This {arch} download requires macOS 13 or later.
The installer chooses your account’s Audio Unit folder automatically.
It installs the plug-in and its capture helper, and replaces an older plug-in.
Your CamOrder recordings and Logic projects are not part of the installation.

Development build: the package is unsigned and not notarized. macOS may
require approval in System Settings > Privacy & Security after you try to
open the package. Follow Apple’s instructions only if you trust this download:
https://support.apple.com/102445

Help and examples: https://santismo.github.io/CamOrder/
Source and ZIP alternative: https://github.com/santismo/CamOrder/releases/latest
''')
        shutil.copy2(project.parent / 'LICENSE', image_root / 'License.txt')
        run('hdiutil', 'create', '-volname', 'Install CamOrder Studio', '-srcfolder', image_root,
            '-format', 'UDZO', '-fs', 'HFS+', dmg)
        run('hdiutil', 'verify', dmg)
    for path in (package, dmg):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_suffix(path.suffix + '.sha256').write_text(f'{digest}  {path.name}\n')
    print(f'Packaged CamOrder {version} ({arch}):\n{package}\n{dmg}')
    return package, dmg


def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', type=Path, default=project / 'dist/CamOrder Studio.component')
    parser.add_argument('--output-dir', type=Path, default=project / 'dist')
    args = parser.parse_args()
    if not args.component.is_dir():
        parser.error('Run Scripts/build-au.sh first.')
    build(args.component.resolve(), args.output_dir.resolve())


if __name__ == '__main__':
    main()
