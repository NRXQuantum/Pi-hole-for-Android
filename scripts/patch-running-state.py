#!/usr/bin/env python3
"""Patch the decoded APK so the UI reflects the live container state.

Two user-visible problems are fixed here:

*  Opening Properties used to re-import the profile
   (``MainActivity.containerProperties`` passed ``restore=true``).  A stale
   ``INCLUDE`` in the profile therefore flipped the SSH checkbox back on even
   though the user had just switched it off.  The screen now opens with the
   stored preferences, and every switch is written back immediately.
*  START/STOP was driven by a guessed state.  ``cli.sh`` now records the pids
   of the chroot processes in ``files/run/container.pids``; the activity polls
   that file and only offers STOP while the container is really running.

Run from scripts/build-apk.sh after the container-lifecycle patch, because the
cli.sh anchors below include the ``container_roots`` helper added there.
"""

import pathlib
import sys

base = pathlib.Path(sys.argv[1])
smali = base / "smali_classes2/com/desktopecho/pideploy"


def replace_once(path, old, new, label):
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


main = smali / "activity/MainActivity.smali"

methods = '''# --- container running-state helpers -------------------------------------

.method private hasLiveContainerProcess()Z
    .locals 8

    const/4 v0, 0x0

    :try_start_0
    new-instance v1, Ljava/io/File;

    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->getFilesDir()Ljava/io/File;

    move-result-object v2

    const-string v3, "run/container.pids"

    invoke-direct {v1, v2, v3}, Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V

    invoke-virtual {v1}, Ljava/io/File;->exists()Z

    move-result v2

    if-nez v2, :try_end_0

    new-instance v2, Ljava/io/BufferedReader;

    new-instance v3, Ljava/io/FileReader;

    invoke-direct {v3, v1}, Ljava/io/FileReader;-><init>(Ljava/io/File;)V

    invoke-direct {v2, v3}, Ljava/io/BufferedReader;-><init>(Ljava/io/Reader;)V

    :goto_0
    invoke-virtual {v2}, Ljava/io/BufferedReader;->readLine()Ljava/lang/String;

    move-result-object v3

    if-nez v3, :cond_0

    invoke-virtual {v2}, Ljava/io/BufferedReader;->close()V

    goto :try_end_0

    :cond_0
    invoke-virtual {v3}, Ljava/lang/String;->trim()Ljava/lang/String;

    move-result-object v3

    invoke-virtual {v3}, Ljava/lang/String;->isEmpty()Z

    move-result v4

    if-eqz v4, :goto_0

    invoke-static {v3}, Ljava/lang/Integer;->parseInt(Ljava/lang/String;)I

    move-result v4

    new-instance v5, Ljava/io/File;

    new-instance v6, Ljava/lang/StringBuilder;

    invoke-direct {v6}, Ljava/lang/StringBuilder;-><init>()V

    const-string v7, "/proc/"

    invoke-virtual {v6, v7}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v6, v4}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v6}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v6

    invoke-direct {v5, v6}, Ljava/io/File;-><init>(Ljava/lang/String;)V

    invoke-virtual {v5}, Ljava/io/File;->exists()Z

    move-result v6

    if-nez v6, :goto_0

    invoke-virtual {v2}, Ljava/io/BufferedReader;->close()V

    const/4 v0, 0x1

    goto :try_end_0
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    goto :goto_1

    :catch_0
    move-exception v1

    const/4 v0, 0x0

    :goto_1
    return v0
.end method

.method public refreshContainerState()V
    .locals 4

    invoke-direct {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->hasLiveContainerProcess()Z

    move-result v0

    iget-boolean v1, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->bootstrapRequested:Z

    if-nez v1, :cond_0

    const/4 v1, 0x1

    iput-boolean v1, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->bootstrapRequested:Z

    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->getBaseContext()Landroid/content/Context;

    move-result-object v1

    const-string v2, "running"

    const-string v3, "-q"

    invoke-static {v1, v2, v3}, Lcom/desktopecho/pideploy/EnvUtils;->execService(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    :cond_0
    const v1, 0x7f090128

    invoke-virtual {p0, v1}, Lcom/desktopecho/pideploy/activity/MainActivity;->findViewById(I)Landroid/view/View;

    move-result-object v1

    const v2, 0x7f090129

    invoke-virtual {p0, v2}, Lcom/desktopecho/pideploy/activity/MainActivity;->findViewById(I)Landroid/view/View;

    move-result-object v2

    if-eqz v1, :cond_3

    if-eqz v2, :cond_3

    if-eqz v0, :cond_1

    const/16 v3, 0x8

    invoke-virtual {v1, v3}, Landroid/view/View;->setVisibility(I)V

    const/4 v3, 0x0

    invoke-virtual {v2, v3}, Landroid/view/View;->setVisibility(I)V

    goto :cond_2

    :cond_1
    const/4 v3, 0x0

    invoke-virtual {v1, v3}, Landroid/view/View;->setVisibility(I)V

    const/16 v3, 0x8

    invoke-virtual {v2, v3}, Landroid/view/View;->setVisibility(I)V

    :cond_2
    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->invalidateOptionsMenu()V

    :cond_3
    return-void
.end method

.method public scheduleStateRefresh()V
    .locals 4

    iget-object v0, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateHandler:Landroid/os/Handler;

    if-nez v0, :cond_0

    new-instance v0, Landroid/os/Handler;

    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;

    move-result-object v1

    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V

    iput-object v0, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateHandler:Landroid/os/Handler;

    :cond_0
    iget-object v1, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateRunnable:Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;

    if-nez v1, :cond_1

    new-instance v1, Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;

    invoke-direct {v1, p0}, Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;-><init>(Lcom/desktopecho/pideploy/activity/MainActivity;)V

    iput-object v1, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateRunnable:Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;

    :cond_1
    invoke-virtual {v0, v1}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    const-wide/16 v2, 0x7d0

    invoke-virtual {v0, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void
.end method

.method public stopStateRefresh()V
    .locals 2

    iget-object v0, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateHandler:Landroid/os/Handler;

    if-eqz v0, :cond_0

    iget-object v1, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->stateRunnable:Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;

    if-eqz v1, :cond_0

    invoke-virtual {v0, v1}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    :cond_0
    const/4 v0, 0x0

    iput-boolean v0, p0, Lcom/desktopecho/pideploy/activity/MainActivity;->bootstrapRequested:Z

    return-void
.end method

.method public onPause()V
    .locals 0

    invoke-super {p0}, Landroidx/appcompat/app/AppCompatActivity;->onPause()V

    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->stopStateRefresh()V

    return-void
.end method

.method public onPrepareOptionsMenu(Landroid/view/Menu;)Z
    .locals 3

    invoke-direct {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->hasLiveContainerProcess()Z

    move-result v0

    const v1, 0x7f0900ae

    invoke-interface {p1, v1}, Landroid/view/Menu;->findItem(I)Landroid/view/MenuItem;

    move-result-object v1

    if-eqz v1, :cond_0

    xor-int/lit8 v2, v0, 0x1

    invoke-interface {v1, v2}, Landroid/view/MenuItem;->setVisible(Z)V

    :cond_0
    const v1, 0x7f0900b0

    invoke-interface {p1, v1}, Landroid/view/Menu;->findItem(I)Landroid/view/MenuItem;

    move-result-object v1

    if-eqz v1, :cond_1

    invoke-interface {v1, v0}, Landroid/view/MenuItem;->setVisible(Z)V

    :cond_1
    invoke-super {p0, p1}, Landroidx/appcompat/app/AppCompatActivity;->onPrepareOptionsMenu(Landroid/view/Menu;)Z

    move-result v0

    return v0
.end method

'''

