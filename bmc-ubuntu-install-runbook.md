# Runbook: Access the Control-Plane BMC and Install Ubuntu

Environment: NVIDIA LaunchPad lab, Lenovo ThinkSystem server managed by
XClarity Controller 3 (XCC3).

This runbook covers reaching the BMC from outside the lab, determining whether
the server already has an operating system, and performing a bare-metal Ubuntu
install over virtual media.

---

## 0. Before you start

**Confirm the node is yours to wipe.** This is a *control-plane* node. Many
bare-metal labs provision control-plane nodes through metal3 / BareMetalHost
CRs or an agent-based installer. A manual OS install on such a node will either
be reverted by the provisioning controller or will break the cluster. Verify
with the lab documentation or the lab owner that a manual reinstall is intended
before proceeding past section 3.

You will need:

- SSO access to the LaunchPad tenant (browser session).
- The BMC address of the target node.
- XCC credentials (see section 2).
- An Ubuntu Server ISO.

---

## 1. Reaching the lab

The BMC sits on a private provisioning network that is not routable from a
workstation. Everything must go through the bastion. Two options:

### 1a. noVNC bastion desktop (works with browser access only)

Open the lab's noVNC URL in a browser already signed in to LaunchPad:

```
https://<tenant-id>.apps.launchpad.nvidia.com/launch/novnc/vnc.html?resize=remote&path=novnc/websockify
```

This is the "bastion desktop" referred to in the lab documentation. Launch a
browser inside that desktop and drive the BMC from there.

Practical notes:

- **Clipboard is not `Cmd+V`.** Expand the control bar via the small tab on the
  left edge of the noVNC window and use its **Clipboard** panel. Paste text
  there on your side, then `Ctrl+V` inside the session. Necessary for entering
  BMC credentials reliably.
- The same sidebar has **Fullscreen** and **Ctrl+Alt+Del**. Combined with
  `resize=remote`, fullscreen makes the desktop match your window.
- Mac modifier keys do not map — use `Ctrl`, not `Cmd`, inside the session.
- If you get "Failed to connect to server", check the `path=` parameter. The
  standard noVNC proxy path is `websockify`.

### 1b. SSH SOCKS proxy (preferred if SSH to the bastion is available)

Noticeably faster than driving a browser through VNC, and the BMC's HTML5
virtual console performs much better.

```sh
ssh -D 1080 -N -C <user>@<bastion>
```

Leave it running, then point a browser at SOCKS5 `127.0.0.1:1080`.

Firefox (use a throwaway profile so you do not proxy everything):

```sh
/Applications/Firefox.app/Contents/MacOS/firefox -no-remote -P bmc
```

Settings → Network Settings → Manual proxy → SOCKS Host `127.0.0.1`, Port
`1080`, SOCKS v5, and tick **Proxy DNS when using SOCKS v5**.

Chrome:

```sh
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir=/tmp/bmc-profile \
  --proxy-server="socks5://127.0.0.1:1080"
```

Prefer SOCKS over a plain `-L` port-forward: BMCs frequently redirect to their
own hostname, which breaks `localhost:<port>` forwards. If you do use a
port-forward and hit a redirect loop, map the BMC hostname to `127.0.0.1` in
`/etc/hosts`.

Expect a self-signed certificate warning. That is normal for a BMC.

---

## 2. Finding the BMC address and credentials

### Address

If the lab runs OpenShift bare metal, the BareMetalHost CRs carry it
(read-only):

```sh
oc get bmh -A -o custom-columns=\
'NAME:.metadata.name,BMC:.spec.bmc.address,STATE:.status.provisioning.state'
```

Strip the `redfish-virtualmedia+https://` or `idrac-virtualmedia://` prefix to
get the host to open in a browser.

Otherwise the addresses are listed in the lab documentation, typically under
**Lab Details** or **Access**.

### Credentials

BMC credentials for a LaunchPad lab are published in the lab's own
documentation — check the **Credentials**, **Access**, or **Lab Details**
section of:

```
https://<tenant-id>.apps.launchpad.nvidia.com/launch/docs/#/start-here
```

Also check the bastion home directory for a credentials file dropped by lab
provisioning.

