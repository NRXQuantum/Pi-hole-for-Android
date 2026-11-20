# Pi-hole for Android APK Installer

[![Pi-hole for Android](https://user-images.githubusercontent.com/33142753/133272103-28c6eba3-d1f7-4e29-9c5b-7d96d9f94e9e.jpg)](https://www.youtube.com/watch?v=sdDkKvaRvOs)

[Pi-hole©](https://pi-hole.net/) is a network-level advertisement and Internet tracker blocking application for Linux which acts as a DNS sinkhole intended for use on a private network. It is designed for low-power embedded devices with network capability, focusing on the Raspberry Pi as its 'reference' hardware platform.

Pi-hole for Android is a Debian disk image tuned to work with the Pi-hole installer on Pi Deploy (a fork of Linux Deploy).  It can be used on **any** rooted Android device with an **ARMv7 or newer CPU** running Android 5.0 (Lolipop) or newer.  Form factor is not important; it could be a phone, tablet, HDMI stick or **any device running Android**.  For very old devices running Android 4.x, see the [Legacy branch](https://github.com/DesktopECHO/Pi-hole-for-Android/tree/legacy)


### What's New (November 2026) — v3.2.1
This release fixes the broken SSH, RDP and Pi Deploy **Terminal** in the 3.2.0 images.  Both disk images were rebuilt, and the included APK is pre-configured for them.

 - **SSH fixed:** the shipped images contained no Dropbear host keys (sysprep removed them and the old first-boot logic could not recreate them), so SSH failed with `No hostkeys available`.  Host keys (RSA/ECDSA/Ed25519) are now generated automatically on every boot, and Dropbear no longer plays games with its pid file.
 - **Web Terminal fixed:** Pi Deploy's Terminal tab opens `127.0.0.1:5023` over telnet.  The container now runs a loopback-only `telnetd` on that port (`p4a-terminal` service), and the bundled APK enables **Telnet** and **HTTP** by default.  This works whether or not the Android side provides its own telnetd.
 - **RDP/xrdp fixed:** the self-signed TLS certificate is recreated on boot with the correct ownership, stale `xrdp` pid files are cleaned up, and `/etc/ssl/private` is made traversable by the `xrdp` user.
 - **mDNS/avahi fixed:** no more `Failed to create client object: Daemon not running` spam; avahi waits for D-Bus, creates its runtime directory, and the status script only publishes aliases when the daemon is actually up.
 - **Stale runtime state:** leftover pid files in `/run` (dropbear, xrdp, cron, avahi) and scripts started with `cwd=/root` caused `find: Failed to change directory` and services refusing to start; both are handled now.
 - **Pi-hole v6 networking:** the boot script updates `dns.interface` and `dns.listeningMode` in `/etc/pihole/pihole.toml` (v6 no longer reads `setupVars.conf`).
 - **Architecture default:** the APK defaults to the **ARMv7 (armhf)** image because it runs on both 32-bit and 64-bit Android devices.  For a 64-bit userland, change the end of the **Source Path** URL from `/raspbian32.tgz` to `/raspbian.tgz`.
 - The images now include a static `busybox` binary used by the terminal service.

### Upgrading from v3.2.0
> **Important:** the APK in this release is signed with a new key, so Android will refuse to install it over the upstream Pi Deploy app.  Export your Pi-hole configuration with **Teleporter** first, then uninstall the old Pi Deploy APK before installing `pideploy.apk`.  Your Pi-hole data lives in the deployment image, not in the APK, but export a backup to be safe.

The easiest path is a fresh deployment: in your current Pi-hole go to **Settings → Teleporter**, download a backup, create a **New Deployment** with this release (or install the updated APK first), then restore the backup with Teleporter.

If you prefer to keep your existing deployment, you can update it in place.  From the Pi-hole web terminal or SSH:

```sh
sudo apt-get update && sudo apt-get install -y busybox-static
cd /tmp
curl -fL -o p4a.tgz https://github.com/NRXQuantum/Pi-hole-for-Android/archive/refs/heads/main.tar.gz
tar xzf p4a.tgz
sudo cp -a Pi-hole-for-Android-main/etc/init.d/. /etc/init.d/
sudo cp -a Pi-hole-for-Android-main/usr/local/bin/. /usr/local/bin/
sudo cp -a Pi-hole-for-Android-main/.pihole-FTL /
sudo chmod +x /etc/init.d/android-raspbian /etc/init.d/android-raspbian-status \
  /etc/init.d/dropbear /etc/init.d/xrdp /etc/init.d/pihole-FTL \
  /etc/init.d/p4a-terminal /usr/local/bin/p4a-terminald
sudo ln -sf ../init.d/p4a-terminal /etc/rc2.d/S04p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc3.d/S04p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc4.d/S04p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc5.d/S04p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc0.d/K01p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc1.d/K01p4a-terminal
sudo ln -sf ../init.d/p4a-terminal /etc/rc6.d/K01p4a-terminal
sudo /etc/init.d/dropbear restart
sudo /etc/init.d/xrdp restart
sudo /etc/init.d/p4a-terminal start
```

After a restart of the deployment, the Terminal tab and SSH should both work.

### What's New (March 2025)
 - **Update for Pi-hole v6 compatibility**
 - Removed lighttpd (not used in v6)
 - Fixed missing PulseAudio volume control in `pideploy-gui-install` XRDP session.
 - Fixed `pideploy-nextcloud-install` to move Pi-hole v6 webserver ports. 
 - Pi Deploy image is **64-bit** by default.
 - For **32-bit** devices, configure Pi Deploy to download the ARMv7 image:  Tap **Properties** and change the end of the **Source Path** URL from `/raspbian.tgz` to `/raspbian32.tgz`

### Requirements:

- Android device that has been rooted

## Install 
### Download the latest [Pi Deploy APK](https://github.com/NRXQuantum/Pi-hole-for-Android/releases/latest/download/pideploy.apk) and open the app.

- Tap **Allow** if asked for permission to access files or run as root.  

- Tap **More Options** (**Three dots** at the top right of screen)
    ![image](https://github.com/DesktopECHO/Pi-hole-for-Android/assets/33142753/b8cbe9e3-f47a-4e3b-a155-b6b0aa3a5161")

- Tap **New Deployment**:
    ![image](https://github.com/DesktopECHO/Pi-hole-for-Android/assets/33142753/a438ee12-b849-4c04-8be1-e5f61f4ba659)

- In a few minutes, the [Raspbian Pi-hole Image](https://github.com/NRXQuantum/Pi-hole-for-Android/releases/latest/download/raspbian32.tgz) will be downloaded and installed on your device (ARMv7 image, works on 32-bit and 64-bit devices).  The 64-bit image is available as [raspbian.tgz](https://github.com/NRXQuantum/Pi-hole-for-Android/releases/latest/download/raspbian.tgz).
- When deployment is complete, tap **[  ▷ START ]**  to launch the instance.
- The instance will provide you with a password to login to Pi-hole webadmin or via SSH/RDP (Username: _android_, see screenshot below)
- **Note**: The password appears only once when the image is deployed, make sure you record this information.  You can also copy the password text to your clipboard for easier management. 

-----------------------------------------------------------
### **INSTALL COMPLETE     ·     Your Android device is a Debian server running Pi-Hole!**

-----------------------------------------------------------
The Android device's IP is shown at the top of the Pi Deploy main window.  You can interact with Pi-hole in several ways, the examples below use IP **_10.73.0.31_** 

 - Connect via RDP in Windows using **```mstsc.exe /v:10.73.0.31```** or in Linux using **```xfreerdp /v:10.73.0.31```** 

 - Connect via SSH **->** **```ssh android@10.73.0.31```**

 - Pi-hole administration is accessible from any browser on your network **->** **```http://10.73.0.31/admin```**

 - If your Android device has a display, you can RDP into the Pi-hole instance (as localhost) by installing the [Microsoft Remote Desktop](https://play.google.com/store/apps/details?id=com.microsoft.rdc.androidx) client.

![image](https://user-images.githubusercontent.com/33142753/196851777-e46b145f-4c99-4b6f-9add-ed2f009dae4b.png)

![image](https://user-images.githubusercontent.com/33142753/196856874-72c307e3-2227-4ef1-a7b5-401e745f918f.png)

![Screenshot_20221020-013907_Bromite](https://user-images.githubusercontent.com/33142753/196860440-1723d8c2-09b0-460b-901e-260b5485d554.png)

**Pi-hole for Android wiki topics:**

- [Pi/Linux Deploy - Trouble finding disk image or install location](https://github.com/DesktopECHO/Pi-hole-for-Android/wiki/Trouble-finding-path-where-Pi%E2%80%90hole-image-is-downloaded,-or-errors-are-reported-during-creation-of-Pi%E2%80%90hole-disk-image.)

**Additional Info:**

RDP Sessions launch the Openbox window manager with QTerminal in fullscreen mode.  To open a new tab hit **[Ctrl-Shift-T]** and to un-hide the menubar hit **[Ctrl-Shift-M]**

You can stop the Pi-hole instance by pressing **[ ■ STOP ]** and waiting a few seconds for all services to stop.  Sart the instance by pressing **[ ▸ START ]**

When a Pi-hole instance starts up, the default configuration is set to automagically configure networking.  If you change networks on the Android device simply restart the instance for Pi-hole to pick up the new settings.

Alternatively, set a static assignment by commenting-out two lines in ```etc/init.d/android-raspbian```.  After the lines are commented out with a hash "#" you can manually set your IP, subnet and interface name in ```/etc/pihole/setupVars.conf```

![image](https://github.com/DesktopECHO/Pi-hole-for-Android/assets/33142753/8781dc01-ebe2-4ffc-bdec-82ca62d3cc97)

Added latest release of [Unbound 1.17](https://www.nlnetlabs.nl/projects/unbound/about) to provide encrypted DNS by default; no addional configuration is necessary but you may customize to preference.

The Pi-hole instance on Android otherwise behaves like it is running on a 'real' Raspberry-Pi or a standard PC.  Consult the extensive documentation online to learn how to fully leverage Pi-hole's functionality.

Adjust QT display scaling: ```~/startwm.sh``` 

Change the font size in QTerminal: ```~/.config/qterminal.org/qterminal.ini```

### Troubleshooting the v3.2.1 images

- **SSH:** connect with `ssh android@<device-ip>`.  If the connection is refused, run `sudo /etc/init.d/dropbear restart` and inspect `sudo tail -n 50 /tmp/p4a.log`.  Host keys are regenerated automatically if they are missing.
- **Terminal tab:** Pi Deploy connects to `127.0.0.1:5023` over telnet.  Verify with `sudo /etc/init.d/p4a-terminal status` and `sudo ss -ltn | grep 5023`.  In the deployment **Properties**, **Telnet** and **HTTP** should be enabled (the bundled APK sets both by default).
- **RDP/xrdp:** run `sudo /etc/init.d/xrdp restart`.  The boot script recreates `/etc/ssl/certs/ssl-cert-snakeoil.pem` and fixes its permissions, which resolves most xrdp connection failures.
- **Pi-hole admin page:** the v6 web server listens on port 80; use `http://<device-ip>/admin`.  If DNS does not answer after changing networks, stop and start the deployment so `dns.interface` is updated in `/etc/pihole/pihole.toml`.

**If your Android device has a battery and was unused for months or years, replace its battery.**  Old, worn, or abused Li-ion batteries can fail when pushed back into service.  Failure appears as a bulge in the battery, or worse a [**_thermal event_**](https://www.urbandictionary.com/define.php?term=unexpected+thermal+event).  A good battery provides [UPS](https://en.wikipedia.org/wiki/Uninterruptible_power_supply) protection for your newly-provisioned Pi-hole.

**Note:** There is no endorsement or partnership between this page and [Pi-hole© LLC](https://pi-hole.net/). They deserve [your support](https://pi-hole.net/donate/) if you find this useful.
