#!/bin/sh
set -eu

# Regenerates the historical persistence fixtures and manifest in
# Tests/QuizEngineCoreTests/Resources/PersistenceFixtures.
#
#   sh Scripts/generate-persistence-fixtures.sh              # every tag, rebuilds manifest.json
#   sh Scripts/generate-persistence-fixtures.sh v0.1.2       # one tag, leaves manifest.json alone
#
# For each tag the script:
#
#   1. creates a detached `git worktree` for that exact tag in a temporary directory
#      (the working branch is never checked out to a tag);
#   2. copies the matching generator from Scripts/PersistenceFixtureGenerators into
#      that worktree as Sources/PersistenceFixtureGenerator/main.swift and appends an
#      executable target to the worktree's Package.swift;
#   3. builds and runs the generator with `CFFIXED_USER_HOME` pointed at a throwaway
#      directory, so the Documents directory the tag resolves internally is isolated,
#      and with `SWIFT_DETERMINISTIC_HASHING=1`, so `Set`/`Dictionary` ordering — and
#      therefore the encoded bytes — are reproducible;
#   4. copies the emitted documents into the fixture resource directory and records
#      what the tag's own decoder reads back out of them.
#
# Every fixture byte is produced by the tag's own model, encoder, and save path.
# Nothing is synthesized with current models or hand-written property lists. If a
# fixture needs correcting, change the generator and rerun this script; never edit a
# generated plist, because that invalidates its recorded provenance and hash.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

ALL_TAGS="v0.1.0 v0.1.1 v0.1.2 v0.1.3 v0.2.0"
if [ "$#" -gt 0 ]; then
    TAGS="$*"
    REBUILD_MANIFEST=0
else
    TAGS="$ALL_TAGS"
    REBUILD_MANIFEST=1
fi

FIXTURE_ROOT="$root/Tests/QuizEngineCoreTests/Resources/PersistenceFixtures"
OBSERVED_ROOT="$root/.build/persistence-fixtures/observed"
SWIFT_TARGET=arm64-apple-macosx14.0

generator_for_tag() {
    case "$1" in
        v0.1.0 | v0.1.1 | v0.1.2 | v0.1.3) echo "legacy-v0_1_x.swift" ;;
        v0.2.0) echo "schema1-v0_2_0.swift" ;;
        *)
            echo "no generator is defined for tag $1" >&2
            exit 2
            ;;
    esac
}

command -v shasum >/dev/null 2>&1 || {
    echo "shasum is required to record fixture hashes" >&2
    exit 2
}

mkdir -p "$OBSERVED_ROOT"

for tag in $TAGS; do
    generator=$(generator_for_tag "$tag")
    commit=$(git rev-parse "${tag}^{commit}")

    work=$(mktemp -d "${TMPDIR:-/tmp}/quizengine-fixtures.XXXXXX")
    src="$work/src"
    isolated_home="$work/home"
    out="$work/out"
    mkdir -p "$isolated_home/Documents" "$out"

    echo "==> $tag ($commit)"
    git worktree add --detach "$src" "$tag" >/dev/null

    mkdir -p "$src/Sources/PersistenceFixtureGenerator"
    cp "$root/Scripts/PersistenceFixtureGenerators/$generator" \
        "$src/Sources/PersistenceFixtureGenerator/main.swift"

    # `Package` is a class in PackageDescription, so the tag's own manifest can be
    # extended in place without rewriting it. This only adds a build product; it does
    # not change any source the fixture is produced from.
    cat >>"$src/Package.swift" <<'MANIFEST'

// Appended by Scripts/generate-persistence-fixtures.sh in a throwaway worktree.
package.targets.append(
    .executableTarget(
        name: "PersistenceFixtureGenerator",
        dependencies: ["QuizEngineCore"],
        path: "Sources/PersistenceFixtureGenerator"
    )
)
MANIFEST

    (
        cd "$src"
        CFFIXED_USER_HOME="$isolated_home" \
        SWIFT_DETERMINISTIC_HASHING=1 \
            swift run \
                -Xswiftc -target -Xswiftc "$SWIFT_TARGET" \
                PersistenceFixtureGenerator "$out" >/dev/null
    )

    mkdir -p "$FIXTURE_ROOT/$tag"
    for file in "$out"/*.plist; do
        name=$(basename "$file")
        cp "$file" "$FIXTURE_ROOT/$tag/$name"
        printf '    %s/%s  %s\n' "$tag" "$name" \
            "$(shasum -a 256 "$FIXTURE_ROOT/$tag/$name" | cut -d ' ' -f 1)"
    done
    cp "$out/observed-values.json" "$OBSERVED_ROOT/$tag.json"

    git worktree remove --force "$src" >/dev/null 2>&1 || true
    rm -rf "$work"
done

if [ "$REBUILD_MANIFEST" -eq 1 ]; then
    echo "==> manifest.json"
    swift "$root/Scripts/PersistenceFixtureGenerators/build-manifest.swift" \
        "$FIXTURE_ROOT" "$OBSERVED_ROOT"
else
    echo "==> manifest.json not rebuilt (a tag subset was requested)."
    echo "    Rerun without arguments to regenerate every fixture and the manifest."
fi

echo "==> Fixtures written to $FIXTURE_ROOT"