Reference only: the historical Lenovo default is `USERID` / `PASSW0RD` (zero,
not the letter O). XCC2 and XCC3 hardware ships with a **unique factory
password printed on the pull-out tab on the chassis**, so there is no guessable
default, and a provisioned lab will have set its own credentials regardless. If
the documentation does not list them, treat it as a lab-provisioning question
and ask the lab owner rather than attempting to work around the login.

---

## 3. Determining whether an OS is already installed

### Without BMC credentials, from the bastion

Use the node's **host** IP (its OS-facing address), not the BMC IP:

```sh
ping -c2 <host-ip>
nc -vz <host-ip> 22
nmap -Pn -p 22,80,443,6443,9100 <host-ip>
```

An answer on `22` means an OS is installed and running. A hit on `6443` means a
Kubernetes control plane is already up.

On an OpenShift bare-metal lab, this is definitive in one read-only command:

```sh
oc get bmh -A -o custom-columns=\
'NAME:.metadata.name,STATE:.status.provisioning.state,ONLINE:.spec.online,CONSUMER:.spec.consumerRef.name'
```

`provisioned` with a consumer means an OS is installed and the node is in use.
`available` or `ready` means the node is bare.

### With XCC access

**Remote Console gives an immediate answer.** Open it and read the screen:

| Console shows                        | Meaning              |
| ------------------------------------ | -------------------- |
| Login prompt or desktop              | OS installed, booted |
| GRUB menu                            | OS installed         |
| "No bootable device" or UEFI Shell   | Empty disk           |
| PXE / network boot attempts          | No local OS          |

Two corroborating places in the UI:

- **Server Configuration → Boot Options** — the UEFI boot entry list. A named
  entry such as `ubuntu`, `rhcos`, or `Red Hat Enterprise Linux` is a
  bootloader written by an installed OS. Only `UEFI Network` / `UEFI USB`
  entries means nothing is installed.
- **Inventory → Drives** — confirms disks are present and correctly sized.
  Worth checking before an install regardless.

A server showing **powered off** on the dashboard tells you nothing about disk
contents. Power it on and watch the console, or read the boot entries.

---

## 4. Installing Ubuntu via XCC3 virtual media

1. **Log in to the XCC web UI.**

2. **Verify licensing.** Remote console and virtual media require XClarity
   Controller **Advanced** or **Premium**. On base XCC these features are
   greyed out. Lab hardware is normally licensed.

3. **Serve the ISO from the bastion.** Uploading an ISO through the browser is
   slow. The bastion shares the BMC network, so serve it over HTTP instead:

   ```sh
   python3 -m http.server 8000
   ```

   In XCC → **Remote Console & Media → Mount Remote Media**, mount:

   ```
   http://<bastion-ip>:8000/ubuntu-24.04-live-server-amd64.iso
   ```

   XCC3 also accepts NFS and CIFS sources.

4. **Launch the HTML5 remote console** from the same page.

5. **Set one-time boot:** Server Configuration → **Boot Options** → one-time
   boot → **CD/DVD-ROM**. Alternatively select **UEFI Boot Manager** and pick
   the virtual media device from the boot menu.

6. **Power cycle:** Power Actions → **Restart Server (immediately)**.

7. **Run the installer** in the console window.

8. **Unmount the virtual media** before the final reboot, then let the server
   boot from disk.

---

## 5. Gotchas

- **Use the Server ISO, not Desktop**, and boot it in **UEFI** mode. Mixing
  UEFI and legacy against an existing disk layout is the usual cause of
  "installer cannot find disk" or an unbootable result.
- **Keep virtual media mounted for the whole install.** Unmount only before the
  final reboot, or the server boots the installer again.
- **Verify the target disk** in the installer's storage step. Servers of this
  class often expose several controllers and NVMe devices; installing to the
  wrong one is easy and silent.
- **noVNC clipboard** — see section 1a. Do not try to type long passwords
  through the console by hand.
- **DevTools "0/50 requests"** — if you inspect LaunchPad web traffic and see
  zero requests listed, a filter is active, not a capture failure. Click
  **All**, clear the text filter box, and untick **Invert**. Tick **Preserve
  log** so SSO redirects do not clear the list.

---

## 6. Credential handling

The LaunchPad session cookie (`_pomerium`) and any BMC credentials are live
secrets. Do not paste them into shared transcripts, tickets, or chat. When
capturing authenticated HTTP requests for debugging, redirect output to a file
rather than letting it print:

```sh
<copied curl command> > /tmp/lp-docs.html
```
