#!/usr/bin/env python3
"""Package an already built AU, matching source and public documentation on macOS."""
import argparse
import hashlib
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    project = Path(__file__).resolve().parents[1]
    repo = project.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=project / 'dist')
    args = parser.parse_args()
    component = project / 'dist/CamOrder Studio.component'
    if not component.is_dir():
        parser.error('Run Scripts/build-au.sh first.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(component)], check=True)
    info = plistlib.loads((component / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    binary = component / 'Contents/MacOS/CamOrderStudioAU'
    arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    architecture = {'x86_64': 'Intel', 'arm64': 'Apple-silicon'}.get(arch, 'Universal')
    name = f'CamOrder-Studio-AU-{version}-{architecture}-macOS'
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{name}.zip'
    if archive.exists():
        parser.error(f'Refusing to overwrite {archive}')
    with tempfile.TemporaryDirectory(prefix='camorder-release-') as temporary:
        release = Path(temporary) / name
        release.mkdir()
        subprocess.run(['ditto', '--norsrc', '--noextattr', '--noqtn', str(component), str(release / component.name)], check=True)
        shutil.copytree(project, release / 'Source/CamOrderStudio', ignore=shutil.ignore_patterns('.build', 'dist', '.DS_Store', '__pycache__', '.codex'))
        shutil.copy2(repo / 'LICENSE', release / 'Source/LICENSE')
        shutil.copy2(project / 'README-AU.md', release / 'READ ME.md')
        verification = repo / f'docs/VERIFICATION-{version}.md'
        if verification.exists():
            shutil.copy2(verification, release / 'VERIFICATION.md')
        screenshot = repo / 'docs/images/camorder-studio-au.png'
        if screenshot.exists():
            shutil.copy2(screenshot, release / 'editor.png')
        installer = release / 'Install CamOrder Studio.command'
        installer.write_text('''#!/bin/bash
set -euo pipefail
release="$(cd "$(dirname "$0")" && pwd)"
"$release/Source/CamOrderStudio/Scripts/install-au.sh" "$release/CamOrder Studio.component"
printf '\\nDone. Fully quit and reopen Logic Pro to load this update.\\n'
''')
        installer.chmod(0o755)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(release / component.name)], check=True)
        subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(release), str(archive)], check=True)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{checksum}  {archive.name}\n')
    print(f'Packaged {version} ({arch}): {archive}')


if __name__ == '__main__':
    main()
