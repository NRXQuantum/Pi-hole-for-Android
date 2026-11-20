#!/usr/bin/env bash
#
# Rebuild pideploy.apk from the pinned upstream 3.2.0 APK, apply the
# Pi-hole-for-Android defaults, and sign it with the project release key.
#
# The signature is produced from ANDROID_KEYSTORE / ANDROID_KEYSTORE_PASSWORD /
# ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD.  Using the same keystore for every
# build is what allows Android to install updates over an existing app; a
# freshly generated key produces "App not installed" instead.
#
# Required environment:
#   VERSION_CODE               integer, e.g. 316
#   VERSION_NAME               e.g. 3.2.2
#   ANDROID_KEYSTORE           path to the .keystore / .jks file
#   ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_ALIAS
#   ANDROID_KEY_PASSWORD
#
# Optional environment:
#   SOURCE_PATH                default image URL baked into the APK
#   ANDROID_BUILD_TOOLS        directory containing zipalign/apksigner/aapt2
#   BASE_APK                   use a local base APK instead of downloading
#   APKTOOL_JAR                use a local apktool jar instead of downloading
#   OUT_DIR                    output directory (default: dist)
#   EXPECTED_SIGNER_SHA256     fail if the signing certificate differs
#
# Pinned inputs (override only for local testing):
#   BASE_APK_URL / BASE_APK_SHA256, APKTOOL_VERSION / APKTOOL_SHA256

set -euo pipefail

: "${VERSION_CODE:?VERSION_CODE is required}"
: "${VERSION_NAME:?VERSION_NAME is required}"
: "${ANDROID_KEYSTORE:?ANDROID_KEYSTORE is required}"
: "${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD is required}"
: "${ANDROID_KEY_ALIAS:?ANDROID_KEY_ALIAS is required}"
: "${ANDROID_KEY_PASSWORD:?ANDROID_KEY_PASSWORD is required}"

