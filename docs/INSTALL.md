# Installing KultrDL on your iPhone

This guide assumes you have **never** installed an app from outside the App
Store before. The first time takes about 20 minutes. After that it takes 2
minutes. Your iPhone does **not** need to be jailbroken, and nothing here voids
your warranty.

**No computer?** On iOS 27 you can do all of it on the iPhone itself, with
SideInstaller and LocalDevVPN: [jump to *Without a computer*](#without-a-computer-sideinstaller-and-localdevvpn).

**Jump to:** [What you need](#what-you-need) ·
[1. Download](#1-download-kultrdl) ·
[2. Install the tool](#2-install-the-installing-tool-on-your-computer) ·
[3. Connect](#3-connect-your-iphone) ·
[4. Install KultrDL](#4-install-kultrdl) ·
[5. Unlock it on the iPhone](#5-let-the-iphone-open-it) ·
[6. The 7-day rule](#6-keeping-kultrdl-working-the-7-day-rule) ·
[7. Updating](#7-updating-to-a-new-version) ·
[Without a computer](#without-a-computer-sideinstaller-and-localdevvpn) ·
[Troubleshooting](#troubleshooting)

---

## What you are about to do, in plain words

Apple only lets iPhones run apps that Apple has signed. The App Store signs
apps for you. So does Apple's free developer program: any Apple ID can sign
an app **for its own iPhone**. Doing this yourself is called *sideloading*.

You will:

1. Download the KultrDL app file (`KultrDL.ipa`) to a computer.
2. Use a free program on that computer. It signs the app with your Apple ID
   and copies it onto your iPhone over a USB cable:
   - **Windows or Mac:** [Sideloadly](https://sideloadly.io)
   - **Linux:** [Impactor](https://github.com/khcrysalis/PlumeImpactor) (formerly
     *PlumeImpactor*)
3. Tell your iPhone that you trust apps signed by your own Apple ID.

There is one catch with a free Apple ID: **the app stops opening after 7 days**
unless you refresh it. Refreshing takes a minute and keeps all your data.
[Section 6](#6-keeping-kultrdl-working-the-7-day-rule) explains how.

---

## What you need

| | |
|---|---|
| An **iPhone or iPad** | running iOS 17 or newer (Settings → General → About → iOS Version) |
| A **computer** | Windows 10/11, a Mac, or a Linux PC. You only need it for installing and refreshing. On iOS 27 you can [skip the computer](#without-a-computer-sideinstaller-and-localdevvpn) |
| A **cable** | the one you charge your iPhone with. It must carry data, not only charge |
| An **Apple ID** | the one you already use is fine. Some people make a second, free Apple ID just for sideloading. That's optional |
| Optional: an **FTP or SFTP server** | a NAS or computer to send downloads to, with its address and a login |

---

## 1. Download KultrDL

Do this **on the computer**.

1. Open **https://github.com/evropiani/KultrDL_iOS/releases/latest** in a web
   browser. No GitHub account is needed.
2. Under **Assets**, click **`KultrDL.ipa`**. It downloads to your *Downloads*
   folder.
   - Do **not** click “Source code (zip)” or “Source code (tar.gz)”. That's the
     source code, not the app.

Leave the file where it is. You'll pick it in the installing tool in a moment.

---

## 2. Install the installing tool on your computer

Follow the part for your computer: [Windows](#on-windows) ·
[Mac](#on-a-mac) · [Linux](#on-linux).

### On Windows

Sideloadly needs Apple's own drivers to talk to your iPhone. They come with
iTunes and iCloud, but **only the versions from Apple's website work**. The
Microsoft Store versions do **not**.

1. If you already have iTunes or iCloud from the **Microsoft Store**, uninstall
   them first: Start → Settings → Apps → find *iTunes* / *iCloud* → Uninstall.
2. Install **iTunes** from Apple's website:
   https://www.apple.com/itunes/download/win64 (the download starts straight away).
   Run the installer and accept the defaults.
3. Install **iCloud for Windows** from Apple's website. Search for “iCloud for
   Windows download Apple support” and use the link on *support.apple.com*
   that says *“download iCloud for Windows from Apple's website”*. Don't use the
   Microsoft Store button. You don't need to sign in to iCloud afterwards. It
   only has to be installed.
4. Download **Sideloadly** from its official site, **https://sideloadly.io**.
   Pick the Windows version and install it with the defaults.
5. Restart the computer. It's the easiest way to make sure the Apple drivers load.

### On a Mac

1. Download **Sideloadly** from **https://sideloadly.io** (the macOS version).
2. Open the downloaded `.dmg` and drag Sideloadly into *Applications*.
3. Open it from *Applications*. The first time, macOS may ask whether you are
   sure. Click **Open**. If macOS refuses, go to System Settings →
   Privacy & Security, scroll down, and click **Open Anyway** next to
   Sideloadly.
4. Sideloadly may ask to install a **Mail plug-in**. Follow its instructions.
   It needs this to talk to Apple on macOS.

> Only ever download Sideloadly from **sideloadly.io**. Sites that offer
> “Sideloadly” downloads or “free iPhone apps” elsewhere are not safe.

### On Linux

Sideloadly doesn't run on Linux. Use **Impactor** instead. It's free and open
source and does the same job. You'll need a terminal for two or three commands.
Copy each one, paste it into the terminal (Ctrl+Shift+V) and press Enter.

**a) Make sure `usbmuxd` is installed.** This small service lets Linux talk to
iPhones. Most distributions include it already. Installing it again does no
harm:

| Your distribution | Command |
|---|---|
| Ubuntu, Linux Mint, Pop!_OS, Debian, elementary | `sudo apt install usbmuxd libimobiledevice-utils` |
| Fedora | `sudo dnf install usbmuxd libimobiledevice-utils` |
| Arch, Manjaro, EndeavourOS | `sudo pacman -S usbmuxd libimobiledevice` |
| openSUSE | `sudo zypper install usbmuxd libimobiledevice-tools` |

It asks for your computer password. The screen shows nothing while you type
it; that's normal. Press Enter when done.

**b) Install Impactor from Flathub.** Many distributions (Linux Mint, Fedora,
Pop!_OS and others) already have **Flatpak**. If yours doesn't, set it up once
by following the page for your distribution at https://flathub.org/setup.
Then run:

```sh
flatpak install flathub dev.khcrysalis.PlumeImpactor
```

Answer **y** when it asks. On some desktops you can also install it by clicking
**Install** on https://flathub.org/apps/dev.khcrysalis.PlumeImpactor, which
opens your software centre.

If you'd rather not use Flatpak, Impactor's
[releases page](https://github.com/khcrysalis/PlumeImpactor/releases) has
downloads for Linux too. Pick the newest release and the file for your
computer.

**c) Open Impactor** from your applications menu (it's called *Impactor*), or
from the terminal:

```sh
flatpak run dev.khcrysalis.PlumeImpactor
```

> Only download Impactor from Flathub or from its GitHub page
> (github.com/khcrysalis/PlumeImpactor).

---

## 3. Connect your iPhone

1. Unlock your iPhone and plug it into the computer with the cable.
2. The iPhone asks **“Trust This Computer?”** Tap **Trust** and enter your
   iPhone passcode.
   - If the question never appears, unplug and plug it back in with the phone
     unlocked. On Windows, opening iTunes once often triggers it. On Linux, run
     `idevicepair pair` in the terminal while the phone is unlocked, tap
     **Trust** on the phone, then run `idevicepair pair` once more.
3. To check it worked:
   - **Windows:** open iTunes. A small phone icon should appear near the top
     left. You can close iTunes again afterwards.
   - **Linux:** run `idevice_id -l`. It should print a long string of letters
     and numbers, which is your iPhone's ID. If it prints nothing, see
     [Troubleshooting](#linux-impactor-doesnt-see-my-iphone).

---

## 4. Install KultrDL

### With Sideloadly (Windows and Mac)

1. Open **Sideloadly**.
2. At the top, the **iDevice** box should show your iPhone's name. If it's
   empty, see [Troubleshooting](#sideloadly-doesnt-see-my-iphone).
3. In the **Apple account** box, type the email address of your Apple ID.
4. Drag **`KultrDL.ipa`** from your *Downloads* folder onto the big IPA icon on
   the left of Sideloadly. You can also click the icon and pick the file.
5. Click **Start**.
6. Sideloadly asks for your **Apple ID password**. Type it and press OK.
   Sideloadly sends it to Apple to create the free signing certificate. It
   doesn't go anywhere else.
7. If you use two-factor authentication (most people do), your iPhone or Mac
   shows a **6-digit code**. Type it into the box Sideloadly shows.
8. Wait. The bottom of the window shows progress, such as *“Signing”* and
   *“Installing”*. After about a minute it says **“Done.”**

### With Impactor (Linux)

1. With the iPhone plugged in and unlocked, open **Impactor**.
2. **Sign in with your Apple ID** (email and password) when Impactor asks. It
   uses them to get a free signing certificate from Apple, the same way
   Apple's own Xcode does.
3. If you use two-factor authentication, your iPhone shows a **6-digit code**.
   Type it into Impactor.
4. Make sure your iPhone is the selected device. Impactor registers it with
   your Apple ID the first time.
5. Choose **`KultrDL.ipa`** from your *Downloads* folder. You can drag it into
   the window or use Impactor's button for opening a file.
6. Start the install and wait. Impactor signs KultrDL and copies it to the
   phone. This takes about a minute.

---

The KultrDL icon (a silver **K**) is now on your iPhone's home screen, but it
**won't open yet**. Do the next section first.

## 5. Let the iPhone open it

These steps are done on the iPhone and are the same whichever computer you
used.

### Trust your own Apple ID

1. On the iPhone, open **Settings → General → VPN & Device Management**.
   (On some iOS versions it's called *Device Management* or *Profiles & Device
   Management*.)
2. Under **Developer App**, tap the entry with **your Apple ID email**.
3. Tap **Trust “your email”**, then **Trust** again.

### Turn on Developer Mode

iPhones need this switched on before they'll open any sideloaded app.

1. Open **Settings → Privacy & Security**.
2. Scroll all the way down and tap **Developer Mode**.
   - If there is no *Developer Mode* entry, install the app first
     ([section 4](#4-install-kultrdl)). The option only appears once a
     sideloaded app is on the phone.
3. Turn it **on**. The iPhone asks to restart. Tap **Restart**.
4. After the restart, unlock the phone. It asks once more whether to turn on
   Developer Mode. Tap **Turn On** and enter your passcode.

### Open KultrDL

Tap the **K** icon. There's nothing to sign in to: tap the round search
button, find a song and play it, or paste a link on the Home page.

To send downloads to a NAS or computer, add it under **Settings → Servers**.
When iOS asks whether KultrDL may *find devices on your local network*, tap
**Allow**, or a server at home can't be reached.

That's it. KultrDL is installed. 🎉

---

## 6. Keeping KultrDL working (the 7-day rule)

Apps signed with a **free** Apple ID expire **7 days** after you install them.
When that happens, KultrDL's icon stays on the home screen, but it won't open or
it closes straight away. **Your music, downloads and settings are not lost.**
You just need to sign it again:

1. Plug the iPhone into the computer and open Sideloadly (or Impactor on
   Linux).
2. Install the same `KultrDL.ipa` (or a newer one) exactly as in
   [section 4](#4-install-kultrdl), with the **same Apple ID**.
3. Done. KultrDL opens again for another 7 days, with everything where you left it.

Tip: refresh it once a week, for example every Sunday, **before** it expires.

### Letting Sideloadly refresh automatically (Windows and Mac)

Sideloadly can re-sign KultrDL for you in the background, over Wi-Fi:

1. Turn on Wi-Fi syncing once, with the cable plugged in:
   - **Windows:** open iTunes → click the phone icon → *Summary* → tick
     **“Sync with this iPhone over Wi-Fi”** → **Apply**.
   - **Mac:** open Finder → click your iPhone in the sidebar → *General* →
     tick **“Show this iPhone when on Wi-Fi”** → **Apply**.
2. In Sideloadly, before clicking **Start**, open **Advanced options** and
   enable **Automatic refresh** (Sideloadly may call it *auto-refresh*).
3. Leave the computer on, with Sideloadly running in the background, on the
   same Wi-Fi as the iPhone. It re-signs KultrDL before the 7 days are up.

On **Linux**, automatic refresh over Wi-Fi isn't available, because Linux's
iPhone service (`usbmuxd`) only works over the cable. Plug the phone in once
a week and reinstall as described above. It takes a minute.

### Limits of a free Apple ID

- At most **3 sideloaded apps** can be installed at the same time.
- At most **10 new app IDs per 7 days**. Reinstalling KultrDL doesn't use a new
  one, but installing lots of different apps does.
- The 7-day expiry described above.

A paid **Apple Developer Program** membership ($99/year) removes these limits
and makes installs last a full year. You don't need it to use KultrDL.

---

## 7. Updating to a new version

1. Download the newer `KultrDL.ipa` from the
   [latest release](https://github.com/evropiani/KultrDL_iOS/releases/latest), as
   in [section 1](#1-download-kultrdl).
2. Install it exactly as in [section 4](#4-install-kultrdl), using the **same
   Apple ID**.

It installs over the old version and **keeps your library, downloads, servers
and settings**. Don't delete the old app first, because deleting the app
deletes its data.

To hear about new versions, open the
[repository](https://github.com/evropiani/KultrDL_iOS), click **Watch** →
**Custom** → **Releases** (this needs a free GitHub account).

---

## Without a computer: SideInstaller and LocalDevVPN

Everything above uses a computer to sign KultrDL and copy it over a cable. With
two free apps, the iPhone can do that job itself:

- **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)** (App
  Store) is a VPN that only ever connects to your own iPhone. It lets
  sideloading tools talk to the phone the way a computer would. Nothing leaves
  the phone through it, and it doesn't use extra battery.
- **[SideInstaller](https://github.com/FrizzleM/SideInstaller)** installs
  **SideStore** for you, on the phone. SideStore is a small app store for your
  own apps: it installs `KultrDL.ipa` with your Apple ID, and re-signs it every
  week in the background, so the [7-day rule](#6-keeping-kultrdl-working-the-7-day-rule)
  takes care of itself.

| Your iOS version | Does it work without a computer? |
|---|---|
| **iOS 27** | ✅ Yes, start to finish |
| **iOS 18 to 26** | ⚠️ Yes, but only after a one-time *pairing file* is made [on a computer](https://docs.sidestore.io/docs/advanced/pairing-file) |
| **iOS 17** | ❌ No. Use a computer, as in sections 1 to 5 |

> ⚠️ **Get SideInstaller only from https://sideinstaller.net/** (or its
> [GitHub page](https://github.com/FrizzleM/SideInstaller)). You type your
> Apple ID password into it, and copies from anywhere else can steal it.
> **sideinstaller.com is a fake site.** Don't use it.

### 1. Install LocalDevVPN and connect it

1. Install **[LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)**
   from the App Store.
2. Open it and tap **Connect**. The first time, iOS asks to **Allow** adding a
   VPN configuration. Allow it and enter your passcode.

Leave it connected while you install, and whenever you want SideStore to
install, update or refresh apps.

### 2. Install SideInstaller

1. In **Safari** on the iPhone, open **https://sideinstaller.net/**.
2. Install SideInstaller with **any of the certificates** listed there. If one
   fails or the app won't open, delete it and try another.
3. If iOS says **“Untrusted Enterprise Developer”** when you open it, go to
   **Settings → General → VPN & Device Management**, tap the developer listed
   there and tap **Trust**.

### 3. Let SideInstaller install SideStore

1. Make sure LocalDevVPN says **Connected**.
2. Open **SideInstaller** and sign in with your **Apple ID**. Type the 6-digit
   code if one appears. Your password stays on the phone.
3. Tap **Install SideStore**, and wait until it says it's done (usually well
   under a minute).
4. Trust your Apple ID and turn on Developer Mode, exactly as in
   [section 5](#5-let-the-iphone-open-it) (skip whatever you've already done).
5. Open **SideStore** and sign in with the **same Apple ID**. Go to **My Apps**
   and tap the **7 DAYS** button next to SideStore once, to finish its setup. If
   it asks to revoke or create a signing certificate, tap **Yes** or **Refresh
   Now**.

### 4. Install KultrDL with SideStore

1. In Safari on the iPhone, open
   **https://github.com/evropiani/KultrDL_iOS/releases/latest**, and under
   **Assets** tap **`KultrDL.ipa`**, then **Download**. It goes to the *Files*
   app, in *Downloads*.
2. With LocalDevVPN connected, open **SideStore → My Apps**, tap **+** in the
   top corner, and pick **`KultrDL.ipa`** from *Downloads*.
3. Wait until KultrDL shows up in the list, then open it from the home screen
   and continue with [Open KultrDL](#open-kultr).

### Refreshing and updating

- **Refreshing:** SideStore re-signs KultrDL in the background before the 7 days
  are up, as long as LocalDevVPN is connected. You can leave the VPN on all the
  time. To do it yourself, tap the **days** button next to KultrDL in
  **My Apps**.
- **Updating:** download the new `KultrDL.ipa` in Safari and install it with
  **+** again. Your servers, library, downloads and settings stay.
- **Or let SideStore tell you about updates:** add KultrDL's source once. In
  SideStore open **Sources**, tap **+**, and paste

  ```
  https://gist.githubusercontent.com/evropiani/6e3a3c18525a228d03924674430c4d48/raw/evropiani.json
  ```

  KultrDL then shows up under **Browse**, and SideStore offers each new version
  as an update. The same address works in AltStore.
- **Coming from a computer install?** Each tool names the app it installs a
  little differently, so SideStore may add a second KultrDL instead of updating
  the one Sideloadly or Impactor put there. Your data stays in the old one,
  so before you delete it, back up your library in KultrDL (Settings →
  Backup and reset) and restore it in the new one. Save downloads you want to
  keep from the Files app first.
- **Handy:** SideInstaller's **Tools** tab lists the apps on the phone signed
  with your Apple ID, and when each one expires.

The [limits of a free Apple ID](#limits-of-a-free-apple-id) still apply, and
SideStore counts as one of the 3 apps.

---

## Troubleshooting

### Sideloadly doesn't see my iPhone
- Unlock the iPhone and make sure you tapped **Trust**
  ([section 3](#3-connect-your-iphone)).
- Try a different cable or USB port. Many cheap cables only charge.
- **Windows:** make sure iTunes and iCloud came from **Apple's website**, not
  the Microsoft Store ([section 2](#on-windows)). Open iTunes once with the phone
  plugged in, then restart Sideloadly.

### Linux: Impactor doesn't see my iPhone
- Unlock the phone, **plug it in first, then (re)start Impactor.** On some
  distributions `usbmuxd` stops when no iPhone is connected and only starts
  again when one is plugged in, so Impactor, if already open, may miss it.
- Check the connection with `idevice_id -l`. If that prints nothing, try
  another cable or USB port, then run `sudo systemctl restart usbmuxd` and plug
  the phone in again.
- If the phone never asked **“Trust This Computer?”**, run `idevicepair pair`
  with the phone unlocked and tap **Trust**.
- Still nothing? Make sure `usbmuxd` is installed
  ([section 2, Linux](#on-linux)) and restart the computer.

### “Untrusted Developer” when opening KultrDL
You skipped **Trust your own Apple ID**. Go to Settings → General →
VPN & Device Management and trust your Apple ID.

### “Developer Mode required” / KultrDL won't open at all
Turn on **Developer Mode** (Settings → Privacy & Security → Developer Mode) and
restart the phone.

### KultrDL opened fine for a week, and now it won't
The 7 days are up. Refresh it ([section 6](#6-keeping-kultrdl-working-the-7-day-rule)).

### “Maximum number of apps” or “App ID limit reached”
A free Apple ID can have 3 sideloaded apps at once and create 10 app IDs a
week. Delete a sideloaded app you no longer use, or wait a few days.

### The tool asks for my password again and again, or says the login failed
- Check that you can sign in at https://account.apple.com with the same email
  and password.
- If you use two-factor authentication, type the 6-digit code as soon as it
  appears on your iPhone.
- **Mac:** make sure Sideloadly's Mail plug-in is enabled (Mail → Settings →
  General → Manage Plug-ins), then restart Sideloadly.

### KultrDL can't connect to my FTP or SFTP server
- Use **Test connection** in the server's settings: it says what went wrong.
- A server at home (for example `192.168.1.20`) only works while the iPhone
  is on your home Wi-Fi, and only when KultrDL may *find devices on your
  local network* (Settings → Privacy & Security → Local Network → KultrDL).
- For SFTP with an RSA key, the server must still accept `ssh-rsa`
  signatures; Ed25519 and ECDSA keys work everywhere.

### YouTube refuses songs, or everything fails to play
- Settings → Engine → **Check for updates now**, then **Test YouTube**. The
  test tries every way of asking YouTube and keeps the one that works on
  your network; **Copy report** gives you something to paste into an issue.

### Music stops when I lock the phone
It shouldn't. KultrDL plays in the background like any music app. Check that
you're on the latest KultrDL release, and tell us if it keeps happening.

### SideStore or SideInstaller can't reach the iPhone, or an install hangs
- Open LocalDevVPN and check it says **Connected**. Disconnect and connect it
  again if it doesn't help.
- Other VPNs (work, privacy or ad-blocking VPNs) can't run at the same time.
  Turn them off while you install or refresh.
- Be on Wi-Fi for the first setup.
- On iOS 18 to 26 without a pairing file, this can't work. See the table in
  [*Without a computer*](#without-a-computer-sideinstaller-and-localdevvpn).

### Still stuck?
Open an issue at https://github.com/evropiani/KultrDL_iOS/issues, or ask on
[Discord (@evropiani)](https://discord.com/users/319246364246540288).

---

## Other ways to install

- **AltStore (Classic)** (Windows and Mac): works much like Sideloadly. You
  install *AltServer* on a computer, which puts the *AltStore* app on your
  iPhone. AltStore can then refresh KultrDL over Wi-Fi by itself while the
  computer is on. Instructions: https://altstore.io. In AltStore, open the
  **My Apps** tab, tap **+** and pick `KultrDL.ipa` (save it to the iPhone's
  *Files* app first).
- **Xcode on a Mac**: developers can open `KultrDL.xcodeproj`, choose their own
  team under *Signing & Capabilities*, and run it on a connected iPhone.
  See [Building](../README.md#building).
