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

# --- pack architecture-specific busybox fallbacks -----------------------
# makeMainScript() below writes a launcher that selects a working busybox at
# runtime.  Keeping both Android ABIs inside bin/all lets one extracted
# environment repair itself when the primary busybox cannot execute.
if [ -f "$WORK/decoded/assets/bin/arm/busybox" ]; then
    cp "$WORK/decoded/assets/bin/arm/busybox" "$WORK/decoded/assets/bin/all/busybox_arm"
fi
if [ -f "$WORK/decoded/assets/bin/arm_64/busybox" ]; then
    cp "$WORK/decoded/assets/bin/arm_64/busybox" "$WORK/decoded/assets/bin/all/busybox_arm64"
fi

# --- patch the environment bootstrap ------------------------------------
# Root cause of ".../files/bin/pideploy: not found": the upstream launcher is
# written with the shebang "#!/<binDir>/sh", but <binDir>/sh only appears when
# "busybox --install -s" succeeds.  On devices where busybox cannot execute
# (missing interpreter, wrong ABI, interrupted extraction) that symlink never
# exists, the kernel rejects the script, and the stale version marker makes the
# app believe the environment is complete so it never retries.
#
# The replacement launcher always runs under /system/bin/sh, locates a working
# bundled busybox, repairs <binDir>/sh, and then executes the CLI with it.
echo "==> patching environment bootstrap"
python3 - "$WORK/decoded" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import pathlib
import re
import sys

base = pathlib.Path(sys.argv[1])
app_version = f"{sys.argv[2]}-{sys.argv[3]}"
smali = base / "smali_classes2/com/desktopecho/pideploy"