[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || { echo "VERSION_CODE must be an integer" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
SOURCE_PATH="${SOURCE_PATH:-https://github.com/NRXQuantum/Pi-hole-for-Android/releases/latest/download/raspbian32.tgz}"

BASE_APK_URL="${BASE_APK_URL:-https://github.com/DesktopECHO/Pi-hole-for-Android/releases/download/v.3.2.0/pideploy.apk}"
BASE_APK_SHA256="${BASE_APK_SHA256:-1220318d3dc2dfdaafb117b94a3610bdd3676b64144287c916f54fab09d59de4}"
APKTOOL_VERSION="${APKTOOL_VERSION:-2.9.3}"
APKTOOL_SHA256="${APKTOOL_SHA256:-7956eb04194300ce0d0a84ad18771eebc94b89fb8d1ddcce8ea4c056818646f4}"

# Certificate of the v3.2.1 release key.  If this does not match, users get
# "App not installed" when updating, so treat it as a hard failure.
EXPECTED_SIGNER_SHA256="${EXPECTED_SIGNER_SHA256:-8e4a48e0122714043968bba9552eba599d1d787e49f21beb6b335e99262fb8eb}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url dest
    echo "==> downloading $1"
    curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

check_hash() { # file expected label
    local actual
    actual="$(sha256_of "$1")"
    if [ "$actual" != "$2" ]; then
        echo "ERROR: $3 checksum mismatch" >&2
        echo "  expected: $2" >&2
        echo "  actual:   $actual" >&2
        exit 3
    fi
    echo "==> $3 checksum OK ($actual)"
}

tool() { # name -> path from ANDROID_BUILD_TOOLS or PATH
    if [ -n "${ANDROID_BUILD_TOOLS:-}" ] && [ -x "$ANDROID_BUILD_TOOLS/$1" ]; then
        echo "$ANDROID_BUILD_TOOLS/$1"
    elif command -v "$1" >/dev/null 2>&1; then
        command -v "$1"
    else
        echo "ERROR: $1 not found (set ANDROID_BUILD_TOOLS)" >&2
        exit 4
    fi
}

# --- inputs -------------------------------------------------------------
BASE_APK="${BASE_APK:-$WORK/base.apk}"
if [ ! -f "$BASE_APK" ]; then
    fetch "$BASE_APK_URL" "$BASE_APK"
fi
check_hash "$BASE_APK" "$BASE_APK_SHA256" "base APK"

APKTOOL_JAR="${APKTOOL_JAR:-$WORK/apktool_${APKTOOL_VERSION}.jar}"
if [ ! -f "$APKTOOL_JAR" ]; then
    fetch "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" "$APKTOOL_JAR"
fi
check_hash "$APKTOOL_JAR" "$APKTOOL_SHA256" "apktool ${APKTOOL_VERSION}"

ZIPALIGN="$(tool zipalign)"
APKSIGNER="$(tool apksigner)"
AAPT2="$(tool aapt2)"

# --- decode -------------------------------------------------------------
echo "==> decoding base APK"
java -jar "$APKTOOL_JAR" d -f -o "$WORK/decoded" "$BASE_APK" >/dev/null

# --- apply Pi-hole-for-Android defaults ---------------------------------
echo "==> patching resources"
python3 - "$WORK/decoded" "$SOURCE_PATH" <<'PY'
import pathlib
import re
import sys

base = pathlib.Path(sys.argv[1])
source_path = sys.argv[2]

strings = base / "res/values/strings.xml"
text = strings.read_text(encoding="utf-8")


def set_string(name: str, value: str) -> None:
    global text
    pattern = re.compile(
        r'(<string name="%s">)(.*?)(</string>)' % re.escape(name), re.S
    )
    text, count = pattern.subn(lambda m: m.group(1) + value + m.group(3), text)
    if count != 1:
        raise SystemExit(f"expected exactly one string/{name}, found {count}")


set_string("is_telnet", "true")
set_string("is_http", "true")
set_string("source_path", source_path)
strings.write_text(text, encoding="utf-8")
PY

# --- patch the environment bootstrap ------------------------------------
# The upstream app trusts files/version and skips extraction when it matches,
# and it only initializes at all after WRITE_EXTERNAL_STORAGE is granted.  A
# restored, cleaned or partially restored data directory can therefore keep
# the marker while files/bin/pideploy (or its interpreter) is missing, which
# aborts every deployment with ".../files/bin/pideploy: not found".
echo "==> patching environment bootstrap"
python3 - "$WORK/decoded" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import pathlib
import re
import sys

base = pathlib.Path(sys.argv[1])
app_version = f"{sys.argv[2]}-{sys.argv[3]}"
smali = base / "smali_classes2/com/desktopecho/pideploy"


def patch(path: pathlib.Path, pattern: str, replacement: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    new, count = re.subn(pattern, replacement, text, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(new, encoding="utf-8")


# Keep the stored version marker in sync with the release so an update always
# refreshes the extracted environment once.
patch(
    smali / "PrefStore.smali",
    r'(\.method public static getVersion\(\)Ljava/lang/String;.*?'
    r'const-string v0, ")[^"]*(")',
    r"\g<1>" + app_version + r"\g<2>",
    "PrefStore.getVersion",
)

helpers = """
.method private static checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z
    .locals 1
    .param p0, "dir"    # Ljava/lang/String;
    .param p1, "name"    # Ljava/lang/String;
    .param p2, "executable"    # Z

    new-instance v0, Ljava/io/File;

    invoke-direct {v0, p0, p1}, Ljava/io/File;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    invoke-virtual {v0}, Ljava/io/File;->exists()Z

    move-result v0

    if-eqz v0, :cond_0

    if-eqz p2, :cond_0

    new-instance v0, Ljava/io/File;

    invoke-direct {v0, p0, p1}, Ljava/io/File;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    invoke-virtual {v0}, Ljava/io/File;->canExecute()Z

    move-result v0

    return v0

    :cond_0
    return v0
.end method

.method private static envIntact(Landroid/content/Context;)Z
    .locals 4
    .param p0, "c"    # Landroid/content/Context;

    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getBinDir(Landroid/content/Context;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "pideploy"

    const/4 v2, 0x1

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-nez v3, :cond_0

    const/4 v3, 0x0

    return v3

    :cond_0
    const-string v1, "busybox"

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-nez v3, :cond_1

    const/4 v3, 0x0

    return v3

    :cond_1
    const-string v1, "sh"

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-nez v3, :cond_2

    const/4 v3, 0x0

    return v3

    :cond_2
    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getEnvDir(Landroid/content/Context;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "cli.sh"

    const/4 v2, 0x0

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    return v3
.end method

"""

patch(
    smali / "EnvUtils.smali",
    r"(\n\.method public static isLatestVersion\(Landroid/content/Context;\)Z\n)",
    "\n" + helpers.lstrip("\n") + r"\g<1>",
    "EnvUtils helpers",
)

# A matching version marker is not enough: require the extracted binaries,
# their interpreter and the CLI library to be present and executable.
patch(
    smali / "EnvUtils.smali",
    r"(    if-nez v1, :cond_0\n\n    return v2\n\n)(    \.line 171\n    :cond_0\n)",
    r"\g<1>"
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->envIntact(Landroid/content/Context;)Z\n\n"
    "    move-result v1\n\n"
    "    if-eqz v1, :cond_0\n\n"
    "    return v2\n\n"
    r"\g<2>",
    "EnvUtils.isLatestVersion",
)

# Rebuild the environment if a command is about to run without it.
patch(
    smali / "EnvUtils.smali",
    r"(\.method public static cli\(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;\)Z\n"
    r"    \.locals 5\n"
    r'    \.param p0, "c"    # Landroid/content/Context;\n'
    r'    \.param p1, "cmd"    # Ljava/lang/String;\n'
    r'    \.param p2, "args"    # Ljava/lang/String;\n\n)',
    r"\g<1>"
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->envIntact(Landroid/content/Context;)Z\n\n"
    "    move-result v3\n\n"
    "    if-nez v3, :env_ready\n\n"
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->updateEnv(Landroid/content/Context;)Z\n\n"
    "    :env_ready\n\n",
    "EnvUtils.cli",
)

# Initialize even when the storage permission is denied: extraction only uses
# internal storage, so refusing WRITE_EXTERNAL_STORAGE must not leave the app
# without files/bin/pideploy.
patch(
    smali / "activity/MainActivity.smali",
    r"(    invoke-virtual \{v0\}, Landroid/widget/Toast;->show\(\)V\n\n)"
    r"(    \.line 472\n)",
    r"\g<1>"
    "    .line 470\n"
    "    new-instance v1, Lcom/desktopecho/pideploy/UpdateEnvTask;\n\n"
    "    invoke-direct {v1, p0}, Lcom/desktopecho/pideploy/UpdateEnvTask;-><init>(Landroid/content/Context;)V\n\n"
    "    const/4 v0, 0x0\n\n"
    "    new-array v0, v0, [Ljava/lang/String;\n\n"
    "    invoke-virtual {v1, v0}, Lcom/desktopecho/pideploy/UpdateEnvTask;->execute([Ljava/lang/Object;)Landroid/os/AsyncTask;\n\n"
    r"\g<2>",
    "MainActivity.onRequestPermissionsResult",
)
PY

# Version bump (apktool.yml feeds the manifest at build time).
sed -i -E "s/^  versionCode: .*/  versionCode: ${VERSION_CODE}/" "$WORK/decoded/apktool.yml"
sed -i -E "s/^  versionName: .*/  versionName: ${VERSION_NAME}/" "$WORK/decoded/apktool.yml"
grep -q "^  versionCode: ${VERSION_CODE}$" "$WORK/decoded/apktool.yml"
grep -q "^  versionName: ${VERSION_NAME}$" "$WORK/decoded/apktool.yml"
grep -q '<string name="is_telnet">true</string>' "$WORK/decoded/res/values/strings.xml"
grep -q '<string name="is_http">true</string>' "$WORK/decoded/res/values/strings.xml"
grep -q "const-string v0, \"${VERSION_NAME}-${VERSION_CODE}\"" "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/PrefStore.smali"
grep -q 'envIntact' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
grep -q ':env_ready' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
grep -q 'new-array v0, v0, \[Ljava/lang/String;' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/activity/MainActivity.smali"

# --- build --------------------------------------------------------------
echo "==> building unsigned APK"
java -jar "$APKTOOL_JAR" b -f "$WORK/decoded" -o "$WORK/unsigned.apk" >/dev/null

echo "==> aligning"
"$ZIPALIGN" -p -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"

echo "==> signing with $ANDROID_KEY_ALIAS"
mkdir -p "$OUT_DIR"
"$APKSIGNER" sign \
    --ks "$ANDROID_KEYSTORE" \
    --ks-key-alias "$ANDROID_KEY_ALIAS" \
    --ks-pass "env:ANDROID_KEYSTORE_PASSWORD" \
    --key-pass "env:ANDROID_KEY_PASSWORD" \
    --min-sdk-version 21 \
    --out "$OUT_DIR/pideploy.apk" \
    "$WORK/aligned.apk"

# --- verify -------------------------------------------------------------
echo "==> verifying signature"
"$APKSIGNER" verify --verbose --print-certs "$OUT_DIR/pideploy.apk" > "$WORK/verify.txt" 2>&1 || {
    cat "$WORK/verify.txt" >&2
    exit 5
}
cat "$WORK/verify.txt"

cert="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$WORK/verify.txt" | head -n1 | tr -d ':' | tr 'A-F' 'a-f')"
if [ -z "$cert" ]; then
    echo "ERROR: could not read signer certificate" >&2
    exit 5
fi
if [ "${EXPECTED_SIGNER_SHA256,,}" != "$cert" ]; then
    echo "ERROR: APK was signed with the wrong key" >&2
    echo "  expected: ${EXPECTED_SIGNER_SHA256,,}" >&2
    echo "  got:      $cert" >&2
    echo "Check ANDROID_KEYSTORE_BASE64 / password / alias secrets." >&2
    exit 5
fi
echo "==> signer certificate matches the release key"

echo "==> verifying version and defaults"
"$AAPT2" dump badging "$OUT_DIR/pideploy.apk" | tee "$WORK/badging.txt" | grep -E '^package:' || true
grep -q "versionCode='${VERSION_CODE}'" "$WORK/badging.txt"
grep -q "versionName='${VERSION_NAME}'" "$WORK/badging.txt"
"$AAPT2" dump resources "$OUT_DIR/pideploy.apk" > "$WORK/resources.txt" 2>/dev/null
grep -A1 'string/is_telnet ' "$WORK/resources.txt" | grep -q '"true"'
grep -A1 'string/is_http ' "$WORK/resources.txt" | grep -q '"true"'
grep -A1 'string/source_path ' "$WORK/resources.txt" | grep -q "\"${SOURCE_PATH}\""
echo "==> APK defaults verified"

{
    echo "versionCode=$VERSION_CODE"
    echo "versionName=$VERSION_NAME"
    echo "sourcePath=$SOURCE_PATH"
    echo "signerSha256=$cert"
} > "$OUT_DIR/build-info.txt"

( cd "$OUT_DIR" && sha256sum pideploy.apk > pideploy.apk.sha256 )

echo "==> done: $OUT_DIR/pideploy.apk"
