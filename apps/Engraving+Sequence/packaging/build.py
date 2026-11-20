#!/usr/bin/python3
"""Build Ubuntu 24.04 amd64 binary packages from this working workstation."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile

PROJECT = Path(__file__).resolve().parents[1]
TEMPLATES = PROJECT / 'packaging/templates'
SERVICE_ROOT = PROJECT.parents[1] / 'services/paddleocr_service'
PRELOAD_NAMES = {'liblsp.so'}  # Workstation VPN injection, never an application dependency.


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def elf(path):
    try:
        with path.open('rb') as f:
            return f.read(4) == b'\x7fELF'
    except (OSError, IsADirectoryError):
        return False


def ignore(directory, names):
    return {n for n in names if n in {'__pycache__', '.git', 'tests', 'test'} or n.endswith(('.pyc', '~'))}


class Package:
    def __init__(self, stage, name, version, install_root="opt/engraving-sequence"):
        self.root = stage / name
        self.root.mkdir(parents=True, exist_ok=False)
        self.app = self.root / install_root
        self.app.mkdir(parents=True)
        self.name, self.version = name, version
        self.objects = {}  # destination -> original ELF, for dependency discovery before relocation
        self.packages = {'libc6', 'ca-certificates'}
        self.libraries = []
        self.owners = {}
        # Index both merged-/usr spellings once, rather than invoking dpkg-query per library.
        for listing in Path('/var/lib/dpkg/info').glob('*.list'):
            package = listing.name[:-5].split(':')[0]
            for path in listing.read_text(errors='replace').splitlines():
                self.owners[path] = package
                if path.startswith('/usr/lib/'):
                    self.owners[path[4:]] = package
                elif path.startswith('/lib/'):
                    self.owners['/usr' + path] = package

    def copy(self, src, dest):
        src, dest = Path(src), self.app / dest
        if not src.exists():
            raise RuntimeError(f'Missing runtime input: {src}')
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dest, ignore=ignore, symlinks=False)
            for file in dest.rglob('*'):
                if file.is_file() and elf(file):
                    self.objects[file] = src / file.relative_to(dest)
        else:
            shutil.copy2(src, dest)
            if elf(dest):
                self.objects[dest] = src
        return dest

    def dependencies(self, library_dir):
        libdir = self.app / library_dir
        libdir.mkdir(parents=True, exist_ok=True)
        # Vendor archives sometimes omit SONAME symlinks (e.g. FFmpeg).
        # Build a source SONAME index so these still resolve, then add private aliases.
        sonames = {}
        for dest, source in self.objects.items():
            soname = run('patchelf', '--print-soname', str(dest))
            if not soname and ('.so' in dest.name or dest.suffix == '.cti'):
                soname = dest.name  # dlopen-only libraries can omit DT_SONAME
            if soname:
                sonames[soname] = source
                alias = libdir / soname
                if not alias.exists() and alias != dest:
                    alias.symlink_to(os.path.relpath(dest, libdir))
        inspected = set()
        recorded = set()
        while True:
            pending = [src for src in self.objects.values() if src not in inspected]
            if not pending:
                break
            def inspect(src):
                process = subprocess.run(['ldd', str(src)], cwd=PROJECT, text=True, capture_output=True)
                output = process.stdout + process.stderr
                deps = []
                for missing in re.findall(r'(\S+) => not found', output):
                    if missing not in sonames:
                        raise RuntimeError(f'Unresolved dependencies for {src}:\n{output}')
                    deps.append((missing, sonames[missing]))
                for line in output.splitlines():
                    match = re.match(r'\s*(\S+) => (\S+) \(0x', line)
                    if match:
                        name, path = match.groups()
                    else:
                        match = re.match(r'\s*(\S+) \(0x', line)
                        if not match:
                            continue
                        path = match.group(1)
                        name = Path(path).name
                    if name == 'linux-vdso.so.1' or Path(path).name in PRELOAD_NAMES:
                        continue
                    p = Path(path)
                    if not p.is_absolute():
                        p = PROJECT / p
                    if p.exists():
                        deps.append((Path(name).name, p))
                return deps
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(inspect, pending))
            inspected.update(pending)
            source_objects = {p.resolve() for p in self.objects.values()}
            for deps in results:
                for soname, source in deps:
                    # Conda dependencies may resolve an older compiler runtime.
                    # Ubuntu 24.04's C/C++ ABI libraries must win for the whole process.
                    if soname in {'libstdc++.so.6', 'libgcc_s.so.1'}:
                        source = Path('/usr/lib/x86_64-linux-gnu') / soname
                    key = (soname, str(source))
                    if key in recorded:
                        continue
                    recorded.add(key)
                    owner = self.owners.get(str(source)) or self.owners.get(str(source.resolve()))
                    if owner and not str(source).startswith(('/opt/', '/usr/local/', '/home/')):
                        self.packages.add(owner)
                        mode = 'ubuntu'
                    elif source.resolve() in source_objects or soname in sonames:
                        mode = 'bundled-in-place'
                    else:
                        dest = libdir / soname
                        if dest.exists() and hashlib.sha256(dest.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
                            raise RuntimeError(f'Conflicting private library {soname}: {source}')
                        if not dest.exists():
                            self.copy(source, str(dest.relative_to(self.app)))
                        mode = 'bundled'
                    self.libraries.append({'soname': soname, 'source': str(source), 'delivery': mode, 'ubuntu_package': owner})
        # Remove development absolute RPATHs; retain wheel-local $ORIGIN paths.
        for dest in self.objects:
            old = run('patchelf', '--print-rpath', str(dest))
            paths = [p for p in old.split(':') if p.startswith('$ORIGIN') and '/home/' not in p]
            paths += ['$ORIGIN', '$ORIGIN/' + os.path.relpath(libdir, dest.parent)]
            subprocess.run(['patchelf', '--set-rpath', ':'.join(dict.fromkeys(paths)), str(dest)], check=True)
            # Absolute DT_NEEDED entries also defeat relocation.
            needed = run('patchelf', '--print-needed', str(dest)).splitlines()
            for name in needed:
                if '/' in name:
                    subprocess.run(['patchelf', '--replace-needed', name, Path(name).name, str(dest)], check=True)

    def template(self, source, target, executable=False, **values):
        text = (TEMPLATES / source).read_text()
        for key, value in values.items():
            text = text.replace('@' + key + '@', str(value))
        path = self.root / target
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755 if executable else 0o644)

    def finish(self, output, description, extra=''):
        control = self.root / 'DEBIAN'
        control.mkdir(exist_ok=True)
        size = sum(p.stat().st_size for p in self.root.rglob('*') if p.is_file()) // 1024
        (control / 'control').write_text(f'''Package: {self.name}
Version: {self.version}
Architecture: amd64
Maintainer: Engraving Sequence Deployment <deployment@localhost>
Section: graphics
Priority: optional
Installed-Size: {size}
Depends: {', '.join(sorted(self.packages))}
{extra}Description: {description}
 Precompiled runtime for Ubuntu 24.04 amd64. No compiler is needed on the target.
''')
        doc = self.root / 'usr/share/doc' / self.name
        doc.mkdir(parents=True, exist_ok=True)
        (doc / 'runtime-manifest.json').write_text(json.dumps({'package': self.name, 'version': self.version,
            'build_os': Path('/etc/os-release').read_text(), 'libraries': self.libraries,
            'system_dependencies': sorted(self.packages)}, indent=2) + '\n')
        # Copy available vendor notices and Python package licenses along with their runtimes.
        shutil.copy2(PROJECT / 'packaging/README.md', doc / 'README.md')
        for p in self.root.rglob('*'):
            if not p.is_symlink():
                p.chmod(0o755 if p.is_dir() or os.access(p, os.X_OK) else 0o644)
        result = output / f'{self.name}_{self.version}_amd64.deb'
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zzstd', '-z3', '--build', str(self.root), str(result)], check=True)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='1.1.0')
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--output', type=Path, default=PROJECT / 'dist')
    parser.add_argument('--component', choices=['client', 'ocr', 'all'], default='client',
                        help='Build the camera client (default), standalone shared OCR, or both independently')
    parser.add_argument('--ocr-venv', type=Path, default=SERVICE_ROOT / '.venv')
    parser.add_argument('--models', type=Path, default=SERVICE_ROOT / '.cache/official_models')
    parser.add_argument('--mvs', type=Path, default=Path('/opt/MVS'))
    parser.add_argument('--config', type=Path, default=PROJECT / 'src', help='Directory containing five Scheme defaults')
    args = parser.parse_args()
    if platform.machine() != 'x86_64' or 'VERSION_ID="24.04"' not in Path('/etc/os-release').read_text():
        parser.error('Build on Ubuntu 24.04 amd64, matching the deployment target')
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+~\-]*', args.version):
        parser.error('Invalid Debian version')
    for tool in ('patchelf', 'dpkg-deb', 'ldd'):
        if not shutil.which(tool):
            parser.error(f'Build workstation needs {tool}')
    binary = args.binary
    if args.component != 'ocr' and binary is None:
        matches = list((PROJECT / '.stack-work/dist').glob('*/ghc-*/build/Camera/Camera'))
        if len(matches) != 1:
            parser.error('Pass --binary pointing to the executable from stack build')
        binary = matches[0]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = output / ('stage-' + args.version + '-' + args.component)
    if stage.exists():
        parser.error(f'{stage} already exists; remove that generated staging directory or choose a new version')
    stage.mkdir()
    artifacts = []
    if args.component in {'client', 'all'}:
        gui = Package(stage, 'engraving-sequence', args.version)
        gui.packages.update({'util-linux', 'libgl1-mesa-dri', 'libglx-mesa0'})
        gui.copy(binary, 'bin/Camera')
        for name in ('vert.glsl', 'frag.glsl', 'font', 'img'):
            gui.copy(PROJECT / name, 'assets/' + name)
        gui.copy(PROJECT / 'src/window.png', 'assets/src/window.png')
        for name in ('fun.scm', 'my.scm', 'config1.scm', 'config2.scm', 'config3.scm'):
            gui.copy(args.config / name, 'defaults/' + name)
        # Include transport libraries loaded at runtime, which do not appear in Camera's ldd list.
        gui.copy(args.mvs / 'lib/64', 'mvs/lib/64')
        gui.copy(args.mvs / 'license', 'mvs/license')
        gui.dependencies('native/lib')
        gui.template('launcher', 'opt/engraving-sequence/launch', executable=True)
        gui.template('desktop', 'usr/share/applications/engraving-sequence.desktop')
        gui.template('settings', 'etc/engraving-sequence/settings')
        gui.template('udev', 'usr/lib/udev/rules.d/70-engraving-sequence-camera.rules')
        gui.template('gui-postinst', 'DEBIAN/postinst', executable=True)
        gui.template('gui-postrm', 'DEBIAN/postrm', executable=True)
        (gui.root / 'DEBIAN/conffiles').write_text('/etc/engraving-sequence/settings\n')
        binlink = gui.root / 'usr/bin/engraving-sequence'
        binlink.parent.mkdir(parents=True, exist_ok=True)
        binlink.symlink_to('/opt/engraving-sequence/launch')
        artifacts.append(gui.finish(output, 'Engraving Sequence camera OCR inspection'))
    if args.component in {'ocr', 'all'}:
        print('Bundling the tested Python runtime and installed OCR packages...', flush=True)
        ocr = Package(stage, 'paddleocr-service', args.version, 'opt/paddleocr-service')
        venv_python = args.ocr_venv / 'bin/python'
        config = json.loads(run(str(venv_python), '-c',
            'import json,sys,sysconfig; print(json.dumps({"base":sys.base_prefix,"version":f"{sys.version_info.major}.{sys.version_info.minor}","packages":sysconfig.get_path("purelib")}))'))
        base, version = Path(config['base']), config['version']
        ocr.copy(venv_python.resolve(), 'python/bin/python3')
        stdlib = base / 'lib' / ('python' + version)
        target = ocr.app / 'python/lib' / ('python' + version)
        target.mkdir(parents=True)
        for item in stdlib.iterdir():
            if item.name in {'site-packages', '__pycache__', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip'} or item.name.startswith('config-'):
                continue
            ocr.copy(item, str((target / item.name).relative_to(ocr.app)))
        ocr.copy(Path(config['packages']), f'python/lib/python{version}/site-packages')
        ocr.copy(SERVICE_ROOT / 'server.py', 'ocr/server.py')
        ocr.copy(args.models, 'ocr/models')
        (ocr.app / 'ocr/python-packages.txt').write_text(run(str(venv_python), '-m', 'pip', 'freeze') + '\n')
        ocr.dependencies('python/lib')
        ocr.template('ocr-launcher', 'opt/paddleocr-service/ocr/launch', executable=True)
        ocr.template('service', 'usr/lib/systemd/system/paddleocr-service.service')
        ocr.template('ocr-postinst', 'DEBIAN/postinst', executable=True)
        ocr.template('ocr-prerm', 'DEBIAN/prerm', executable=True)
        ocr.template('ocr-postrm', 'DEBIAN/postrm', executable=True)
        ocr.packages.add('systemd')
        ocr.template('ocr-settings', 'etc/paddleocr-service/settings')
        (ocr.root / 'DEBIAN/conffiles').write_text('/etc/paddleocr-service/settings\n')
        cli = ocr.root / 'usr/bin/paddleocr-service'
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.symlink_to('/opt/paddleocr-service/ocr/launch')
        artifacts.append(ocr.finish(output, 'Shared two-worker CPU PaddleOCR ZeroMQ service',
            'Conflicts: engraving-sequence-ocr\nReplaces: engraving-sequence-ocr\n'))
    # Each package has an independent installer/archive and no cross-package dependency.
    bundles = []
    for artifact in artifacts:
        name = artifact.name.split('_')[0]
        release = output / f'{name}-{args.version}'
        release.mkdir(exist_ok=False)
        shutil.copy2(artifact, release / artifact.name)
        (release / 'install.sh').write_text((TEMPLATES / 'install.sh').read_text()
            .replace('@PACKAGE@', name).replace('@VERSION@', args.version))
        (release / 'install.sh').chmod(0o755)
        shutil.copy2(PROJECT / 'packaging/README.md', release / 'README.md')
        shutil.copy2(PROJECT / 'packaging/DEPENDENCIES.md', release / 'DEPENDENCIES.md')
        with artifact.open('rb') as file:
            digest = hashlib.file_digest(file, 'sha256').hexdigest()
        (release / 'SHA256SUMS').write_text(f'{digest}  {artifact.name}\n')
        bundle = output / f'{name}_{args.version}_ubuntu24.04_amd64.tar'
        with tarfile.open(bundle, 'w') as archive:
            for path in sorted(release.iterdir()):
                archive.add(path, arcname=path.name)
        bundles.append(bundle)
    print('\nBuilt:', *(str(p) for p in artifacts + bundles), sep='\n')


if __name__ == '__main__':
    main()
