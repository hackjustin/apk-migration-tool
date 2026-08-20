# androidterm.sh — guided APK migration

A terminal tool for moving APKs where you want them: between two Android
phones, between a phone and your computer, or between two folders on
disk. The main flow, **Migrate APKs (guided)**, walks you through it —
pick a source, pick a destination, multi-select the apps, confirm once,
and it runs the whole batch unattended. Split-APK bundles (base + config
splits) are detected and handled automatically in every direction.

Source and destination can each be a connected Android device or the
local filesystem, covering all four combinations:

- **Device → device** — pulled to a temporary local staging folder, then
  installed on the destination (adb has no direct device-to-device path)
- **Device → filesystem** — pulled into a folder you choose
- **Filesystem → device** — installed from your local APK library
- **Filesystem → filesystem** — copied to another folder

No files are required as arguments — run the script and follow the
prompts. Every menu shows `esc/q: cancel`, which backs out one step at a
time, all the way to the main menu.

```
./androidterm.sh
```

## Requirements

**Bash 4.3+** and a real terminal (the UI reads raw keypresses and uses
`tput` for cursor control — both are standard on any Linux desktop/server
install).

**adb** (Android Debug Bridge) — required, this is what everything else is
built on.

| Distro family | Install |
|---|---|
| Debian / Ubuntu / Mint (`apt`) | `sudo apt install adb` |
| Arch / Manjaro (`pacman`) | `sudo pacman -S android-tools` (add `android-udev` too if USB access needs help) |
| Fedora (`dnf`) | `sudo dnf install android-tools` |
| RHEL / CentOS / Rocky / Alma (`yum`) | `sudo yum install epel-release` first, then `sudo yum install android-tools` |
| openSUSE (`zypper`) | `sudo zypper install android-tools` |

On each device you want to use, enable **Developer options → USB
debugging**, then accept the "Allow USB debugging?" RSA-key prompt the
first time you plug it in — until you do, `adb devices` will list it as
`unauthorized` rather than `device`.

## Optional dependencies

Both are auto-detected at startup (see "System upgrades" in the main
menu for what was found). Neither is required — the script works fully
without them, just with a plainer picker and no version comparison.

**fzf** — fast fuzzy-search picker used for browsing/selecting packages,
including the migration wizard's multi-select (tab to mark several apks
at once). Without it, the script falls back to a built-in
paginated/type-to-filter picker that supports the same multi-select, just
with a plainer keyboard-driven UI instead of fuzzy search.

| Distro family | Install |
|---|---|
| Debian / Ubuntu (`apt`) | `sudo apt install fzf` |
| Arch (`pacman`) | `sudo pacman -S fzf` |
| Fedora (`dnf`) | `sudo dnf install fzf` |
| openSUSE (`zypper`) | `sudo zypper install fzf` |

**aapt / aapt2** — reads `versionName`/`versionCode` out of local APKs to
compare against what's already installed (NEW / UPGRADE / DOWNGRADE / up
to date), shown before a single-app push. The guided migration wizard
always installs with reinstall/upgrade semantics regardless of aapt's
presence. Not required either way; installs work the same without it.

| Distro family | Install |
|---|---|
| Debian / Ubuntu (`apt`) | `sudo apt install aapt` |
| Arch (AUR, needs a helper like `yay`/`paru`) | `yay -S android-sdk-build-tools` |
| Fedora / RHEL / openSUSE | no standalone package in the main repos — install via Android Studio's SDK Manager, or grab the [command-line tools](https://developer.android.com/studio#command-tools) and run `sdkmanager "build-tools;<version>"` |

The script also picks up `aapt`/`aapt2` automatically if it's sitting
under `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Android/Sdk`, or
`~/Library/Android/sdk` (i.e. a normal Android Studio install), even
without it being on `PATH`.

## Where files land

Pulled/local APKs live under `apps/<package-name>/` next to the script —
this is the library a filesystem-side migration reads from and writes
into by default (you can point a migration at any other folder when
prompted).
