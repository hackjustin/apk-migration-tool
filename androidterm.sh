#!/bin/bash
#
# androidterm.sh — interactive terminal session for migrating APKs
# to/from connected Android devices and the local filesystem via adb.
# The flagship flow is "Migrate APKs (guided)": pick a source, a
# destination, multi-select apks, and run the whole batch in one pass —
# device-to-device, device-to-filesystem, or filesystem-to-device.
# Manual single-package pull/push still exist underneath but are
# currently hidden from the main menu (temporary — see MAIN_MENU_ROWS).
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

MIGRATE_STAGE_DIR=""

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
    [ -n "$MIGRATE_STAGE_DIR" ] && rm -rf "$MIGRATE_STAGE_DIR" 2>/dev/null
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
    local subtitle="rev 4.0 — guided apk migration"
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
    lines=$((lines + 1))  # footer hint line, always drawn — keep in sync with _mi_draw

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
        tput el; printf '%s[ up/down or j/k: move   enter: select   esc/q: cancel ]%s\n' "$C_DIM" "$C_RESET"
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
# multi-select pickers — used by the migration wizard, which lets a user
# grab a batch of apks in one pass instead of one pull/push at a time.
# ---------------------------------------------------------------------------

# paginated_picker_multi HEADER ARRAYNAME RESULTARRAYNAME
# Same fallback picker as paginated_picker, but space/tab toggles a mark on
# the current line instead of selecting immediately. Enter confirms every
# marked item (in ARRAYNAME's original order); with nothing marked, Enter
# confirms just the highlighted line, so a single pick still works in one
# keystroke.
paginated_picker_multi() {
    local header="$1"
    local -n _pmm_all="$2"
    local -n _pmm_result="$3"
    local filter="" sel=0 offset=0 key rest i
    local page_size=$(( TERM_LINES - 9 ))
    [ "$page_size" -lt 5 ] && page_size=5
    local -a filtered=()
    local -A marked=()

    _pmm_filter() {
        filtered=()
        if [ -z "$filter" ]; then
            filtered=("${_pmm_all[@]}")
        else
            for i in "${_pmm_all[@]}"; do
                [[ "$i" == *"$filter"* ]] && filtered+=("$i")
            done
        fi
        [ "$sel" -ge "${#filtered[@]}" ] && sel=0
        offset=0
    }

    _pmm_draw() {
        clear
        banner
        printf '\n%s%s%s\n' "$C_BGREEN" "$header" "$C_RESET"
        printf '%sfilter:%s %s%s_%s   %s%d marked%s\n\n' \
            "$C_DIM" "$C_RESET" "$C_GREEN" "$filter" "$C_RESET" "$C_DIM" "${#marked[@]}" "$C_RESET"
        for ((i=offset; i<${#filtered[@]} && i<offset+page_size; i++)); do
            local mark=' '
            [ -n "${marked[${filtered[$i]}]+x}" ] && mark='x'
            if [ "$i" -eq "$sel" ]; then
                printf '%s%s > [%s] %s%s\n' "$C_REV" "$C_BGREEN" "$mark" "${filtered[$i]}" "$C_RESET"
            else
                printf '   %s[%s] %s%s\n' "$C_GREEN" "$mark" "${filtered[$i]}" "$C_RESET"
            fi
        done
        printf '\n%s[ %d / %d ]  arrows: move   space/tab: mark   type: filter   backspace: delete   enter: confirm   esc: cancel%s\n' \
            "$C_DIM" "$((${#filtered[@]} > 0 ? sel + 1 : 0))" "${#filtered[@]}" "$C_RESET"
    }

    _pmm_filter
    tput civis
    _pmm_draw
    while true; do
        if ! IFS= read -rsn1 key; then
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
            ' '|$'\t')
                if [ "${#filtered[@]}" -gt 0 ]; then
                    if [ -n "${marked[${filtered[$sel]}]+x}" ]; then
                        unset "marked[${filtered[$sel]}]"
                    else
                        marked["${filtered[$sel]}"]=1
                    fi
                fi
                ;;
            $'\x7f'|$'\x08')
                filter="${filter%?}"
                _pmm_filter
                ;;
            "")
                if [ "${#marked[@]}" -gt 0 ]; then
                    _pmm_result=()
                    for i in "${_pmm_all[@]}"; do
                        [ -n "${marked[$i]+x}" ] && _pmm_result+=("$i")
                    done
                    tput cnorm
                    unset -f _pmm_filter _pmm_draw
                    return 0
                elif [ "${#filtered[@]}" -gt 0 ]; then
                    _pmm_result=("${filtered[$sel]}")
                    tput cnorm
                    unset -f _pmm_filter _pmm_draw
                    return 0
                fi
                ;;
            $'\x1b')
                tput cnorm
                unset -f _pmm_filter _pmm_draw
                return 1
                ;;
            *)
                [ -n "$key" ] && { filter+="$key"; _pmm_filter; }
                ;;
        esac
        [ "$sel" -lt "$offset" ] && offset=$sel
        [ "$sel" -ge $((offset + page_size)) ] && offset=$(( sel - page_size + 1 ))
        _pmm_draw
    done
}