replace_once(
    main,
    ".method public onCreate(Landroid/os/Bundle;)V",
    methods + ".method public onCreate(Landroid/os/Bundle;)V",
    "MainActivity state methods",
)

fields = '''# instance fields
.field private bootstrapRequested:Z

.field private stateHandler:Landroid/os/Handler;

.field private stateRunnable:Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;

'''
replace_once(main, "# instance fields\n", fields, "MainActivity state fields")

# onResume: refresh the button/menu state after every resume
replace_once(
    main,
    '''    :cond_5
    :goto_3
    return-void
.end method

.method public setTheme(I)V''',
    '''    :cond_5
    :goto_3
    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->refreshContainerState()V

    invoke-virtual {p0}, Lcom/desktopecho/pideploy/activity/MainActivity;->scheduleStateRefresh()V

    return-void
.end method

.method public setTheme(I)V''',
    "MainActivity.onResume",
)

# containerProperties: do not re-import the profile on every open
replace_once(
    main,
    '''    .line 381
    .local v0, "intent":Landroid/content/Intent;
    const-string v1, "restore"

    const/4 v2, 0x1

    invoke-virtual {v0, v1, v2}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Z)Landroid/content/Intent;

    .line 382
    invoke-virtual {p0, v0}, Lcom/desktopecho/pideploy/activity/MainActivity;->startActivity(Landroid/content/Intent;)V''',
    '''    .line 381
    .local v0, "intent":Landroid/content/Intent;
    .line 382
    invoke-virtual {p0, v0}, Lcom/desktopecho/pideploy/activity/MainActivity;->startActivity(Landroid/content/Intent;)V''',
    "containerProperties restore",
)