def substitute(path: pathlib.Path, pattern: str, func, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    new, count = re.subn(pattern, func, text, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(new, encoding="utf-8")


def replace_once(path: pathlib.Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def smali_string(text: str) -> str:
    return (text.replace("\\", "\\\\").replace('"', '\\"')
                .replace("\n", "\\n").replace("\t", "\\t"))


# Keep the stored version marker in sync with the release so an update always
# refreshes the extracted environment once.
substitute(
    smali / "PrefStore.smali",
    r'(\.method public static getVersion\(\)Ljava/lang/String;.*?'
    r'const-string v0, ")[^"]*(")',
    lambda m: m.group(1) + app_version + m.group(2),
    "PrefStore.getVersion",
)

# Each Android runtime is shipped twice by the launcher: first extracted under
# bin/all (busybox_arm / busybox_arm64), then the matching arch copy overwrites
# the plain "busybox".  If that primary copy cannot execute, the launcher falls
# back to one of these.
launcher = """#!/system/bin/sh
BIN="${0%/*}"
[ "$BIN" = "$0" ] && BIN="."
ENV_DIR="${BIN%/*}"
[ "$ENV_DIR" = "$BIN" ] && ENV_DIR="."
export ENV_DIR
CP=/system/bin/cp
[ -x "$CP" ] || CP=cp
RM=/system/bin/rm
[ -x "$RM" ] || RM=rm
CH=/system/bin/chmod
[ -x "$CH" ] || CH=chmod
BB="$BIN/busybox"
if ! "$BB" true >/dev/null 2>&1; then
    for c in "$BIN/busybox_arm64" "$BIN/busybox_arm"; do
        [ -f "$c" ] || continue
        "$RM" -f "$BB" 2>/dev/null
        "$CP" -f "$c" "$BB" 2>/dev/null || continue
        "$CH" 755 "$BB" 2>/dev/null
        if "$BB" true >/dev/null 2>&1; then
            break
        fi
    done
fi
if ! "$BB" true >/dev/null 2>&1; then
    echo "Pi Deploy: cannot execute a bundled busybox in $BIN" >&2
    exit 127
fi
if [ ! -f "$BIN/sh" ] || ! "$BIN/sh" -c true >/dev/null 2>&1; then
    "$RM" -f "$BIN/sh" 2>/dev/null
    "$CP" -f "$BB" "$BIN/sh" 2>/dev/null
    "$CH" 755 "$BIN/sh" 2>/dev/null
fi
"$BB" --install -s "$BIN" >/dev/null 2>&1
PATH="$BIN:$PATH"
export PATH
exec "$BB" sh -c '. "$ENV_DIR/cli.sh" "$@"' pideploy "$@"
"""

new_main_script = """.method private static makeMainScript(Landroid/content/Context;)Z
    .locals 4
    .param p0, "c"    # Landroid/content/Context;

    new-instance v0, Ljava/lang/StringBuilder;

    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getBinDir(Landroid/content/Context;)Ljava/lang/String;

    move-result-object v1

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v1, "/pideploy"

    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    :try_start_0
    new-instance v1, Ljava/io/FileWriter;

    invoke-direct {v1, v0}, Ljava/io/FileWriter;-><init>(Ljava/lang/String;)V

    const-string v2, "@@LAUNCHER@@"

    invoke-virtual {v1, v2}, Ljava/io/FileWriter;->write(Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/FileWriter;->close()V
    :try_end_0
    .catch Ljava/io/IOException; {:try_start_0 .. :try_end_0} :catch_0

    const/4 v1, 0x1

    return v1

    :catch_0
    move-exception v1

    const/4 v1, 0x0

    return v1
.end method
""".replace("@@LAUNCHER@@", smali_string(launcher))

env_utils = smali / "EnvUtils.smali"
text = env_utils.read_text(encoding="utf-8")
start = text.index(".method private static makeMainScript(Landroid/content/Context;)Z")
end = text.index(".end method", start) + len(".end method")
text = text[:start] + new_main_script.rstrip("\n") + text[end:]
env_utils.write_text(text, encoding="utf-8")

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
    .locals 5
    .param p0, "c"    # Landroid/content/Context;

    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getBinDir(Landroid/content/Context;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "pideploy"

    const/4 v2, 0x0

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-nez v3, :fail

    const-string v1, "busybox"

    const/4 v2, 0x1

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-eqz v3, :have_busybox

    const-string v1, "busybox_arm64"

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-eqz v3, :have_busybox

    const-string v1, "busybox_arm"

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-eqz v3, :have_busybox

    goto :fail

    :have_busybox
    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getEnvDir(Landroid/content/Context;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "cli.sh"

    const/4 v2, 0x0

    invoke-static {v0, v1, v2}, Lcom/desktopecho/pideploy/EnvUtils;->checkFile(Ljava/lang/String;Ljava/lang/String;Z)Z

    move-result v3

    if-nez v3, :fail

    const/4 v3, 0x1

    return v3

    :fail
    const/4 v3, 0x0

    return v3
.end method

"""

replace_once(
    env_utils,
    "\n.method public static isLatestVersion(Landroid/content/Context;)Z\n",
    "\n" + helpers.lstrip("\n") + ".method public static isLatestVersion(Landroid/content/Context;)Z\n",
    "EnvUtils helpers",
)

# A version marker only means extraction finished; it does not prove the
# launcher can run.  Rebuild the environment whenever it is incomplete.
replace_once(
    env_utils,
    '.method public static isLatestVersion(Landroid/content/Context;)Z\n'
    "    .locals 5\n"
    '    .param p0, "c"    # Landroid/content/Context;\n\n',
    '.method public static isLatestVersion(Landroid/content/Context;)Z\n'
    "    .locals 5\n"
    '    .param p0, "c"    # Landroid/content/Context;\n\n'
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->envIntact(Landroid/content/Context;)Z\n\n"
    "    move-result v1\n\n"
    "    if-eqz v1, :env_ok\n\n"
    "    const/4 v1, 0x0\n\n"
    "    return v1\n\n"
    "    :env_ok\n\n",
    "EnvUtils.isLatestVersion",
)

# Rebuild the environment if a command is about to run without it.
replace_once(
    env_utils,
    '.method public static cli(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z\n'
    "    .locals 5\n"
    '    .param p0, "c"    # Landroid/content/Context;\n'
    '    .param p1, "cmd"    # Ljava/lang/String;\n'
    '    .param p2, "args"    # Ljava/lang/String;\n\n',
    '.method public static cli(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z\n'
    "    .locals 5\n"
    '    .param p0, "c"    # Landroid/content/Context;\n'
    '    .param p1, "cmd"    # Ljava/lang/String;\n'
    '    .param p2, "args"    # Ljava/lang/String;\n\n'
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->envIntact(Landroid/content/Context;)Z\n\n"
    "    move-result v3\n\n"
    "    if-nez v3, :env_ready\n\n"
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/EnvUtils;->updateEnv(Landroid/content/Context;)Z\n\n"
    "    :env_ready\n\n",
    "EnvUtils.cli",
)

# Run the launcher through the system shell: this still works when the script
# lost its execute bit or carries a stale shebang from an older release.
replace_once(
    env_utils,
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getBinDir(Landroid/content/Context;)Ljava/lang/String;\n\n"
    "    move-result-object v4\n\n"
    '    invoke-virtual {v2, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n'
    '    const-string v4, "/pideploy "',
    '    const-string v4, "/system/bin/sh "\n\n'
    "    invoke-virtual {v2, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    "    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->getBinDir(Landroid/content/Context;)Ljava/lang/String;\n\n"
    "    move-result-object v4\n\n"
    '    invoke-virtual {v2, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n'
    '    const-string v4, "/pideploy "',
    "EnvUtils.cli command",
)

# A reinstall can reuse an old data directory whose owner is the previous
# install's UID.  The app then cannot write its own files/, extraction fails
# silently, and pideploy is missing.  When root is available, repair the
# ownership of the app's own data directory before extracting.
replace_once(
    env_utils,
    '.method static updateEnv(Landroid/content/Context;)Z\n'
    "    .locals 16\n"
    '    .param p0, "c"    # Landroid/content/Context;\n\n'
    "    .line 242\n",
    '.method static updateEnv(Landroid/content/Context;)Z\n'
    "    .locals 16\n"
    '    .param p0, "c"    # Landroid/content/Context;\n\n'
    "    move-object/from16 v15, p0\n\n"
    "    invoke-virtual {v15}, Landroid/content/Context;->getApplicationInfo()Landroid/content/pm/ApplicationInfo;\n\n"
    "    move-result-object v0\n\n"
    "    iget-object v1, v0, Landroid/content/pm/ApplicationInfo;->dataDir:Ljava/lang/String;\n\n"
    "    new-instance v2, Ljava/io/File;\n\n"
    "    invoke-direct {v2, v1}, Ljava/io/File;-><init>(Ljava/lang/String;)V\n\n"
    "    invoke-virtual {v2}, Ljava/io/File;->canWrite()Z\n\n"
    "    move-result v2\n\n"
    "    if-eqz v2, :repair_env\n\n"
    "    invoke-static {v15}, Lcom/desktopecho/pideploy/PrefStore;->getEnvDir(Landroid/content/Context;)Ljava/lang/String;\n\n"
    "    move-result-object v1\n\n"
    "    new-instance v2, Ljava/io/File;\n\n"
    "    invoke-direct {v2, v1}, Ljava/io/File;-><init>(Ljava/lang/String;)V\n\n"
    "    invoke-virtual {v2}, Ljava/io/File;->exists()Z\n\n"
    "    move-result v1\n\n"
    "    if-eqz v1, :env_writable\n\n"
    "    invoke-virtual {v2}, Ljava/io/File;->canWrite()Z\n\n"
    "    move-result v1\n\n"
    "    if-eqz v1, :repair_env\n\n"
    "    goto :env_writable\n\n"
    "    :repair_env\n"
    "    new-instance v0, Ljava/util/ArrayList;\n\n"
    "    invoke-direct {v0}, Ljava/util/ArrayList;-><init>()V\n\n"
    "    new-instance v1, Ljava/lang/StringBuilder;\n\n"
    "    invoke-direct {v1}, Ljava/lang/StringBuilder;-><init>()V\n\n"
    '    const-string v2, "chown -R "\n\n'
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    "    invoke-static {}, Landroid/os/Process;->myUid()I\n\n"
    "    move-result v2\n\n"
    "    invoke-static {v2}, Ljava/lang/Integer;->toString(I)Ljava/lang/String;\n\n"
    "    move-result-object v2\n\n"
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    '    const-string v2, ":"\n\n'
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    "    invoke-static {}, Landroid/os/Process;->myUid()I\n\n"
    "    move-result v2\n\n"
    "    invoke-static {v2}, Ljava/lang/Integer;->toString(I)Ljava/lang/String;\n\n"
    "    move-result-object v2\n\n"
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    '    const-string v2, " "\n\n'
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    "    invoke-virtual {v15}, Landroid/content/Context;->getApplicationInfo()Landroid/content/pm/ApplicationInfo;\n\n"
    "    move-result-object v2\n\n"
    "    iget-object v2, v2, Landroid/content/pm/ApplicationInfo;->dataDir:Ljava/lang/String;\n\n"
    "    invoke-virtual {v1, v2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;\n\n"
    "    invoke-virtual {v1}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;\n\n"
    "    move-result-object v2\n\n"
    "    invoke-virtual {v0, v2}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z\n\n"
    "    invoke-static {}, Lcom/desktopecho/pideploy/EnvUtils;->isRooted()Z\n\n"
    "    move-result v1\n\n"
    "    if-eqz v1, :env_writable\n\n"
    '    const-string v1, "su"\n\n'
    "    invoke-static {v15, v1, v0}, Lcom/desktopecho/pideploy/EnvUtils;->exec(Landroid/content/Context;Ljava/lang/String;Ljava/util/List;)Z\n\n"
    "    :env_writable\n\n"
    "    .line 242\n",
    "EnvUtils.updateEnv storage repair",
)

# Initialize even when the storage permission is denied: extraction only uses
# internal storage, so refusing WRITE_EXTERNAL_STORAGE must not leave the app
# without files/bin/pideploy.
replace_once(
    base / "smali_classes2/com/desktopecho/pideploy/activity/MainActivity.smali",
    "    invoke-virtual {v0}, Landroid/widget/Toast;->show()V\n\n"
    "    .line 472\n",
    "    invoke-virtual {v0}, Landroid/widget/Toast;->show()V\n\n"
    "    .line 470\n"
    "    new-instance v1, Lcom/desktopecho/pideploy/UpdateEnvTask;\n\n"
    "    invoke-direct {v1, p0}, Lcom/desktopecho/pideploy/UpdateEnvTask;-><init>(Landroid/content/Context;)V\n\n"
    "    const/4 v0, 0x0\n\n"
    "    new-array v0, v0, [Ljava/lang/String;\n\n"
    "    invoke-virtual {v1, v0}, Lcom/desktopecho/pideploy/UpdateEnvTask;->execute([Ljava/lang/Object;)Landroid/os/AsyncTask;\n\n"
    "    .line 472\n",
    "MainActivity.onRequestPermissionsResult",
)
PY

# --- patch the CLI/container lifecycle ----------------------------------
# A stopped container used to leave daemons behind: rc6.d in the shipped
# images has no K links for dbus, cron and syslogd, and container_stop()
# returned early when the container had already been unmounted.  The orphaned
# processes kept the ports (dropbear/xrdp/pihole-FTL "fail", dnsmasq "Address
# in use") and kept the old rootfs files alive, so the next deploy deleted a
# gigabyte of data that was still referenced and then ran out of space
# mid-extraction (curl: (23) Failure writing output to destination).
#
# Kill every process whose root is the container directory before start, after
# stop, and before a destructive install.  Also make init/sysv tolerate an
# rc?.d entry that is renamed while it is being started (the first boot's
# provisioning reorders the links), and refuse to deploy when there is not
# enough free space for the image.
echo "==> patching container lifecycle"
python3 - "$WORK/decoded" <<'PY'
import pathlib
import sys

base = pathlib.Path(sys.argv[1])


def replace_once(path: pathlib.Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


cli = base / "assets/env/cli.sh"

replace_once(
    cli,
    """kill_pids()
{
    local pids=$(get_pids $*)
    if [ -n "${pids}" ]; then
        kill -9 ${pids}
        return $?
    fi
    return 0
}
""",
    """kill_pids()
{
    local pids=$(get_pids $*)
    if [ -n "${pids}" ]; then
        kill -9 ${pids}
        return $?
    fi
    return 0
}

# Absolute roots that identify processes belonging to this container.  The
# deployment directory (TARGET_PATH) and its mount point (CHROOT_DIR) can be
# different, and a previous session may have left services running after the
# container was unmounted, so both have to be checked.
container_roots()
{
    local roots="${CHROOT_DIR%/}"
    local target="${TARGET_PATH%/}"
    local base="${ENV_DIR:-$(pwd)}"
    case "${target}" in
    /*) ;;
    *) target="${base%/}/${target#./}" ;;
    esac
    target="${target%/}"
    if [ -n "${target}" -a "${target}" != "${roots}" ]; then
        roots="${roots} ${target}"
    fi
    echo "${roots}"
}

# Stop services left behind by an earlier start/stop.  rc6.d in the shipped
# images does not contain K links for every daemon (dbus, cron, syslogd and
# others survive do_stop), and if the container was already unmounted,
# container_stop returned early and killed nothing.  Those processes keep the
# ports and the deleted rootfs files, which makes the next start fail with
# "Address in use" and makes the next deploy run out of space.
kill_container_processes()
{
    local roots=$(container_roots)
    local pids=""
    local pid root
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$')
    do
        [ "${pid}" = "$$" ] && continue
        [ "${pid}" = "${PPID}" ] && continue
        root=$(readlink "/proc/${pid}/root" 2>/dev/null)
        [ -n "${root}" ] || continue
        root="${root% (deleted)}"
        case " ${roots} " in
        *" ${root} "*) pids="${pids} ${pid}" ;;
        esac
    done
    [ -n "${pids}" ] || return 0

    msg -n "Stopping stale container processes ... "
    kill -TERM ${pids} 2>/dev/null
    local i alive
    for i in 1 2 3 4 5
    do
        sleep 1
        alive=""
        for pid in ${pids}
        do
            [ -d "/proc/${pid}" ] && alive="${alive} ${pid}"
        done
        [ -n "${alive}" ] || { msg "done"; return 0; }
        pids="${alive}"
    done
    kill -9 ${pids} 2>/dev/null
    sleep 1
    msg "done"
    return 0
}
""",
    "cli.kill_container_processes",
)

replace_once(
    cli,
    """    container_mounted || { msg "The container is not mounted." ; return 0; }

    msg -n "Release resources ... \"""",
    """    container_mounted || { msg "The container is not mounted." ; return 0; }

    kill_container_processes

    msg -n "Release resources ... \"""",
    "cli.container_umount reap",
)

replace_once(
    cli,
    """container_start()
{
    container_mounted || { msg "The container is not mounted." ; return 1; }
""",
    """container_start()
{
    kill_container_processes
    container_mounted || { msg "The container is not mounted." ; return 1; }
""",
    "cli.container_start reap",
)

replace_once(
    cli,
    """container_stop()
{
    container_mounted || { msg "The container is not mounted." ; return 1; }

    DO_ACTION='do_stop'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}
""",
    """container_stop()
{
    if container_mounted; then
        DO_ACTION='do_stop'
        if [ $# -gt 0 ]; then
            component_exec "$@"
        else
            component_exec "${INCLUDE}"
        fi
    else
        msg "The container is not mounted."
    fi
    # Even if the mount is gone, make sure no daemon from this container is
    # left running.  Otherwise it keeps the ports and the old rootfs busy.
    kill_container_processes
    return 0
}
""",
    "cli.container_stop reap",
)

replace_once(
    cli,
    """    # parse parameters
    params_parse "$@"
    shift $((OPTIND-1))

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi
""",
    """    # parse parameters
    params_parse "$@"
    shift $((OPTIND-1))

    # A destructive install must not run on top of a live container: rm would
    # fail on proc/sys/dev, services would keep deleted files mapped, and the
    # extraction would run out of space.  Stop everything and unmount first.
    if [ "${DO_ACTION#*do_install}" != "${DO_ACTION}" ]; then
        kill_container_processes
        container_umount >/dev/null 2>&1
    fi

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi
""",
    "cli.deploy cleanup",
)

sysv = base / "assets/env/include/init/sysv/deploy.sh"

replace_once(
    sysv,
    """    [ -n "${INIT_LEVEL}" ] || return 0

    local services=$(ls "${CHROOT_DIR}/etc/rc${INIT_LEVEL}.d/" | grep '^S')
""",
    """    [ -n "${INIT_LEVEL}" ] || return 0

    # A fresh extraction resets ownership of runtime files.  xrdp runs as the
    # unprivileged xrdp user and refuses to start when it cannot write its log
    # ("Could not start log"), so restore the ownership the image expects.
    if [ -d "${CHROOT_DIR}/etc/xrdp" ]; then
        chroot_exec -u root "/usr/bin/chown xrdp:xrdp /var/log/xrdp.log /var/log/xrdp-sesman.log 2>/dev/null; /usr/bin/chmod 0660 /var/log/xrdp.log /var/log/xrdp-sesman.log 2>/dev/null" >/dev/null 2>&1
    fi

    local services=$(ls "${CHROOT_DIR}/etc/rc${INIT_LEVEL}.d/" | grep '^S')
""",
    "sysv.do_start xrdp log ownership",
)

replace_once(
    sysv,
    """        for item in ${services}
        do
            msg -n "${item/S[0-9][0-9]/} ... "
""",
    """        for item in ${services}
        do
            # The first boot runs android-raspbian, which may reorder the
            # rc3.d links (e.g. S04p4a-terminal -> S01p4a-terminal) while this
            # list is being processed.  Do not execute a stale name.
            [ -e "${CHROOT_DIR}/etc/rc${INIT_LEVEL}.d/${item}" ] || continue
            msg -n "${item/S[0-9][0-9]/} ... "
""",
    "sysv.do_start rename race",
)

replace_once(
    sysv,
    """        for item in ${services}
        do
            msg -n "${item/K[0-9][0-9]/} ... "
""",
    """        for item in ${services}
        do
            [ -e "${CHROOT_DIR}/etc/rc6.d/${item}" ] || continue
            msg -n "${item/K[0-9][0-9]/} ... "
""",
    "sysv.do_stop rename race",
)

rootfs = base / "assets/env/include/bootstrap/rootfs/deploy.sh"

replace_once(
    rootfs,
    """do_install()
{
""",
    """rootfs_space_check()
{
    [ "${TARGET_TYPE}" = "directory" ] || return 0
    local required="${MIN_FREE_MB:-}"
    if [ -z "${required}" ]; then
        case "${SOURCE_PATH##*/}" in
        *32*) required=1200 ;;
        *) required=1600 ;;
        esac
    fi
    local probe="${CHROOT_DIR}"
    if [ ! -d "${probe}" ]; then
        probe="${TARGET_PATH%/*}"
        [ -n "${probe}" -a "${probe}" != "${TARGET_PATH}" ] || probe="."
    fi
    local available=$(df -k "${probe}" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    [ -n "${available}" ] || return 0
    if [ "${available}" -lt "${required}" ]; then
        msg "Not enough free space: ${available} MB available, ${required} MB required."
        msg "Remove unused files or deployments, then deploy again."
        return 1
    fi
    msg "Free space check: ${available} MB available (${required} MB required)"
    return 0
}

do_install()
{
""",
    "rootfs.space_check",
)

replace_once(
    rootfs,
    """    msg ":: Installing ${COMPONENT} ... "

    rootfs_make || return 1
""",
    """    msg ":: Installing ${COMPONENT} ... "

    # Check before rootfs_make: for a directory target it deletes the existing
    # deployment, and a later failure must not leave an empty container.
    rootfs_space_check || return 1
    rootfs_make || return 1
""",
    "rootfs.do_install space_check",
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
grep -q '#!/system/bin/sh' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
grep -q 'cannot execute a bundled busybox' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
grep -q 'const-string v4, "/system/bin/sh "' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
grep -q 'busybox_arm64' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/EnvUtils.smali"
test -s "$WORK/decoded/assets/bin/all/busybox_arm"
test -s "$WORK/decoded/assets/bin/all/busybox_arm64"
grep -q 'new-array v0, v0, \[Ljava/lang/String;' "$WORK/decoded/smali_classes2/com/desktopecho/pideploy/activity/MainActivity.smali"
grep -q 'kill_container_processes' "$WORK/decoded/assets/env/cli.sh"
grep -q 'rootfs_space_check' "$WORK/decoded/assets/env/include/bootstrap/rootfs/deploy.sh"
grep -q 'Do not execute a stale name' "$WORK/decoded/assets/env/include/init/sysv/deploy.sh"
grep -q 'xrdp.log' "$WORK/decoded/assets/env/include/init/sysv/deploy.sh"

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
