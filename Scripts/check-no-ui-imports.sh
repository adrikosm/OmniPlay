#!/bin/zsh
# Core/UI boundary: no package imports SwiftUI; input and runtime host packages may import UIKit.
cd "$(dirname "$0")/.."
bad=$( { grep -rnE '^\s*(@_exported\s+)?import\s+SwiftUI\b' Packages/*/Sources 2>/dev/null
         grep -rnE '^\s*(@_exported\s+)?import\s+UIKit\b' Packages/*/Sources 2>/dev/null | grep -vE '^Packages/(InputKit|RuntimeCore|RGSSRuntime|RenPyRuntime|EasyRPGRuntime|ScummVMRuntime|GodotRuntime)/'; } )
[[ -z "$bad" ]] && exit 0
echo "$bad" | while IFS=: read -r file line rest; do echo "$file:$line: error: UI framework import is not allowed in packages"; done
exit 1