# changeProfile: load the selected profile, now that the properties button no
# longer re-imports it on every open
pref = smali / "PrefStore.smali"
replace_once(
    pref,
    '''    .line 604
    :cond_0
    return-void
.end method

.method public static dumpProperties''',
    '''    .line 604
    :cond_0
    invoke-static {p0}, Lcom/desktopecho/pideploy/PrefStore;->restoreProperties(Landroid/content/Context;)Z

    return-void
.end method

.method public static dumpProperties''',
    "changeProfile restore",
)

# persist the profile as soon as a preference changes, so a stale INCLUDE cannot
# survive an app kill or a profile switch
frag = smali / "fragment/PropertiesFragment.smali"
replace_once(
    frag,
    '''    .line 134
    .local v0, "pref":Landroidx/preference/Preference;
    const/4 v1, 0x1

    invoke-direct {p0, v0, v1}, Lcom/desktopecho/pideploy/fragment/PropertiesFragment;->setSummary(Landroidx/preference/Preference;Z)V

    .line 135
    return-void
.end method''',
    '''    .line 134
    .local v0, "pref":Landroidx/preference/Preference;
    const/4 v1, 0x1

    invoke-direct {p0, v0, v1}, Lcom/desktopecho/pideploy/fragment/PropertiesFragment;->setSummary(Landroidx/preference/Preference;Z)V

    .line 135
    invoke-virtual {p0}, Lcom/desktopecho/pideploy/fragment/PropertiesFragment;->getContext()Landroid/content/Context;

    move-result-object v0

    invoke-static {v0}, Lcom/desktopecho/pideploy/PrefStore;->dumpProperties(Landroid/content/Context;)Z

    return-void
.end method''',
    "PropertiesFragment dump",
)

# The include -> is_ssh mapping used to only ever set the switch to true.  A
# profile without extra/ssh therefore left a previous true value behind when a
# profile was loaded.  Make the mapping symmetric.
props = smali / "PropertiesStore.smali"
replace_once(
    props,
    '''    .line 84
    :cond_4
    const-string v2, "extra/ssh"

    invoke-interface {v0, v2}, Ljava/util/List;->contains(Ljava/lang/Object;)Z

    move-result v2

    if-eqz v2, :cond_5

    const-string v2, "is_ssh"

    invoke-virtual {p0, p1, v2, v1}, Lcom/desktopecho/pideploy/PropertiesStore;->set(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    .line 85
    :cond_5''',
    '''    .line 84
    :cond_4
    const-string v2, "extra/ssh"

    invoke-interface {v0, v2}, Ljava/util/List;->contains(Ljava/lang/Object;)Z

    move-result v2

    if-eqz v2, :cond_ssh_off

    const-string v2, "is_ssh"

    invoke-virtual {p0, p1, v2, v1}, Lcom/desktopecho/pideploy/PropertiesStore;->set(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    goto :goto_ssh_done

    :cond_ssh_off
    const-string v2, "is_ssh"

    const-string v3, "false"

    invoke-virtual {p0, p1, v2, v3}, Lcom/desktopecho/pideploy/PropertiesStore;->set(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V

    :goto_ssh_done
    .line 85
    :cond_5''',
    "PropertiesStore.is_ssh",
)

# new runnable for the 2 s state poll
runnable = smali / "activity/ContainerStateRunnable.smali"
runnable.write_text(
    '''.class public Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;
.super Ljava/lang/Object;
.source "ContainerStateRunnable.java"

# interfaces
.implements Ljava/lang/Runnable;


# instance fields
.field private final activity:Lcom/desktopecho/pideploy/activity/MainActivity;


# direct methods
.method public constructor <init>(Lcom/desktopecho/pideploy/activity/MainActivity;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;->activity:Lcom/desktopecho/pideploy/activity/MainActivity;

    return-void
.end method


# virtual methods
.method public run()V
    .locals 1

    iget-object v0, p0, Lcom/desktopecho/pideploy/activity/ContainerStateRunnable;->activity:Lcom/desktopecho/pideploy/activity/MainActivity;

    invoke-virtual {v0}, Lcom/desktopecho/pideploy/activity/MainActivity;->refreshContainerState()V

    invoke-virtual {v0}, Lcom/desktopecho/pideploy/activity/MainActivity;->scheduleStateRefresh()V

    return-void
.end method
''',
    encoding="utf-8",
)

