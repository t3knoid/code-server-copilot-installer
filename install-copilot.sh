#!/usr/bin/env bash

set -uo pipefail

EXTENSION_ID="GitHub.copilot-chat"
PUBLISHER="GitHub"
EXTENSION_NAME="copilot-chat"

GALLERY_API="https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/code-server-copilot"
TEMP_DIR="${TMPDIR:-/tmp}/code-server-copilot"

cleanup() {
rm -rf "$TEMP_DIR"
}

info() {
printf ' %s\n' "$*" >&2
}

success() {
printf ' ✓ %s\n' "$*" >&2
}

die() {
printf ' ✗ %s\n' "$*" >&2
exit 1
}

check_dependencies() {
local cmd
local missing=()

for cmd in curl jq code-server unzip sort grep head tail tr gzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    die "Missing dependencies: ${missing[*]}"
fi


}

get_vscode_version() {
code-server --version 2>/dev/null |
head -n 1 |
grep -oE 'with Code [0-9]+\.[0-9]+\.[0-9]+' |
grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

version_gte() {
local a="$1"
local b="$2"

[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" = "$b" ]


}

gallery_query() {
curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 30 -X POST "$GALLERY_API" -H "Content-Type: application/json" -H "Accept: application/json;api-version=3.0-preview.1" --data-binary @- <<EOF
{
"filters": [
{
"criteria": [
{
"filterType": 7,
"value": "$EXTENSION_ID"
}
],
"pageNumber": 1,
"pageSize": 1000
}
],
"flags": 2151
}
EOF
}

get_manifest_url() {
printf '%s' "$1" |
jq -r '
.files[]? |
select(
.assetType ==
"Microsoft.VisualStudio.Code.Manifest"
) |
.source
' |
head -n 1
}

get_engine() {
local url="$1"

curl -fsSL \
    --connect-timeout 3 \
    --max-time 5 \
    "$url" 2>/dev/null |
    jq -r '.engines.vscode // empty' 2>/dev/null


}

engine_is_compatible() {
local engine="$1"
local vscode="$2"
local minimum

minimum="$(
    printf '%s' "$engine" |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1
)"

[ -n "$minimum" ] || return 1

version_gte "$vscode" "$minimum"


}

cache_file() {
local vscode_version="$1"

printf '%s/%s.version\n' "$CACHE_DIR" "$vscode_version"


}

read_cached_version() {
local vscode_version="$1"
local file

file="$(cache_file "$vscode_version")"

if [ -f "$file" ]; then
    tr -d '[:space:]' < "$file"
fi


}

write_cached_version() {
local vscode_version="$1"
local version="$2"
local file

mkdir -p "$CACHE_DIR" || return 1

file="$(cache_file "$vscode_version")"

printf '%s\n' "$version" > "$file"


}

remove_cached_version() {
local vscode_version="$1"
local file

file="$(cache_file "$vscode_version")"
rm -f "$file"


}

find_compatible_version() {
local vscode_version="$1"
local response
local count
local i
local version_json
local version
local manifest_url
local engine

info "Querying Microsoft Marketplace..."

response="$(gallery_query)" || return 1

count="$(
    printf '%s' "$response" |
        jq '.results[0].extensions[0].versions | length'
)"

if [ "$count" -le 0 ]; then
    info "Marketplace returned no versions."
    return 1
fi

info "Marketplace returned $count versions."
info "Searching newest to oldest..."

for ((i = 0; i < count; i++)); do

    version_json="$(
        printf '%s' "$response" |
            jq -c --argjson index "$i" \
            '.results[0].extensions[0].versions[$index]'
    )"

    version="$(
        printf '%s' "$version_json" |
            jq -r '.version'
    )"

    manifest_url="$(get_manifest_url "$version_json")"

    if [ -z "$manifest_url" ] || [ "$manifest_url" = "null" ]; then
        continue
    fi

    engine="$(get_engine "$manifest_url")"

    if [ -z "$engine" ]; then
        continue
    fi

    if engine_is_compatible "$engine" "$vscode_version"; then
        success "Compatible version: $version ($engine)"
        printf '%s\n' "$version"
        return 0
    fi

    if (( (i + 1) % 25 == 0 )); then
        info "Checked $((i + 1)) versions..."
    fi
done

return 1


}

get_compatible_version() {
local vscode_version="$1"
local cached

cached="$(read_cached_version "$vscode_version")"

if [ -n "$cached" ]; then
    info "Using cached compatible version: $cached"
    printf '%s\n' "$cached"
    return 0
fi

find_compatible_version "$vscode_version"


}

download_vsix() {
local version="$1"
local output="$2"
local compressed="${output}.gz"
local url

url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${PUBLISHER}/vsextensions/${EXTENSION_NAME}/${version}/vspackage"

info "Downloading $EXTENSION_ID $version..."

if ! curl -fL --retry 3 --retry-delay 1 \
    --connect-timeout 10 --max-time 300 \
    "$url" -o "$compressed"; then
    rm -f "$compressed"
    return 1
fi

info "Decompressing VSIX..."

if ! gzip -df "$compressed"; then
    rm -f "$compressed"
    return 1
fi

[ -f "$output" ]


}

validate_vsix() {
local vsix="$1"

unzip -t "$vsix" >/dev/null 2>&1


}

install_extension() {
local vsix="$1"

code-server --force --install-extension "$vsix"


}

main() {
local vscode_version
local extension_version
local vsix_path

trap cleanup EXIT

echo
echo "GitHub Copilot Chat installer for code-server"
echo "=============================================="
echo

check_dependencies

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR" || die "Unable to create temporary directory."

vscode_version="$(get_vscode_version)"

[ -n "$vscode_version" ] ||
    die "Could not determine VS Code version."

echo "Detected:"
echo "  code-server: $(code-server --version | head -n 1)"
echo "  VS Code:     $vscode_version"
echo "  Extension:   $EXTENSION_ID"
echo

extension_version="$(
    get_compatible_version "$vscode_version"
)"

if [ -z "$extension_version" ]; then
    die "No compatible Copilot Chat version was found."
fi

echo
success "Selected version: $extension_version"

vsix_path="$TEMP_DIR/${EXTENSION_NAME}-${extension_version}.vsix"

if ! download_vsix "$extension_version" "$vsix_path"; then
    info "Cached version may no longer be available."

    remove_cached_version "$vscode_version"

    info "Searching Marketplace again..."

    extension_version="$(
        find_compatible_version "$vscode_version"
    )"

    if [ -z "$extension_version" ]; then
        die "Unable to find a downloadable compatible version."
    fi

    write_cached_version \
        "$vscode_version" \
        "$extension_version"

    rm -f "$vsix_path"

    vsix_path="$TEMP_DIR/${EXTENSION_NAME}-${extension_version}.vsix"

    download_vsix "$extension_version" "$vsix_path" ||
        die "Failed to download Copilot Chat."
fi

success "Download complete."

info "Validating VSIX..."

validate_vsix "$vsix_path" ||
    die "VSIX validation failed."

success "VSIX validation passed."

info "Installing extension..."

install_extension "$vsix_path" ||
    die "code-server failed to install the extension."

echo
success "GitHub Copilot Chat installed successfully."
echo
echo "Restart code-server and sign in to GitHub."
echo


}

main "$@"
