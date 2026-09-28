#!/bin/zsh
# Static libmspack (cabinet decoding only) with a callback-only C seam, for the app, simulator and host tests.
# libarchive's LZX decoder fails on large real installers (an 812 MB Game.rgss3a); libmspack reads them.
source "$(dirname "$0")/native/common.sh"
cd "$NATIVE_ROOT"
require_xcode
python3 - <<'PY'
import concurrent.futures, pathlib, shutil, subprocess
root = pathlib.Path.cwd()
source = root / 'Native/libmspack/libmspack/mspack'
shim = root / 'Packages/GameImport/Sources/CMspack'
files = [source / name for name in ('cabd.c', 'lzxd.c', 'mszipd.c', 'qtmd.c', 'system.c')] + [shim / 'reader.c']
libraries = []
for sdk, target in [('iphoneos', 'arm64-apple-ios27.0'), ('iphonesimulator', 'arm64-apple-ios27.0-simulator'), ('macosx', 'arm64-apple-macos15.0')]:
    out = root / 'Native/build/libmspack' / sdk
    out.mkdir(parents=True, exist_ok=True)
    sysroot = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    flags = ['xcrun', 'clang', '-target', target, '-isysroot', sysroot, '-std=c99', '-O2', '-fPIC', '-w',
             '-DHAVE_STRING_H', '-DHAVE_LIMITS_H', '-DHAVE_INTTYPES_H', '-DLARGEFILE_SUPPORT', '-D_FILE_OFFSET_BITS=64',
             '-I' + str(source), '-I' + str(shim / 'include')]
    def compile(path):
        obj = out / (path.stem + '.o')
        subprocess.run(flags + ['-c', str(path), '-o', str(obj)], check=True)
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        compiled = list(pool.map(compile, files))
    library = out / 'libmspack.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(library)] + list(map(str, compiled)), check=True)
    headers = out / 'headers'
    module = headers / 'CMspack'
    module.mkdir(parents=True, exist_ok=True)
    (module / 'CMspack.h').write_bytes((shim / 'include/CMspack.h').read_bytes())
    (module / 'module.modulemap').write_text('module CMspack { header "CMspack.h" export * }\n')
    libraries += ['-library', str(library), '-headers', str(headers)]
    print('Built libmspack:', sdk, flush=True)
output = root / 'Packages/GameImport/Native/libmspack.xcframework'
if output.exists(): shutil.rmtree(output)
subprocess.run(['xcodebuild', '-create-xcframework'] + libraries + ['-output', str(output)], check=True)
PY
Scripts/native/manifest.sh libmspack Packages/GameImport/Native/libmspack.xcframework Native/libmspack