# --- cli.sh: record the pids that belong to the container -----------------
cli = base / "assets/env/cli.sh"

replace_once(
    cli,
    '''container_roots()
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
''',
    '''container_roots()
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

# Keep the app informed about whether the container still has live processes.
# The app cannot inspect other processes without root, so cli.sh records the
# pids here after a successful start and removes the file on stop.  The app
# treats the container as running only while at least one recorded pid exists.
container_state_file()
{
    echo "${ENV_DIR%/}/run/container.pids"
}

update_container_state()
{
    local state=$(container_state_file)
    local roots=$(container_roots)
    local pid root pids=""
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$')
    do
        [ "${pid}" = "$$" ] && continue
        [ "${pid}" = "${PPID}" ] && continue
        root=$(readlink "/proc/${pid}/root" 2>/dev/null)
        [ -n "${root}" ] || continue
        root="${root% (deleted)}"
        case " ${roots} " in
        *" ${root} "*) pids="${pids}${pid}
" ;;
        esac
    done
    mkdir -p "${state%/*}" 2>/dev/null
    if [ -n "${pids}" ]; then
        # Write and rename atomically: the app polls this file every 2 s and
        # must never read a half-written pid list.
        printf '%s' "${pids}" > "${state}.$$"
        chmod 644 "${state}.$$" 2>/dev/null || true
        mv -f "${state}.$$" "${state}"
    else
        rm -f "${state}"
    fi
}

# The app writes properties as its own uid.  A config file created or rewritten
# by a root command would otherwise stay root-owned, so the next dump from the
# app failed silently and the profile kept a stale INCLUDE.  Hand the config
# directory back to the owner of the environment directory.
ensure_config_writable()
{
    [ -d "${CONFIG_DIR}" ] || return 0
    local owner=$(ls -nd "${ENV_DIR}" 2>/dev/null | awk '{print $3":"$4}')
    [ -n "${owner}" ] || return 0
    chown -R "${owner}" "${CONFIG_DIR}" 2>/dev/null || true
}
''',
    "cli.container_state",
)

replace_once(
    cli,
    '''[ -d "${CHROOT_DIR}" ] || mkdir "${CHROOT_DIR}"
''',
    '''[ -d "${CHROOT_DIR}" ] || mkdir "${CHROOT_DIR}"

# Keep the properties profile writable by the app (see ensure_config_writable).
ensure_config_writable
''',
    "cli.config_owner",
)

replace_once(
    cli,
    '''container_start()
{
    kill_container_processes
    container_mounted || { msg "The container is not mounted." ; return 1; }

    configure_ssh

    DO_ACTION='do_start'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}
''',
    '''container_start()
{
    rm -f "$(container_state_file)"
    kill_container_processes
    container_mounted || { msg "The container is not mounted." ; return 1; }

    configure_ssh

    DO_ACTION='do_start'
    local rc=0
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
    rc=$?
    update_container_state
    return ${rc}
}
''',
    "cli.container_start",
)

replace_once(
    cli,
    '''    # Even if the mount is gone, make sure no daemon from this container is
    # left running.  Otherwise it keeps the ports and the old rootfs busy.
    kill_container_processes
    return 0
}
''',
    '''    # Even if the mount is gone, make sure no daemon from this container is
    # left running.  Otherwise it keeps the ports and the old rootfs busy.
    kill_container_processes
    rm -f "$(container_state_file)"
    return 0
}
''',
    "cli.container_stop",
)

replace_once(
    cli,
    '''    if [ -n "${loop}" ]; then
        msg -n "Disassociating loop device ... "
        losetup -d "${loop}"
        is_ok "fail" "done"
    fi

    return 0
}
''',
    '''    if [ -n "${loop}" ]; then
        msg -n "Disassociating loop device ... "
        losetup -d "${loop}"
        is_ok "fail" "done"
    fi

    rm -f "$(container_state_file)"
    return 0
}
''',
    "cli.container_umount",
)

replace_once(
    cli,
    '''status)
    if [ $# -gt 0 ]; then
        DO_ACTION='do_status'
        component_exec "$@"
    else
        container_status
    fi
;;
''',
    '''status)
    if [ $# -gt 0 ]; then
        DO_ACTION='do_status'
        component_exec "$@"
    else
        container_status
    fi
;;
running)
    update_container_state
    if [ -s "$(container_state_file)" ]; then
        [ "$1" = "-q" ] || msg "running"
    else
        [ "$1" = "-q" ] || msg "stopped"
    fi
;;
''',
    "cli.running",
)

print("patched running-state UI")
