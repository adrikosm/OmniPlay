#!/bin/zsh
# Static UnRAR with a callback-only C seam, for the app, simulator and host tests.
source "$(dirname "$0")/native/common.sh"
cd "$NATIVE_ROOT"
require_xcode
python3 - <<'PY'
import concurrent.futures, pathlib, re, subprocess
root = pathlib.Path.cwd()
source = root / 'Native/unrar'
shim = root / 'Packages/GameImport/Sources/CUnrar'
make = (source / 'makefile').read_text().replace('\\\n', ' ')
objects = []
for key in ('OBJECTS', 'LIB_OBJ'):
    objects += re.search(r'^' + key + r'=(.+)$', make, re.M)[1].split()
files = [source / (name[:-2] + '.cpp') for name in dict.fromkeys(objects)] + [shim / 'reader.cpp']
libraries = []
for sdk, target in [('iphoneos', 'arm64-apple-ios27.0'), ('iphonesimulator', 'arm64-apple-ios27.0-simulator'), ('macosx', 'arm64-apple-macos15.0')]:
    out = root / 'Native/build/unrar' / sdk
    out.mkdir(parents=True, exist_ok=True)
    sysroot = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    flags = ['xcrun', 'clang++', '-target', target, '-isysroot', sysroot, '-std=c++14', '-O2', '-fPIC',
             '-D_UNIX', '-DRARDLL', '-DSILENT', '-D_FILE_OFFSET_BITS=64', '-I' + str(source), '-I' + str(shim / 'include')]
    def compile(path):
        obj = out / (path.stem + '.o')
        subprocess.run(flags + ['-c', str(path), '-o', str(obj)], check=True)
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        compiled = list(pool.map(compile, files))
    library = out / 'libunrar.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(library)] + list(map(str, compiled)), check=True)
    headers = out / 'headers'
    headers.mkdir(exist_ok=True)
    module = headers / 'CUnrar'
    module.mkdir(exist_ok=True)
    for stale in ('CUnrar.h', 'module.modulemap'):
        (headers / stale).unlink(missing_ok=True)
    (module / 'CUnrar.h').write_bytes((shim / 'include/CUnrar.h').read_bytes())
    (module / 'module.modulemap').write_text('module CUnrar { header "CUnrar.h" export * }\n')
    libraries += ['-library', str(library), '-headers', str(headers)]
    print('Built UnRAR:', sdk, flush=True)
output = root / 'Packages/GameImport/Native/unrar.xcframework'
import shutil
if output.exists(): shutil.rmtree(output)
subprocess.run(['xcodebuild', '-create-xcframework'] + libraries + ['-output', str(output)], check=True)
PY
Scripts/native/manifest.sh unrar Packages/GameImport/Native/unrar.xcframework Native/unrar
