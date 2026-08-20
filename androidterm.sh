#!/bin/bash
#
# androidterm.sh — interactive terminal session for pulling and pushing
# APKs to/from a connected Android device via adb. One device/profile
# selection per session; pull and push both live in the same main menu.
# Styled after old green-phosphor terminal computers.
#
# Usage: ./androidterm.sh
#
set -uo pipefail

# ---------------------------------------------------------------------------
# theme
# ---------------------------------------------------------------------------
TERM="${TERM:-xterm}"
C_RESET=$(tput sgr0 2>/dev/null)
C_GREEN=$(tput setaf 2 2>/dev/null)
C_BGREEN="$(tput bold 2>/dev/null)$(tput setaf 2 2>/dev/null)"
C_DIM=$(tput dim 2>/dev/null)
C_DIMGREEN="$(tput dim 2>/dev/null)$(tput setaf 2 2>/dev/null)"
C_REV=$(tput rev 2>/dev/null)
TERM_LINES=$(tput lines 2>/dev/null); TERM_LINES=${TERM_LINES:-24}

# ---------------------------------------------------------------------------
# paths / runtime state
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
APPS_DIR="$SCRIPT_DIR/apps"

CURRENT_DEVICE=""
CURRENT_DEVICE_LABEL=""
DEVICE_SERIALS=()
DEVICE_LABELS=()

TARGET_USER=""
TARGET_USER_LABEL=""
PROFILE_IDS=()
PROFILE_LABELS=()

PKG_SCOPE="user"   # "user" (3rd-party only) or "all"

DEP_ADB_FOUND=0; DEP_ADB_PATH=""
DEP_FZF_FOUND=0; DEP_FZF_PATH=""
AAPT_BIN=""

INSTALLED_FOR_PROFILE_CACHE=""