# pick_multi HEADER ARRAYNAME RESULTARRAYNAME
# Uses fzf --multi when available (tab marks a line, enter confirms all
# marked — or just the highlighted one if none were marked), otherwise
# falls back to paginated_picker_multi. RESULTARRAYNAME is set to the
# chosen items; returns 1 on an empty source list or a cancelled pick.
pick_multi() {
    local header="$1" arrname="$2"
    local -n _pm_arr="$arrname"
    local -n _pm_result="$3"
    _pm_result=()
    [ "${#_pm_arr[@]}" -eq 0 ] && return 1
    if [ "$DEP_FZF_FOUND" -eq 1 ]; then
        local out
        out=$(printf '%s\n' "${_pm_arr[@]}" | fzf --multi --prompt="MIGRATE> " --height=90% \
            --color=bg+:-1,fg+:2,bg:-1,fg:2,hl:2,hl+:2,pointer:2,marker:2,border:2,prompt:2,info:2 \
            --header="$header  (tab: mark multiple — enter: confirm — esc: cancel)")
        [ -z "$out" ] && return 1
        mapfile -t _pm_result <<< "$out"
        return 0
    else
        local -a picked=()
        paginated_picker_multi "$header" "$arrname" picked || return 1
        _pm_result=("${picked[@]}")
        return 0
    fi
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
    printf '   acquire via: Debian/Ubuntu: apt install aapt.  Arch: AUR package\n'
    printf '   android-sdk-build-tools (needs an AUR helper, e.g. yay -S ...).\n'
    printf '   Fedora/RHEL/openSUSE: no standalone repo package — use Android Studio'"'"'s\n'
    printf '   SDK Manager, or the command-line tools'"'"' sdkmanager "build-tools;<ver>".%s\n' "$C_RESET"
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
# Shown before an *implicit* multi-device pick (boot, or the first pull/push
# of a session) — an explicit "Change device" from the Device & profile menu
# skips it, since the user's intent is already clear there.
DEVICE_PICK_NOTE='This pick becomes your default working device. Change it anytime via "Device & profile" — or use "Migrate APKs (guided)" to choose source and destination devices independently.'

# select_device [NOTE] — NOTE, if given, is printed above the picker but
# only when there is actually a choice to make (2+ devices).
select_device() {
    local note="${1:-}"
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
        [ -n "$note" ] && printf '\n%s%s%s\n' "$C_DIM" "$note" "$C_RESET"
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

# pick_device_for HEADER OUT_SERIAL_VAR OUT_LABEL_VAR
# Same auto-pick/menu logic as select_device, but reports into caller-named
# variables instead of the global CURRENT_DEVICE. Used by the migration
# wizard, which juggles a source device and a destination device that may
# both be connected at once and must not stomp on each other (or on
# whatever device is "current" elsewhere in the app).
pick_device_for() {
    local header="$1"
    local -n _pdf_serial="$2"
    local -n _pdf_label="$3"
    refresh_devices
    local n=${#DEVICE_SERIALS[@]}
    if [ "$n" -eq 0 ]; then
        printf '\n%sNo devices detected. Plug in a device (USB debugging enabled) and retry.%s\n' "$C_GREEN" "$C_RESET"
        return 1
    elif [ "$n" -eq 1 ]; then
        _pdf_serial="${DEVICE_SERIALS[0]}"
        _pdf_label="${DEVICE_LABELS[0]}"
        printf '\n%sOne device found — using %s%s\n' "$C_GREEN" "$_pdf_label" "$C_RESET"
        return 0
    else
        printf '\n%s%s%s\n\n' "$C_GREEN" "$header" "$C_RESET"
        local idx
        if menu_select "" DEVICE_LABELS idx; then
            _pdf_serial="${DEVICE_SERIALS[$idx]}"
            _pdf_label="${DEVICE_LABELS[$idx]}"
            printf '\n%sUsing device: %s%s\n' "$C_GREEN" "$_pdf_label" "$C_RESET"
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
        select_device "$DEVICE_PICK_NOTE"
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

# pick_profile_for SERIAL OUT_ID_VAR OUT_LABEL_VAR
# Runs the normal select_profile flow against an arbitrary device serial
# (refresh_profiles reads CURRENT_DEVICE, so this swaps it in, reuses
# select_profile as-is, then restores whatever device/profile was
# "current" before the call). Used by the migration wizard to pick a
# destination profile without disturbing the app's own current
# device/profile selection.
pick_profile_for() {
    local serial="$1"
    local -n _ppf_id="$2"
    local -n _ppf_label="$3"
    local saved_device="$CURRENT_DEVICE" saved_user="$TARGET_USER" saved_label="$TARGET_USER_LABEL"
    CURRENT_DEVICE="$serial"
    TARGET_USER=""
    TARGET_USER_LABEL=""
    local rc=0
    select_profile || rc=1
    _ppf_id="$TARGET_USER"
    _ppf_label="$TARGET_USER_LABEL"
    CURRENT_DEVICE="$saved_device"
    TARGET_USER="$saved_user"
    TARGET_USER_LABEL="$saved_label"
    return "$rc"
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
get_packages() { get_packages_on "$CURRENT_DEVICE" "$PKG_SCOPE"; }

# get_packages_on SERIAL SCOPE [USER] — same as get_packages but for an
# arbitrary device serial and scope, so callers (e.g. the migration wizard)
# aren't tied to the globally-selected CURRENT_DEVICE/PKG_SCOPE. USER, if
# given, scopes the listing to that profile id (pm list packages --user);
# omitted, it lists whatever the adb shell's own default user sees, same as
# before this parameter existed.
get_packages_on() {
    local serial="$1" scope="$2" user="${3:-}" flag=""
    [ "$scope" = "user" ] && flag="-3"
    local -a cmd=(adb -s "$serial" shell pm list packages)
    [ -n "$flag" ] && cmd+=("$flag")
    [ -n "$user" ] && cmd+=(--user "$user")
    "${cmd[@]}" 2>/dev/null | sed 's/^package://' | tr -d '\r' | sort
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
    pull_package "$CURRENT_DEVICE" "$chosen" "$APPS_DIR/$chosen"
    pause
}

# pull_one SERIAL REMOTE_PATH LOCAL_DEST
# Runs `adb pull` but swallows its raw (uncolored, verbose) status line —
# on success we print our own short, dim, indented confirmation instead;
# on failure we surface adb's actual output so errors stay diagnosable.
pull_one() {
    local serial="$1" remote="$2" dest="$3" out status
    out=$(adb -s "$serial" pull "$remote" "$dest" 2>&1)
    status=$?
    if [ "$status" -eq 0 ]; then
        printf '     %s↳ pulled %s%s\n' "$C_DIMGREEN" "$(basename "$remote")" "$C_RESET"
    else
        printf '     %s↳ FAILED: %s%s\n' "$C_DIM" "$out" "$C_RESET"
    fi
    return "$status"
}

# pull_package SERIAL PKG DEST_DIR [USER] — pulls PKG off the device at
# SERIAL into DEST_DIR (created if needed). SERIAL/DEST_DIR are explicit
# rather than always CURRENT_DEVICE/APPS_DIR so the migration wizard can
# pull from whichever device the user picked as the source, into whichever
# directory the user picked as the destination. USER, if given, scopes
# `pm path` to that profile (same default-user behavior as before if
# omitted).
pull_package() {
    local serial="$1" pkg="$2" dest="$3" user="${4:-}"
    mkdir -p "$dest"

    printf '\n%sLocating package: %s%s\n' "$C_GREEN" "$pkg" "$C_RESET"
    local -a path_cmd=(adb -s "$serial" shell pm path)
    [ -n "$user" ] && path_cmd+=(--user "$user")
    path_cmd+=("$pkg")
    local paths
    paths=$("${path_cmd[@]}" 2>/dev/null | sed 's/^package://' | tr -d '\r')

    if [ -z "$paths" ]; then
        printf '%sPackage "%s" not found on device.%s\n' "$C_GREEN" "$pkg" "$C_RESET"
        return 1
    fi

    local count
    count=$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l)

    if [ "$count" -eq 1 ]; then
        printf '%sSingle APK detected, pulling...%s\n' "$C_GREEN" "$C_RESET"
        pull_one "$serial" "$paths" "$dest/$pkg.apk"
    else
        printf '%sSplit APKs detected (%s files), pulling...%s\n' "$C_GREEN" "$count" "$C_RESET"
        local apk
        while IFS= read -r apk; do
            [ -z "$apk" ] && continue
            pull_one "$serial" "$apk" "$dest/"
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

# list_local_packages — package names under APPS_DIR that have at least one
# .apk file, i.e. the local library the push menu (and the migration
# wizard's "local filesystem" source) both draw from.
list_local_packages() {
    local d pkg
    for d in "$APPS_DIR"/*/; do
        [ -d "$d" ] || continue
        pkg="${d%/}"; pkg="${pkg##*/}"
        local -a apks=("$d"*.apk)
        [ -e "${apks[0]}" ] || continue
        printf '%s\n' "$pkg"
    done
}

build_push_menu() {
    local -a pkgs
    local pkg
    mapfile -t pkgs < <(list_local_packages)
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
# migrate — guided, "ez mode" wizard for moving a batch of apks in one pass.
# Source and destination are each either a connected device or the local
# filesystem, covering all four combinations: device->device (staged
# through a temp dir on this machine, since adb can't talk device-to-
# device directly), device->local, local->device, local->local. The user
# picks source, destination, then any number of apks in one multi-select,
# confirms once, and the whole batch runs unattended.
# ---------------------------------------------------------------------------

# migrate_install SERIAL USER APKDIR [EXTRA_INSTALL_FLAGS...]
# Installs every .apk under APKDIR to USER on SERIAL. Unlike
# push_confirm_and_install this is non-interactive (no downgrade prompt) —
# it's meant to run unattended as part of a batch migration.
migrate_install() {
    local serial="$1" user="$2" apkdir="$3"
    shift 3
    local -a extra_flags=("$@")
    local -a apks=("$apkdir"/*.apk)
    if [ ! -e "${apks[0]}" ]; then
        printf '     %s↳ FAILED: no apk files found in %s%s\n' "$C_DIM" "$apkdir" "$C_RESET"
        return 1
    fi
    local install_out
    if [ "${#apks[@]}" -eq 1 ]; then
        install_out=$(adb -s "$serial" install -r "${extra_flags[@]}" --user "$user" "${apks[0]}" 2>&1)
    else
        install_out=$(adb -s "$serial" install-multiple -r "${extra_flags[@]}" --user "$user" "${apks[@]}" 2>&1)
    fi
    if [[ "$install_out" == *Success* ]]; then
        printf '     %s↳ installed%s\n' "$C_DIMGREEN" "$C_RESET"
        return 0
    else
        printf '     %s↳ FAILED: %s%s\n' "$C_DIM" "$install_out" "$C_RESET"
        return 1
    fi
}

# migrate_copy_local PKG DEST_ROOT — copies PKG's apk(s) from the local
# library (APPS_DIR/PKG) into DEST_ROOT/PKG, for local-filesystem ->
# local-filesystem migrations (e.g. exporting a batch to another drive).
migrate_copy_local() {
    local pkg="$1" destroot="$2"
    local srcdir="$APPS_DIR/$pkg" destdir="$destroot/$pkg"
    local -a apks=("$srcdir"/*.apk)
    if [ ! -e "${apks[0]}" ]; then
        printf '     %s↳ FAILED: no apk files found in %s%s\n' "$C_DIM" "$srcdir" "$C_RESET"
        return 1
    fi
    mkdir -p "$destdir"
    if [ "$(cd "$destdir" 2>/dev/null && pwd -P)" = "$(cd "$srcdir" 2>/dev/null && pwd -P)" ]; then
        printf '     %s↳ already at destination, skipping%s\n' "$C_DIM" "$C_RESET"
        return 0
    fi
    if cp -a "${apks[@]}" "$destdir/" 2>/dev/null; then
        printf '     %s↳ copied to %s%s\n' "$C_DIMGREEN" "$destdir" "$C_RESET"
        return 0
    else
        printf '     %s↳ FAILED to copy to %s%s\n' "$C_DIM" "$destdir" "$C_RESET"
        return 1
    fi
}

migrate_wizard() {
    # _mw_header cleans itself up on every return path (explicit or falling
    # off the end) via this RETURN trap, same idea as menu_select/
    # paginated_picker unsetting their own nested draw functions — just
    # centralized instead of repeated at each return.
    trap 'unset -f _mw_header 2>/dev/null' RETURN

    clear; banner
    printf '\n%sAPK MIGRATION WIZARD%s\n' "$C_BGREEN" "$C_RESET"
    printf '%sguided flow — pick a source, a destination, the apks you want, and go.%s\n' "$C_DIM" "$C_RESET"
    printf '%sesc/q backs out one step at a time, all the way to the main menu.%s\n' "$C_DIM" "$C_RESET"

    local -a kind_opts=("Connected Android device" "Local filesystem")
    local kidx

    # src_desc/dst_desc are the one-line "what did I already pick" summaries
    # _mw_header prints; each stays empty (and is skipped) until that side
    # is actually settled.
    local src_desc="" dst_desc=""
    _mw_header() {
        banner
        [ -n "$src_desc" ] && printf '\n%sSOURCE:%s %s\n' "$C_DIM" "$C_RESET" "$src_desc"
        [ -n "$dst_desc" ] && printf '%sDESTINATION:%s %s\n' "$C_DIM" "$C_RESET" "$dst_desc"
    }

    printf '\n'
    if ! menu_select "MIGRATE FROM (source):" kind_opts kidx; then return; fi
    local src_kind; [ "$kidx" -eq 0 ] && src_kind=device || src_kind=local

    local src_serial="" src_label="" src_user="" src_user_label=""
    if [ "$src_kind" = device ]; then
        clear; _mw_header
        printf '\n%sSCANNING FOR SOURCE DEVICE...%s\n' "$C_DIM" "$C_RESET"
        if ! pick_device_for "select source device:" src_serial src_label; then
            pause; return
        fi
        printf '\n%sSCANNING FOR PROFILES ON SOURCE...%s\n' "$C_DIM" "$C_RESET"
        if pick_profile_for "$src_serial" src_user src_user_label; then
            src_desc="$src_label  [$src_user_label]"
        else
            printf '\n%sCould not determine a source profile — continuing without profile scoping.%s\n' "$C_DIM" "$C_RESET"
            src_user=""; src_user_label=""
            src_desc="$src_label"
        fi
    else
        src_desc="$APPS_DIR (local)"
    fi

    clear; _mw_header
    printf '\n'
    if ! menu_select "MIGRATE TO (destination):" kind_opts kidx; then return; fi
    local dst_kind; [ "$kidx" -eq 0 ] && dst_kind=device || dst_kind=local

    local dst_serial="" dst_label="" dst_user="" dst_user_label="" dst_path=""
    if [ "$dst_kind" = device ]; then
        clear; _mw_header
        printf '\n%sSCANNING FOR DESTINATION DEVICE...%s\n' "$C_DIM" "$C_RESET"
        if ! pick_device_for "select destination device:" dst_serial dst_label; then
            pause; return
        fi
        printf '\n%sSCANNING FOR PROFILES ON DESTINATION...%s\n' "$C_DIM" "$C_RESET"
        if ! pick_profile_for "$dst_serial" dst_user dst_user_label; then
            printf '\n%sCould not determine a destination profile.%s\n' "$C_GREEN" "$C_RESET"
            pause; return
        fi
        dst_desc="$dst_label  [$dst_user_label]"

        # Same device AND same profile as the source is a true no-op —
        # pull each apk just to reinstall it right back onto itself.
        # Same device with a *different* profile is a legitimate move
        # (migrating apps between profiles on one phone), so that case
        # stays silent.
        if [ "$src_kind" = device ] && [ "$dst_serial" = "$src_serial" ] && [ -n "$dst_user" ] && [ "$dst_user" = "$src_user" ]; then
            printf '\n%sSource and destination are the same device AND the same profile (%s).%s\n' "$C_DIM" "$dst_user_label" "$C_RESET"
            printf '%sEach apk would just be pulled and reinstalled right back onto itself.%s\n' "$C_DIM" "$C_RESET"
            if ! confirm_yes_no "Continue anyway?"; then
                printf '\n%sCancelled.%s\n' "$C_DIM" "$C_RESET"
                pause; return
            fi
        fi
    else
        clear; _mw_header
        printf '\n%sDestination directory%s (default: %s — type q to cancel):\n' "$C_DIM" "$C_RESET" "$APPS_DIR"
        read -e -r -p "> " dst_path
        if [ "$dst_path" = q ] || [ "$dst_path" = Q ]; then
            printf '\n%sCancelled.%s\n' "$C_DIM" "$C_RESET"
            pause; return
        fi
        [ -z "$dst_path" ] && dst_path="$APPS_DIR"
        mkdir -p "$dst_path" 2>/dev/null
        if [ ! -d "$dst_path" ]; then
            printf '\n%sCould not create/use directory: %s%s\n' "$C_GREEN" "$dst_path" "$C_RESET"
            pause; return
        fi
        dst_desc="$dst_path (local)"
    fi

    local -a pool=()
    clear; _mw_header
    if [ "$src_kind" = device ]; then
        printf '\n%sFetching package list (scope: %s)...%s\n' "$C_DIM" "$PKG_SCOPE" "$C_RESET"
        mapfile -t pool < <(get_packages_on "$src_serial" "$PKG_SCOPE" "$src_user")
    else
        mapfile -t pool < <(list_local_packages)
    fi
    if [ "${#pool[@]}" -eq 0 ]; then
        printf '\n%sNothing found to migrate from this source.%s\n' "$C_GREEN" "$C_RESET"
        pause; return
    fi

    local -a chosen=()
    pick_multi "SELECT APKS TO MIGRATE" pool chosen
    if [ "${#chosen[@]}" -eq 0 ]; then
        return
    fi

    clear; banner
    printf '\n%sMIGRATION PLAN%s\n' "$C_BGREEN" "$C_RESET"
    printf '%sFROM:%s %s\n' "$C_DIM" "$C_RESET" "$src_desc"
    printf '%sTO:%s   %s\n' "$C_DIM" "$C_RESET" "$dst_desc"
    printf '%sAPKS (%d):%s\n' "$C_DIM" "${#chosen[@]}" "$C_RESET"
    local p
    for p in "${chosen[@]}"; do printf '  - %s\n' "$p"; done
    printf '\n'
    if ! confirm_yes_no "Run migration now?"; then
        printf '\n%sCancelled.%s\n' "$C_DIM" "$C_RESET"
        pause; return
    fi

    local stage=""
    if [ "$src_kind" = device ] && [ "$dst_kind" = device ]; then
        stage=$(mktemp -d "${TMPDIR:-/tmp}/androidterm-migrate.XXXXXX")
        MIGRATE_STAGE_DIR="$stage"
    fi

    printf '\n'
    local ok_count=0 fail_count=0 pkg
    for pkg in "${chosen[@]}"; do
        printf '%s— %s —%s\n' "$C_BGREEN" "$pkg" "$C_RESET"
        case "$src_kind:$dst_kind" in
            device:local)
                if pull_package "$src_serial" "$pkg" "$dst_path/$pkg" "$src_user"; then
                    ok_count=$((ok_count+1))
                else
                    fail_count=$((fail_count+1))
                fi
                ;;
            device:device)
                if pull_package "$src_serial" "$pkg" "$stage/$pkg" "$src_user" && migrate_install "$dst_serial" "$dst_user" "$stage/$pkg"; then
                    ok_count=$((ok_count+1))
                else
                    fail_count=$((fail_count+1))
                fi
                ;;
            local:device)
                if migrate_install "$dst_serial" "$dst_user" "$APPS_DIR/$pkg"; then
                    ok_count=$((ok_count+1))
                else
                    fail_count=$((fail_count+1))
                fi
                ;;
            local:local)
                if migrate_copy_local "$pkg" "$dst_path"; then
                    ok_count=$((ok_count+1))
                else
                    fail_count=$((fail_count+1))
                fi
                ;;
        esac
        printf '\n'
    done

    if [ -n "$stage" ]; then
        rm -rf "$stage"
        MIGRATE_STAGE_DIR=""
    fi

    printf '%sMIGRATION COMPLETE:%s %d succeeded, %d failed.\n' "$C_BGREEN" "$C_RESET" "$ok_count" "$fail_count"
    pause
}

# ---------------------------------------------------------------------------
# boot sequence + main menu
# ---------------------------------------------------------------------------
boot_sequence() {
    clear
    banner
    printf '\n'
    type_out "  ANDROID PACKAGE PULL/PUSH TERMINAL — REV 4.0" 0.008
    sleep 0.15
    printf '\n'

    log_line "  ESTABLISHING TERMLINK (adb start-server)"
    if adb start-server &>/dev/null; then ok; else fail; fi
    sleep 0.1

    printf '\n%sSCANNING FOR DEVICES...%s\n' "$C_DIM" "$C_RESET"
    if select_device "$DEVICE_PICK_NOTE"; then
        printf '\n%sSCANNING FOR PROFILES...%s\n' "$C_DIM" "$C_RESET"
        select_profile
    fi
    sleep 0.2
}

# Main menu rows are "label|handler-function" — menu_select's index maps
# straight to a function call, so hiding an item is just commenting out its
# row here (the handler function itself is untouched and still fully
# callable/working). List/Pull/Push are hidden for now at the user's
# request — this is a temporary UI change, not a functionality removal;
# uncomment the three rows below to bring them back.
main_menu_show_upgrades() { deps_screen; pause; }
main_menu_exit() { clear; printf '%sTERMLINK SESSION CLOSED.%s\n' "$C_GREEN" "$C_RESET"; exit 0; }

MAIN_MENU_ROWS=(
    "Device & profile|device_profile_menu"
    #"List installed programs|list_installed"
    #"Pull a program|select_and_pull"
    #"Push a program|push_menu"
    "Migrate APKs (guided)|migrate_wizard"
    "__TOGGLE_SCOPE__|toggle_scope"
    "System upgrades|main_menu_show_upgrades"
    "Exit|main_menu_exit"
)

main_menu() {
    local idx row label action
    local -a labels actions
    while true; do
        labels=(); actions=()
        for row in "${MAIN_MENU_ROWS[@]}"; do
            label="${row%%|*}"
            action="${row#*|}"
            [ "$label" = "__TOGGLE_SCOPE__" ] && label="Toggle package scope (currently: $PKG_SCOPE)"
            labels+=("$label")
            actions+=("$action")
        done
        clear
        banner
        printf '\n%sDEVICE:%s  %s\n' "$C_DIM" "$C_RESET" "${CURRENT_DEVICE_LABEL:-none selected}"
        printf '%sPROFILE:%s %s\n' "$C_DIM" "$C_RESET" "${TARGET_USER_LABEL:-none selected}"
        printf '%s%s%s\n' "$C_DIM" "$(deps_summary_line)" "$C_RESET"
        printf '\n'
        if menu_select "MAIN MENU" labels idx; then
            "${actions[$idx]}"
        else
            main_menu_exit
        fi
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
