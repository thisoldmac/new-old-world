#!/usr/bin/env bash
# Lane H2: watch every new assertion fail under a deliberate mutation.
#
# A test is trusted only after it has been seen to fail (AGENTS.md). Each
# mutation below puts a specific bug back and names which tests must go red;
# the tree is restored from git after each one, so no mutation can ride along
# into a commit.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
KIT=host/MirrorKit

run () { (cd "$KIT" && swift test 2>&1 | grep -E "^Test Case .* failed" \
            | sed 's/.*MirrorKitTests\.//; s/\].*//'); }

mutate () {                      # $1 = label, $2 = file, $3 = perl -0pi expr
    echo "=== $1"
    perl -0pi -e "$3" "$2"
    if git diff --quiet "$2"; then
        echo "  !! MUTATION DID NOT APPLY — the expression matched nothing"
    else
        run | sed 's/^/  red: /'
    fi
    git checkout -- "$2"
}

S=$KIT/Sources/MirrorKit

mutate "clickPoint aims at the icon's top-left, not its centre" \
    "$S/FinderItems.swift" \
    's/let cx = item\.x \+ iconSize \/ 2/let cx = item.x/'

mutate "iconArea ignores the window's scrollbars (no info-bar inset)" \
    "$S/FinderItems.swift" \
    's/for ctl in win\.controls where ctl\.visible \{/for ctl in win.controls where false {/'

mutate "layoutKey forgets the scroll values" \
    "$S/FinderItems.swift" \
    's/\.map \{ "\\\(\$0\.value \?\? 0\)" \}/.map { _ in "0" }/'

mutate "merge keeps the catalog's saved fdLocation instead of the live one" \
    "$S/FinderItems.swift" \
    's/            item\.x = p\.x\n            item\.y = p\.y\n//'

mutate "parse fills in a missing coordinate instead of dropping the record" \
    "$S/FinderItems.swift" \
    's/guard coords\.count == 2,\n                      let x = Int\(coords\[0\]\.trimmingCharacters\(in: \.whitespaces\)\),\n                      let y = Int\(coords\[1\]\.trimmingCharacters\(in: \.whitespaces\)\)\n                else \{ continue \}/guard let x = Int(coords[0].trimmingCharacters(in: .whitespaces))\n                else { continue }\n                let y = coords.count > 1\n                    ? (Int(coords[1].trimmingCharacters(in: .whitespaces)) ?? 0) : 0/'

mutate "hit-test resolves icons BEFORE controls" \
    "$S/HitTester.swift" \
    's/            for ctl in win\.controls where ctl\.visible \{/            for ctl in win.controls where false {/'

mutate "the poller no longer marks items additive in the IR" \
    "$S/IRSchema.swift" \
    's/        "windows\[\]\.items",\n//'

mutate "window items go back to being excluded from the wire" \
    "$S/Scene.swift" \
    's/            case items          \/\/ additive in v1 — see the declaration\n//'