# ---------------------------------------------------------------------------
# low-level helpers
# ---------------------------------------------------------------------------
cleanup() {
    tput cnorm 2>/dev/null
    printf '%s' "$C_RESET"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

pause() {
    printf '\n%s[ press any key to continue ]%s' "$C_DIM" "$C_RESET"
    IFS= read -rsn1 -t 600 _ || true
    printf '\n'
}

type_out() {
    local text="$1" delay="${2:-0.012}" i
    for (( i=0; i<${#text}; i++ )); do
        printf '%s' "${text:$i:1}"
        sleep "$delay"
    done
    printf '\n'
}

log_line() { printf '%s%-46s%s' "$C_GREEN" "$1" "$C_RESET"; }
ok()   { printf '%s[ OK ]%s\n' "$C_BGREEN" "$C_RESET"; }
fail() { printf '%s[FAIL]%s\n' "$C_DIM" "$C_RESET"; }

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------
banner() {
    local width=68
    local title="ANDROID TERMLINK"
    local subtitle="rev 3.0 — pull / push unit"
    local pad_t=$(( (width - ${#title}) / 2 ))
    local pad_t2=$(( width - pad_t - ${#title} ))
    local pad_s=$(( (width - ${#subtitle}) / 2 ))
    local pad_s2=$(( width - pad_s - ${#subtitle} ))

    printf '%s' "$C_BGREEN"
    printf '   ┌'; printf -- '─%.0s' $(seq 1 "$width"); printf '┐\n'
    printf '   │%*s%s%*s│\n' "$pad_t" '' "$title" "$pad_t2" ''
    printf '   │%*s%s%*s│\n' "$pad_s" '' "$subtitle" "$pad_s2" ''
    printf '   └'; printf -- '─%.0s' $(seq 1 "$width"); printf '┘\n'
    printf '%s' "$C_RESET"
}

# ---------------------------------------------------------------------------
# generic arrow-key menu
#
# menu_select HEADER ARRAYNAME RESULTVAR
# Draws ARRAYNAME as a vertical list navigable with arrow keys (or j/k).
# On Enter, stores the chosen 0-based index into RESULTVAR and returns 0.
# On Esc/q, returns 1 and leaves RESULTVAR untouched.
# ---------------------------------------------------------------------------
menu_select() {
    local header="$1"
    local -n _mi_items="$2"
    local -n _mi_result="$3"
    local count=${#_mi_items[@]}
    local sel=0 key rest lines
    [ "$count" -eq 0 ] && return 1
    lines=$count
    [ -n "$header" ] && lines=$((lines + 1))

    _mi_draw() {
        local j
        if [ -n "$header" ]; then
            tput el; printf '%s%s%s\n' "$C_BGREEN" "$header" "$C_RESET"
        fi
        for ((j=0; j<count; j++)); do
            tput el
            if [ "$j" -eq "$sel" ]; then
                printf '%s%s > %s%s\n' "$C_REV" "$C_BGREEN" "${_mi_items[$j]}" "$C_RESET"
            else
                printf '   %s%s%s\n' "$C_GREEN" "${_mi_items[$j]}" "$C_RESET"
            fi
        done
    }

    tput civis
    _mi_draw
    while true; do
        if ! IFS= read -rsn1 key; then
            # stdin closed (EOF) — nothing more will ever arrive; without
            # this check the loop would spin forever re-reading instant
            # EOF and misreading it as Enter.
            printf '\n%sInput closed — exiting.%s\n' "$C_DIM" "$C_RESET"
            exit 1
        fi
        if [ "$key" = $'\x1b' ]; then
            IFS= read -rsn2 -t 0.05 rest
            key+="$rest"
        fi
        case "$key" in
            $'\x1b[A'|k) sel=$(( (sel - 1 + count) % count )); tput cuu "$lines"; _mi_draw ;;
            $'\x1b[B'|j) sel=$(( (sel + 1) % count )); tput cuu "$lines"; _mi_draw ;;
            "")
                _mi_result=$sel
                tput cnorm
                unset -f _mi_draw
                return 0
                ;;
            q|$'\x1b')
                tput cnorm
                unset -f _mi_draw
                return 1
                ;;
        esac
    done
}

# confirm_yes_no PROMPT — arrow-driven Yes/No, returns 0 for yes.
confirm_yes_no() {
    local prompt="$1"
    local -a opts=("Yes" "No")
    local idx
    menu_select "$prompt" opts idx && [ "$idx" -eq 0 ]
}

# ---------------------------------------------------------------------------
# fallback picker for when fzf isn't installed: paginated + type-to-filter
#
# paginated_picker HEADER ARRAYNAME RESULTVAR
# ---------------------------------------------------------------------------
paginated_picker() {
    local header="$1"
    local -n _pp_all="$2"
    local -n _pp_result="$3"
    local filter="" sel=0 offset=0 key rest i
    local page_size=$(( TERM_LINES - 8 ))
    [ "$page_size" -lt 5 ] && page_size=5
    local -a filtered=()

    _pp_filter() {
        filtered=()
        if [ -z "$filter" ]; then
            filtered=("${_pp_all[@]}")
        else
            for i in "${_pp_all[@]}"; do
                [[ "$i" == *"$filter"* ]] && filtered+=("$i")
            done
        fi
        [ "$sel" -ge "${#filtered[@]}" ] && sel=0
        offset=0
    }

    _pp_draw() {
        clear
        banner
        printf '\n%s%s%s\n' "$C_BGREEN" "$header" "$C_RESET"
        printf '%sfilter:%s %s%s_%s\n\n' "$C_DIM" "$C_RESET" "$C_GREEN" "$filter" "$C_RESET"
        for ((i=offset; i<${#filtered[@]} && i<offset+page_size; i++)); do
            if [ "$i" -eq "$sel" ]; then
                printf '%s%s > %s%s\n' "$C_REV" "$C_BGREEN" "${filtered[$i]}" "$C_RESET"
            else
                printf '   %s%s%s\n' "$C_GREEN" "${filtered[$i]}" "$C_RESET"
            fi
        done
        printf '\n%s[ %d / %d ]  arrows: move   type: filter   backspace: delete   enter: select   esc: cancel%s\n' \
            "$C_DIM" "$((${#filtered[@]} > 0 ? sel + 1 : 0))" "${#filtered[@]}" "$C_RESET"
    }

    _pp_filter
    tput civis
    _pp_draw
    while true; do
        if ! IFS= read -rsn1 key; then
            # stdin closed (EOF) — nothing more will ever arrive; without
            # this check the loop would spin forever re-reading instant
            # EOF and misreading it as Enter.
            printf '\n%sInput closed — exiting.%s\n' "$C_DIM" "$C_RESET"
            exit 1
        fi
        if [ "$key" = $'\x1b' ]; then
            IFS= read -rsn2 -t 0.05 rest
            key+="$rest"
        fi
        case "$key" in
            $'\x1b[A')
                [ "${#filtered[@]}" -gt 0 ] && sel=$(( (sel - 1 + ${#filtered[@]}) % ${#filtered[@]} ))
                ;;
            $'\x1b[B')
                [ "${#filtered[@]}" -gt 0 ] && sel=$(( (sel + 1) % ${#filtered[@]} ))
                ;;
            $'\x7f'|$'\x08')
                filter="${filter%?}"
                _pp_filter
                ;;
            "")
                if [ "${#filtered[@]}" -gt 0 ]; then
                    _pp_result="${filtered[$sel]}"
                    tput cnorm
                    unset -f _pp_filter _pp_draw
                    return 0
                fi
                ;;
            $'\x1b')
                tput cnorm
                unset -f _pp_filter _pp_draw
                return 1
                ;;
            *)
                [ -n "$key" ] && { filter+="$key"; _pp_filter; }
                ;;
        esac
        [ "$sel" -lt "$offset" ] && offset=$sel
        [ "$sel" -ge $((offset + page_size)) ] && offset=$(( sel - page_size + 1 ))
        _pp_draw
    done
}

# ---------------------------------------------------------------------------
# dependencies
#
# adb is required for everything and is checked before the UI even boots.
# fzf and aapt/aapt2 are optional "add-ons": each unlocks a nicer feature
# but everything still works, just in a plainer way, without them. Status
# is surfaced as an unintrusive line on the main menu, plus a full-detail
# screen on demand.
# ---------------------------------------------------------------------------
detect_aapt() {
    if command -v aapt2 &>/dev/null; then AAPT_BIN=$(command -v aapt2); return; fi
    if command -v aapt &>/dev/null; then AAPT_BIN=$(command -v aapt); return; fi
    local root cand
    for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
        [ -n "$root" ] && [ -d "$root/build-tools" ] || continue
        cand=$(ls -d "$root"/build-tools/*/ 2>/dev/null | sort -V | tail -1)
        [ -n "$cand" ] || continue
        if [ -x "${cand}aapt2" ]; then AAPT_BIN="${cand}aapt2"; return; fi
        if [ -x "${cand}aapt" ]; then AAPT_BIN="${cand}aapt"; return; fi
    done
    AAPT_BIN=""
}
have_aapt() { [ -n "$AAPT_BIN" ]; }

detect_deps() {
    if command -v adb &>/dev/null; then DEP_ADB_FOUND=1; DEP_ADB_PATH=$(command -v adb); fi
    if command -v fzf &>/dev/null; then DEP_FZF_FOUND=1; DEP_FZF_PATH=$(command -v fzf); fi
    detect_aapt
}

deps_summary_line() {
    local fzf_tag aapt_tag
    [ "$DEP_FZF_FOUND" -eq 1 ] && fzf_tag="✓" || fzf_tag="✗"
    have_aapt && aapt_tag="✓" || aapt_tag="✗"
    printf 'MODULES   fzf %s    aapt/aapt2 %s   (see "System upgrades" for details)' "$fzf_tag" "$aapt_tag"
}

deps_screen() {
    clear; banner
    printf '\n%sSYSTEM UPGRADES%s\n' "$C_BGREEN" "$C_RESET"
    printf '%soptional modules detected on this machine that extend TERMLINK capability.%s\n\n' "$C_DIM" "$C_RESET"

    printf '%sADB%s                   [ CORE — REQUIRED ]  ' "$C_GREEN" "$C_RESET"
    if [ "$DEP_ADB_FOUND" -eq 1 ]; then printf '%sINSTALLED%s\n' "$C_BGREEN" "$C_RESET"; else printf '%sMISSING%s\n' "$C_DIM" "$C_RESET"; fi
    if [ "$DEP_ADB_FOUND" -eq 1 ]; then printf '   %slocation: %s%s\n' "$C_DIM" "$DEP_ADB_PATH" "$C_RESET"; fi
    printf '   %sbenefit: powers the TERMLINK itself — device scan, pull, push, everything.%s\n\n' "$C_DIM" "$C_RESET"

    printf '%sFZF MODULE%s            [ optional upgrade ]  ' "$C_GREEN" "$C_RESET"
    if [ "$DEP_FZF_FOUND" -eq 1 ]; then printf '%sINSTALLED%s\n' "$C_BGREEN" "$C_RESET"; else printf '%sNOT DETECTED%s\n' "$C_DIM" "$C_RESET"; fi
    if [ "$DEP_FZF_FOUND" -eq 1 ]; then printf '   %slocation: %s%s\n' "$C_DIM" "$DEP_FZF_PATH" "$C_RESET"; fi
    printf '   %sbenefit: fast fuzzy-search picker for long package lists.\n' "$C_DIM"
    printf '   without it: TERMLINK falls back to a built-in paginated picker — slower to\n'
    printf '   browse, but fully functional.%s\n\n' "$C_RESET"

    printf '%sAAPT MODULE%s           [ optional upgrade ]  ' "$C_GREEN" "$C_RESET"
    if have_aapt; then printf '%sINSTALLED%s\n' "$C_BGREEN" "$C_RESET"; else printf '%sNOT DETECTED%s\n' "$C_DIM" "$C_RESET"; fi
    if have_aapt; then printf '   %slocation: %s%s\n' "$C_DIM" "$AAPT_BIN" "$C_RESET"; fi
    printf '   %sbenefit: reads version info out of local APKs, so the push menu can show\n' "$C_DIM"
    printf '   NEW / UPGRADE / DOWNGRADE / up-to-date at a glance before you commit.\n'
    printf '   without it: push still works, version comparisons are just skipped.\n'
    printf '   acquire via: Android SDK build-tools (Android Studio SDK Manager, or e.g.\n'
    printf '   pacman -S android-sdk-build-tools / apt install android-sdk-build-tools).%s\n' "$C_RESET"
}

# ---------------------------------------------------------------------------
# devices
# ---------------------------------------------------------------------------
refresh_devices() {
    DEVICE_SERIALS=()
    DEVICE_LABELS=()
    local serial state rest model
    while read -r serial state rest; do
        [ -z "$serial" ] && continue
        DEVICE_SERIALS+=("$serial")
        model=$(grep -o 'model:[^ ]*' <<<"$rest" | cut -d: -f2 | tr '_' ' ')
        [ -z "$model" ] && model="unknown model"
        if [ "$state" = "device" ]; then
            DEVICE_LABELS+=("$(printf '%-22s [online]  %s' "$serial" "$model")")
        else
            DEVICE_LABELS+=("$(printf '%-22s [%s]' "$serial" "$state")")
        fi
    done < <(adb devices -l 2>/dev/null | tail -n +2)
}

# Picks a device: auto-picks if exactly one, prompts with an arrow menu if
# several, reports and returns 1 if none. Sets CURRENT_DEVICE(_LABEL).
select_device() {
    refresh_devices
    local n=${#DEVICE_SERIALS[@]}
    if [ "$n" -eq 0 ]; then
        printf '\n%sNo devices detected. Plug in a device (USB debugging enabled) and retry.%s\n' "$C_GREEN" "$C_RESET"
        return 1
    elif [ "$n" -eq 1 ]; then
        CURRENT_DEVICE="${DEVICE_SERIALS[0]}"
        CURRENT_DEVICE_LABEL="${DEVICE_LABELS[0]}"
        printf '\n%sOne device found — using %s%s\n' "$C_GREEN" "$CURRENT_DEVICE_LABEL" "$C_RESET"
        return 0
    else
        printf '\n%s%d devices detected — select one:%s\n\n' "$C_GREEN" "$n" "$C_RESET"
        local idx
        if menu_select "" DEVICE_LABELS idx; then
            CURRENT_DEVICE="${DEVICE_SERIALS[$idx]}"
            CURRENT_DEVICE_LABEL="${DEVICE_LABELS[$idx]}"
            printf '\n%sUsing device: %s%s\n' "$C_GREEN" "$CURRENT_DEVICE_LABEL" "$C_RESET"
            return 0
        else
            return 1
        fi
    fi
}

show_devices() {
    refresh_devices
    if [ "${#DEVICE_SERIALS[@]}" -eq 0 ]; then
        printf '%sNo devices detected.%s\n' "$C_GREEN" "$C_RESET"
        return
    fi
    printf '%sCONNECTED DEVICES:%s\n\n' "$C_GREEN" "$C_RESET"
    local label
    for label in "${DEVICE_LABELS[@]}"; do
        printf '  %s\n' "$label"
    done
}

# Re-validates that the previously selected device is still actually
# connected (handles swapping hardware mid-session) before falling back
# to picking one if needed. A stale/vanished device clears the profile
# selection too, since profile ids are device-specific.
require_device() {
    if [ -n "$CURRENT_DEVICE" ]; then
        refresh_devices
        local d found=0
        for d in "${DEVICE_SERIALS[@]}"; do
            [ "$d" = "$CURRENT_DEVICE" ] && { found=1; break; }
        done
        if [ "$found" -eq 0 ]; then
            printf '\n%sPreviously selected device (%s) is no longer connected.%s\n' "$C_GREEN" "$CURRENT_DEVICE" "$C_RESET"
            CURRENT_DEVICE=""
            CURRENT_DEVICE_LABEL=""
            TARGET_USER=""
            TARGET_USER_LABEL=""
        fi
    fi
    if [ -z "$CURRENT_DEVICE" ]; then
        printf '\n%sScanning for devices...%s\n' "$C_GREEN" "$C_RESET"
        select_device
    fi
    [ -n "$CURRENT_DEVICE" ]
}

# ---------------------------------------------------------------------------
# profiles (Android user profiles on the selected device)
# ---------------------------------------------------------------------------
refresh_profiles() {
    PROFILE_IDS=()
    PROFILE_LABELS=()
    local uid name
    while read -r uid name; do
        [ -z "$uid" ] && continue
        PROFILE_IDS+=("$uid")
        PROFILE_LABELS+=("$(printf '[%s] %s' "$uid" "$name")")
    done < <(adb -s "$CURRENT_DEVICE" shell pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9]*\):\([^:]*\).*/\1 \2/p' | tr -d '\r')
}

select_profile() {
    refresh_profiles
    local n=${#PROFILE_IDS[@]}
    if [ "$n" -eq 0 ]; then
        printf '\n%sCould not detect user profiles.%s\n' "$C_GREEN" "$C_RESET"
        return 1
    elif [ "$n" -eq 1 ]; then
        TARGET_USER="${PROFILE_IDS[0]}"
        TARGET_USER_LABEL="${PROFILE_LABELS[0]}"
        printf '\n%sOne profile found — using %s%s\n' "$C_GREEN" "$TARGET_USER_LABEL" "$C_RESET"
        return 0
    else
        printf '\n%s%d profiles detected — select one:%s\n\n' "$C_GREEN" "$n" "$C_RESET"
        local idx
        if menu_select "" PROFILE_LABELS idx; then
            TARGET_USER="${PROFILE_IDS[$idx]}"
            TARGET_USER_LABEL="${PROFILE_LABELS[$idx]}"
            printf '\n%sUsing profile: %s%s\n' "$C_GREEN" "$TARGET_USER_LABEL" "$C_RESET"
            return 0
        else
            return 1
        fi
    fi
}

require_profile() {
    if [ -z "$TARGET_USER" ]; then
        select_profile
    fi
    [ -n "$TARGET_USER" ]
}

device_profile_menu() {
    local -a items=("Show devices" "Change device" "Change profile" "Back")
    local idx
    while true; do
        clear; banner
        printf '\n%sDEVICE:%s  %s\n' "$C_DIM" "$C_RESET" "${CURRENT_DEVICE_LABEL:-none selected}"
        printf '%sPROFILE:%s %s\n\n' "$C_DIM" "$C_RESET" "${TARGET_USER_LABEL:-none selected}"
        if ! menu_select "DEVICE & PROFILE" items idx; then
            return
        fi
        case "$idx" in
            0) clear; banner; printf '\n'; show_devices; pause ;;
            1)
                clear; banner
                if select_device; then
                    TARGET_USER=""
                    TARGET_USER_LABEL=""
                    select_profile
                fi
                pause
                ;;
            2)
                clear; banner
                if [ -z "$CURRENT_DEVICE" ]; then
                    printf '\n%sSelect a device first.%s\n' "$C_GREEN" "$C_RESET"
                else
                    select_profile
                fi
                pause
                ;;
            3) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# pull
# ---------------------------------------------------------------------------
get_packages() {
    local flag=""
    [ "$PKG_SCOPE" = "user" ] && flag="-3"
    adb -s "$CURRENT_DEVICE" shell pm list packages $flag 2>/dev/null \
        | sed 's/^package://' | tr -d '\r' | sort
}

toggle_scope() {
    if [ "$PKG_SCOPE" = "user" ]; then PKG_SCOPE="all"; else PKG_SCOPE="user"; fi
    clear; banner
    printf '\n%sPackage scope set to: %s%s\n' "$C_GREEN" "$PKG_SCOPE" "$C_RESET"
    pause
}

list_installed() {
    clear; banner
    if ! require_device; then pause; return; fi
    printf '\n%sFetching package list from device...%s\n' "$C_DIM" "$C_RESET"
    local -a packages
    mapfile -t packages < <(get_packages)
    if [ "${#packages[@]}" -eq 0 ]; then
        printf '%sNo packages found (or device disconnected).%s\n' "$C_GREEN" "$C_RESET"
        pause
        return
    fi
    if [ "$DEP_FZF_FOUND" -eq 1 ]; then
        printf '%s\n' "${packages[@]}" | fzf --prompt="BROWSE> " --height=90% \
            --color=bg+:-1,fg+:2,bg:-1,fg:2,hl:2,hl+:2,pointer:2,marker:2,border:2,prompt:2,info:2 \
            --header="installed packages ($PKG_SCOPE) — esc to return" >/dev/null
    else
        local dummy
        paginated_picker "INSTALLED PACKAGES ($PKG_SCOPE) — esc to return" packages dummy
    fi
}

select_and_pull() {
    clear; banner
    if ! require_device; then pause; return; fi
    printf '\n%sFetching package list from device...%s\n' "$C_DIM" "$C_RESET"
    local -a packages
    local chosen=""
    mapfile -t packages < <(get_packages)
    if [ "${#packages[@]}" -eq 0 ]; then
        printf '%sNo packages found (or device disconnected).%s\n' "$C_GREEN" "$C_RESET"
        pause
        return
    fi
    if [ "$DEP_FZF_FOUND" -eq 1 ]; then
        chosen=$(printf '%s\n' "${packages[@]}" | fzf --prompt="PULL> " --height=90% \
            --color=bg+:-1,fg+:2,bg:-1,fg:2,hl:2,hl+:2,pointer:2,marker:2,border:2,prompt:2,info:2 \
            --header="select a package to pull ($PKG_SCOPE)")
    else
        paginated_picker "SELECT PROGRAM TO PULL ($PKG_SCOPE)" packages chosen
    fi
    [ -z "$chosen" ] && return
    clear; banner
    pull_package "$chosen"
    pause
}

# pull_one REMOTE_PATH LOCAL_DEST
# Runs `adb pull` but swallows its raw (uncolored, verbose) status line —
# on success we print our own short, dim, indented confirmation instead;
# on failure we surface adb's actual output so errors stay diagnosable.
pull_one() {
    local remote="$1" dest="$2" out status
    out=$(adb -s "$CURRENT_DEVICE" pull "$remote" "$dest" 2>&1)
    status=$?
    if [ "$status" -eq 0 ]; then
        printf '     %s↳ pulled %s%s\n' "$C_DIMGREEN" "$(basename "$remote")" "$C_RESET"
    else
        printf '     %s↳ FAILED: %s%s\n' "$C_DIM" "$out" "$C_RESET"
    fi
    return "$status"
}

pull_package() {
    local pkg="$1"
    local dest="$APPS_DIR/$pkg"
    mkdir -p "$dest"

    printf '\n%sLocating package: %s%s\n' "$C_GREEN" "$pkg" "$C_RESET"
    local paths
    paths=$(adb -s "$CURRENT_DEVICE" shell pm path "$pkg" 2>/dev/null | sed 's/^package://' | tr -d '\r')

    if [ -z "$paths" ]; then
        printf '%sPackage "%s" not found on device.%s\n' "$C_GREEN" "$pkg" "$C_RESET"
        return 1
    fi

    local count
    count=$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l)

    if [ "$count" -eq 1 ]; then
        printf '%sSingle APK detected, pulling...%s\n' "$C_GREEN" "$C_RESET"
        pull_one "$paths" "$dest/$pkg.apk"
    else
        printf '%sSplit APKs detected (%s files), pulling...%s\n' "$C_GREEN" "$count" "$C_RESET"
        local apk
        while IFS= read -r apk; do
            [ -z "$apk" ] && continue
            pull_one "$apk" "$dest/"
        done <<< "$paths"
    fi

    printf '%sDone. Files saved to %s/%s\n' "$C_GREEN" "$dest" "$C_RESET"
}

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------

# pick_base_apk DIR — best-effort pick of the "main" apk in a split-apk
# directory, for version parsing purposes only (the push itself always
# installs every .apk in the directory together).
pick_base_apk() {
    local dir="$1" f
    if [ -f "$dir/base.apk" ]; then printf '%s\n' "$dir/base.apk"; return 0; fi
    local -a apks=("$dir"/*.apk)
    [ -e "${apks[0]}" ] || return 1
    if [ "${#apks[@]}" -eq 1 ]; then printf '%s\n' "${apks[0]}"; return 0; fi
    for f in "${apks[@]}"; do
        [[ "$(basename "$f")" == *base* ]] && { printf '%s\n' "$f"; return 0; }
    done
    printf '%s\n' "${apks[0]}"
}

# apk_version APK — prints "versionName versionCode" (space separated),
# using aapt2/aapt. "?" / "0" if unavailable or unparseable.
apk_version() {
    local apk="$1" out vername vercode
    out=$("$AAPT_BIN" dump badging "$apk" 2>/dev/null)
    vername=$(grep -m1 -oE "versionName='[^']*'" <<<"$out" | sed "s/versionName='//; s/'//")
    vercode=$(grep -m1 -oE "versionCode='[0-9]*'" <<<"$out" | sed "s/versionCode='//; s/'//")
    printf '%s %s\n' "${vername:-?}" "${vercode:-0}"
}

# get_pkg_status PKG — sets STATUS_KIND, STATUS_TEXT (plain, uncolored —
# safe to embed directly in a menu_select row), STATUS_DEV_VER,
# STATUS_LOCAL_VER.
get_pkg_status() {
    local pkg="$1"
    local apkdir="$APPS_DIR/$pkg" base_apk="" local_ver="" local_code=""
    base_apk=$(pick_base_apk "$apkdir") || true
    if [ -n "$base_apk" ] && have_aapt; then
        read -r local_ver local_code < <(apk_version "$base_apk")
    fi

    local dev_out dev_code dev_ver on_profile=0
    dev_out=$(adb -s "$CURRENT_DEVICE" shell dumpsys package "$pkg" 2>/dev/null)
    dev_code=$(grep -m1 -oE 'versionCode=[0-9]+' <<<"$dev_out" | cut -d= -f2)
    dev_ver=$(grep -m1 -oE 'versionName=[^ ]+' <<<"$dev_out" | cut -d= -f2)
    grep -qx "package:$pkg" <<<"$INSTALLED_FOR_PROFILE_CACHE" && on_profile=1

    STATUS_DEV_VER="${dev_ver:-}"
    STATUS_LOCAL_VER="${local_ver:-}"

    if [ -z "$dev_code" ]; then
        STATUS_KIND="NEW"
        if [ -n "$local_ver" ]; then STATUS_TEXT="NEW (local v$local_ver)"; else STATUS_TEXT="NEW"; fi
        return
    fi
    if [ "$on_profile" -eq 0 ]; then
        STATUS_KIND="NEW_FOR_PROFILE"
        STATUS_TEXT="NEW FOR PROFILE (on device: v$dev_ver)"
        return
    fi
    if [ -z "$local_code" ]; then
        STATUS_KIND="UNKNOWN"
        STATUS_TEXT="installed: v$dev_ver (local version unknown)"
        return
    fi
    if [ "$local_code" -gt "$dev_code" ]; then
        STATUS_KIND="UPGRADE"
        STATUS_TEXT="UPGRADE v$dev_ver -> v$local_ver"
    elif [ "$local_code" -eq "$dev_code" ]; then
        STATUS_KIND="SAME"
        STATUS_TEXT="up to date: v$dev_ver"
    else
        STATUS_KIND="DOWNGRADE"
        STATUS_TEXT="!DOWNGRADE v$dev_ver -> v$local_ver"
    fi
}

# colorize plain STATUS_TEXT for use outside a menu_select row (safe here
# since these calls aren't part of a highlighted/redrawn list item).
colorize_status() {
    local kind="$1" text="$2"
    case "$kind" in
        NEW|NEW_FOR_PROFILE|UPGRADE) printf '%s%s%s' "$C_BGREEN" "$text" "$C_RESET" ;;
        DOWNGRADE)                   printf '%s%s%s' "$C_REV" "$text" "$C_RESET" ;;
        *)                           printf '%s%s%s' "$C_DIM" "$text" "$C_RESET" ;;
    esac
}

PUSH_PKG_NAMES=()
PUSH_MENU_LABELS=()

build_push_menu() {
    local -a pkgs
    local d pkg
    pkgs=()
    for d in "$APPS_DIR"/*/; do
        [ -d "$d" ] || continue
        pkg="${d%/}"; pkg="${pkg##*/}"
        local -a apks=("$d"*.apk)
        [ -e "${apks[0]}" ] || continue
        pkgs+=("$pkg")
    done
    PUSH_PKG_NAMES=()
    PUSH_MENU_LABELS=()
    [ "${#pkgs[@]}" -eq 0 ] && return 1

    INSTALLED_FOR_PROFILE_CACHE=$(adb -s "$CURRENT_DEVICE" shell pm list packages --user "$TARGET_USER" 2>/dev/null | tr -d '\r')

    local maxlen=20 l
    for pkg in "${pkgs[@]}"; do
        l=${#pkg}
        [ "$l" -gt "$maxlen" ] && maxlen=$l
    done

    for pkg in "${pkgs[@]}"; do
        get_pkg_status "$pkg"
        PUSH_PKG_NAMES+=("$pkg")
        PUSH_MENU_LABELS+=("$(printf "%-${maxlen}s  [%s]" "$pkg" "$STATUS_TEXT")")
    done
    return 0
}

push_menu() {
    clear; banner
    if ! require_device; then pause; return; fi
    if ! require_profile; then pause; return; fi
    printf '\n%sScanning %s and querying device...%s\n' "$C_DIM" "$APPS_DIR" "$C_RESET"
    if ! build_push_menu; then
        printf '%sNo local APKs found under %s%s\n' "$C_GREEN" "$APPS_DIR" "$C_RESET"
        pause
        return
    fi
    local idx
    if ! menu_select "SELECT APP TO PUSH (profile: $TARGET_USER_LABEL) — esc to cancel" PUSH_MENU_LABELS idx; then
        return
    fi
    push_confirm_and_install "${PUSH_PKG_NAMES[$idx]}"
}

push_confirm_and_install() {
    local pkg="$1"
    local apkdir="$APPS_DIR/$pkg"
    local -a apks=("$apkdir"/*.apk)
    clear; banner
    printf '\n%sPACKAGE:%s %s\n' "$C_DIM" "$C_RESET" "$pkg"
    printf '%sFILES:%s\n' "$C_DIM" "$C_RESET"
    local f
    for f in "${apks[@]}"; do printf '  %s\n' "$(basename "$f")"; done

    get_pkg_status "$pkg"
    printf '\n%sSTATUS:%s %s\n' "$C_DIM" "$C_RESET" "$(colorize_status "$STATUS_KIND" "$STATUS_TEXT")"

    local -a extra_flags=()
    if [ "$STATUS_KIND" = "DOWNGRADE" ]; then
        printf '\n'
        if confirm_yes_no "This is a version downgrade. Include --downgrade flag?"; then
            extra_flags+=("-d")
        fi
    fi

    printf '\n'
    if ! confirm_yes_no "Push to profile $TARGET_USER_LABEL now?"; then
        printf '\n%sCancelled.%s\n' "$C_DIM" "$C_RESET"
        pause
        return
    fi

    local install_out
    if [ "${#apks[@]}" -eq 1 ]; then
        printf '\n%sInstalling single APK to user %s...%s\n' "$C_GREEN" "$TARGET_USER" "$C_RESET"
        install_out=$(adb -s "$CURRENT_DEVICE" install -r "${extra_flags[@]}" --user "$TARGET_USER" "${apks[0]}" 2>&1)
    else
        printf '\n%sInstalling split APKs (%d files) to user %s...%s\n' "$C_GREEN" "${#apks[@]}" "$TARGET_USER" "$C_RESET"
        install_out=$(adb -s "$CURRENT_DEVICE" install-multiple -r "${extra_flags[@]}" --user "$TARGET_USER" "${apks[@]}" 2>&1)
    fi

    if [[ "$install_out" == *Success* ]]; then
        printf '     %s↳ %s%s\n' "$C_DIMGREEN" "$install_out" "$C_RESET"
        printf '%sDone.%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '     %s↳ %s%s\n' "$C_DIM" "$install_out" "$C_RESET"
        printf '%sInstall failed.%s\n' "$C_GREEN" "$C_RESET"
    fi
    pause
}

# ---------------------------------------------------------------------------
# boot sequence + main menu
# ---------------------------------------------------------------------------
boot_sequence() {
    clear
    banner
    printf '\n'
    type_out "  ANDROID PACKAGE PULL/PUSH TERMINAL — REV 3.0" 0.008
    sleep 0.15
    printf '\n'

    log_line "  ESTABLISHING TERMLINK (adb start-server)"
    if adb start-server &>/dev/null; then ok; else fail; fi
    sleep 0.1

    printf '\n%sSCANNING FOR DEVICES...%s\n' "$C_DIM" "$C_RESET"
    if select_device; then
        printf '\n%sSCANNING FOR PROFILES...%s\n' "$C_DIM" "$C_RESET"
        select_profile
    fi
    sleep 0.2
}

MAIN_MENU_ITEMS=(
    "Device & profile"
    "List installed programs"
    "Pull a program"
    "Push a program"
    "Toggle package scope (currently: user)"
    "System upgrades"
    "Exit"
)

main_menu() {
    local idx
    while true; do
        MAIN_MENU_ITEMS[4]="Toggle package scope (currently: $PKG_SCOPE)"
        clear
        banner
        printf '\n%sDEVICE:%s  %s\n' "$C_DIM" "$C_RESET" "${CURRENT_DEVICE_LABEL:-none selected}"
        printf '%sPROFILE:%s %s\n' "$C_DIM" "$C_RESET" "${TARGET_USER_LABEL:-none selected}"
        printf '%s%s%s\n' "$C_DIM" "$(deps_summary_line)" "$C_RESET"
        printf '\n'
        if ! menu_select "MAIN MENU" MAIN_MENU_ITEMS idx; then
            idx=6
        fi
        case "$idx" in
            0) device_profile_menu ;;
            1) list_installed ;;
            2) select_and_pull ;;
            3) push_menu ;;
            4) toggle_scope ;;
            5) deps_screen; pause ;;
            6) clear; printf '%sTERMLINK SESSION CLOSED.%s\n' "$C_GREEN" "$C_RESET"; exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------
main() {
    detect_deps
    mkdir -p "$APPS_DIR"

    if [ "$DEP_ADB_FOUND" -ne 1 ]; then
        printf '%sTERMLINK CANNOT INITIALIZE — adb not found.%s\n' "$C_GREEN" "$C_RESET"
        printf '%sInstall Android platform-tools and add it to PATH, then try again.%s\n' "$C_GREEN" "$C_RESET"
        exit 1
    fi

    boot_sequence
    main_menu
}

main "$@"
