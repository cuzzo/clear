#!/usr/bin/env bash
# Devcontainer post-create hook. Runs once when the container is built.
#
# Steps (idempotent — safe to re-run):
#   1. Install Ruby gems for the compiler.
#   2. Install Zig (matches the version pinned in CI).
#   3. Build the in-repo VS Code extension.

set -euo pipefail

ZIG_VERSION="0.16.0"
ZIG_INSTALL_DIR="/usr/local/share/zig"

echo "[devcontainer] $(date '+%H:%M:%S')  step 1/3 — bundle install"
bundle install

echo "[devcontainer] $(date '+%H:%M:%S')  step 2/3 — installing Zig ${ZIG_VERSION}"
if command -v zig >/dev/null 2>&1; then
    echo "  zig already on PATH ($(zig version)) — skipping"
else
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  zig_arch="x86_64-linux" ;;
        aarch64) zig_arch="aarch64-linux" ;;
        *) echo "  unsupported arch: $arch — install zig manually"; exit 0 ;;
    esac
    tarball="zig-${zig_arch}-${ZIG_VERSION}.tar.xz"
    url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"

    echo "  downloading ${url}"
    curl -fsSL "$url" -o "/tmp/${tarball}"

    sudo mkdir -p "$ZIG_INSTALL_DIR"
    sudo tar -xJf "/tmp/${tarball}" -C "$ZIG_INSTALL_DIR" --strip-components=1
    sudo ln -sf "$ZIG_INSTALL_DIR/zig" /usr/local/bin/zig
    rm -f "/tmp/${tarball}"
    echo "  zig $(zig version) installed at $ZIG_INSTALL_DIR"
fi

echo "[devcontainer] $(date '+%H:%M:%S')  step 3/4 — building VS Code extension"
pushd .vscode/extensions/cheat-lang >/dev/null
npm install --silent
npm run compile
popd >/dev/null

echo "[devcontainer] $(date '+%H:%M:%S')  step 4/4 — installing extension into VS Code Server"
# VS Code (and Codespaces) does NOT auto-load extensions from
# `.vscode/extensions/<name>/` — that's a Cursor-specific convention.
# To get the extension loaded in vanilla VS Code Server, symlink the
# built directory into `~/.vscode-server/extensions/` using the
# `<publisher>.<name>-<version>` naming convention VS Code expects.
EXT_SRC="$PWD/.vscode/extensions/cheat-lang"
EXT_NAME="clear.clear-lang-0.2.0"

# Codespaces uses ~/.vscode-server/extensions; some Dev Containers
# use ~/.vscode-remote/extensions. Symlink to whichever exists, and
# create both as a belt-and-suspenders.
for VSCODE_HOME in "$HOME/.vscode-server" "$HOME/.vscode-remote"; do
    mkdir -p "$VSCODE_HOME/extensions"
    ln -sfn "$EXT_SRC" "$VSCODE_HOME/extensions/$EXT_NAME"
    echo "  installed at $VSCODE_HOME/extensions/$EXT_NAME"
done

echo "[devcontainer] $(date '+%H:%M:%S')  setup complete"
echo ""
echo "  Try it:"
echo "    1. Open any .cht file (try transpile-tests/01_smoke.cht)"
echo "    2. Squiggles, hover (mouse-over), and Ctrl+. (quick fix) all work."
echo ""
echo "  Run the test suite:"
echo "    bundle exec prspec spec/        # 4180+ Ruby specs"
echo "    ./clear test transpile-tests/   # 514 transpile tests"
