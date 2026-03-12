#!/usr/bin/env bash
# setup.sh - 每次 build 前執行，自動偵測系統參數並更新 .env
#
# 取代 get_param.sh，支援以下功能：
#   - 使用者資訊偵測（UID/GID/USER/GROUP）
#   - 硬體架構偵測
#   - Docker Hub 用戶名偵測
#   - GPU 支援偵測
#   - Image 名稱推導（相容 get_param.sh 的 docker_* / *_ws 命名慣例）
#   - 工作區路徑偵測（路徑內搜尋 → 鄰層搜尋 → 提示輸入）
#   - .env 生成

# Only set strict mode when running directly; when sourced, respect caller's settings
# LCOV_EXCL_START
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    set -euo pipefail
fi
# LCOV_EXCL_STOP

# ════════════════════════════════════════════════════════════════════
# detect_user_info
#
# Usage: detect_user_info <user_outvar> <group_outvar> <uid_outvar> <gid_outvar>
# ════════════════════════════════════════════════════════════════════
detect_user_info() {
    local -n __dui_user="${1:?"${FUNCNAME[0]}: missing user outvar"}"; shift
    local -n __dui_group="${1:?"${FUNCNAME[0]}: missing group outvar"}"; shift
    local -n __dui_uid="${1:?"${FUNCNAME[0]}: missing uid outvar"}"; shift
    local -n __dui_gid="${1:?"${FUNCNAME[0]}: missing gid outvar"}"

    __dui_user="${USER:-$(id -un)}"
    __dui_group="$(id -gn)"
    __dui_uid="$(id -u)"
    __dui_gid="$(id -g)"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
#
# Usage: detect_hardware <outvar>
# ════════════════════════════════════════════════════════════════════
detect_hardware() {
    local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
    _outvar="$(uname -m)"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
#
# Tries docker info first, falls back to USER, then id -un
#
# Usage: detect_docker_hub_user <outvar>
# ════════════════════════════════════════════════════════════════════
detect_docker_hub_user() {
    local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
    local _name=""
    _name="$(docker info 2>/dev/null | awk '/^[[:space:]]*Username:/{print $2}')" || true
    _outvar="${_name:-${USER:-$(id -un)}}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
#
# Checks nvidia-container-toolkit via dpkg-query
#
# Usage: detect_gpu <outvar>
# outvar: "true" or "false"
# ════════════════════════════════════════════════════════════════════
detect_gpu() {
    local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
    if dpkg-query -W -f='${db:Status-Abbrev}\n' -- "nvidia-container-toolkit" 2>/dev/null \
        | grep -q '^ii'; then
        _outvar=true
    else
        _outvar=false
    fi
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name
#
# Scans path components from right to left.
# Priority: docker_<name> → <name>_ws → last directory component
# Compatible with get_param.sh naming convention.
#
# Usage: detect_image_name <outvar> <path>
# ════════════════════════════════════════════════════════════════════
detect_image_name() {
    local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
    local _path="${1:?"${FUNCNAME[0]}: missing path"}"

    local -a _parts=()
    local _found=""

    IFS='/' read -ra _parts <<< "${_path}"

    local i _part
    for (( i=${#_parts[@]}-1; i>=0; i-- )); do
        _part="${_parts[i]}"
        [[ -z "${_part}" ]] && continue
        if [[ "${_part}" == docker_* ]]; then
            _found="${_part#docker_}"
        elif [[ "${_part}" == *_ws ]]; then
            _found="${_part%_ws}"
        else
            _found="${_part}"
        fi
        break
    done

    _outvar="${_found,,}"
}

# ════════════════════════════════════════════════════════════════════
# _read_ws_path  (internal, extracted for testability)
#
# Usage: _read_ws_path <default_path>
# Prints: user input or default
# ════════════════════════════════════════════════════════════════════
_read_ws_path() {
    local _default="${1}"
    local _input=""
    read -rp "[setup] 請輸入工作區路徑 [${_default}]: " _input
    echo "${_input:-${_default}}"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
#
# Workspace detection strategy (in order):
#   1. Traverse path upward looking for a *_ws component
#   2. Scan sibling directories for *_ws
#   3. Prompt user interactively
#
# Compatible with get_param.sh get_workdir behaviour.
#
# Usage: detect_ws_path <outvar> <base_path>
# ════════════════════════════════════════════════════════════════════
detect_ws_path() {
    local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
    local _base_path="${1:?"${FUNCNAME[0]}: missing base_path"}"

    # Strategy 1: traverse path upward looking for *_ws component
    local _check="${_base_path}"
    while [[ "${_check}" != "/" && "${_check}" != "." ]]; do
        if [[ "$(basename "${_check}")" == *_ws && -d "${_check}" ]]; then
            _outvar="$(cd "${_check}" && pwd -P)"
            return 0
        fi
        _check="$(dirname "${_check}")"
    done

    # Strategy 2: scan sibling *_ws directories
    local _dir=""
    for _dir in "${_base_path}/../"*_ws/; do
        if [[ -d "${_dir}" ]]; then
            _outvar="$(cd "${_dir}" && pwd -P)"
            return 0
        fi
    done

    # Strategy 3: prompt user
    local _default="${_base_path}/../workspace"
    printf "[setup] 工作區路徑未找到，請手動輸入\n" >&2
    local _ws_read_result=""
    _ws_read_result="$(_read_ws_path "${_default}")"
    mkdir -p "${_ws_read_result}"
    _outvar="${_ws_read_result}"
}

# ════════════════════════════════════════════════════════════════════
# write_env
#
# Usage: write_env <env_file> <user_name> <user_group> <uid> <gid>
#                  <hardware> <docker_hub_user> <gpu_enabled>
#                  <image_name> <ws_path>
# ════════════════════════════════════════════════════════════════════
write_env() {
    local _env_file="${1:?"${FUNCNAME[0]}: missing env_file"}"; shift
    local _user_name="${1}"; shift
    local _user_group="${1}"; shift
    local _uid="${1}"; shift
    local _gid="${1}"; shift
    local _hardware="${1}"; shift
    local _docker_hub_user="${1}"; shift
    local _gpu_enabled="${1}"; shift
    local _image_name="${1}"; shift
    local _ws_path="${1}"

    cat > "${_env_file}" << EOF
# Auto-generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# 自動偵測欄位請勿手動修改，如需變更 WS_PATH 可直接編輯此檔案

# ── 自動偵測 ──────────────────────────────────
USER_NAME=${_user_name}
USER_GROUP=${_user_group}
USER_UID=${_uid}
USER_GID=${_gid}
HARDWARE=${_hardware}
DOCKER_HUB_USER=${_docker_hub_user}
GPU_ENABLED=${_gpu_enabled}
IMAGE_NAME=${_image_name}

# ── 工作區 ────────────────────────────────────
WS_PATH=${_ws_path}
EOF
}

# ════════════════════════════════════════════════════════════════════
# main
#
# Usage: main [--base-path <path>]
#   --base-path  override script directory (useful for testing)
# ════════════════════════════════════════════════════════════════════
main() {
    local _base_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-path)
                _base_path="${2:?"--base-path requires a value"}"
                shift 2
                ;;
            *)
                printf "[setup] Unknown argument: %s\n" "$1" >&2
                return 1
                ;;
        esac
    done

    if [[ -z "${_base_path}" ]]; then
        _base_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
    fi

    local _env_file="${_base_path}/.env"

    # Load existing .env to preserve manually-set values (e.g. WS_PATH)
    if [[ -f "${_env_file}" ]]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "${_env_file}"
        set +o allexport
    fi

    local user_name="" user_group="" user_uid="" user_gid=""
    local hardware="" docker_hub_user="" gpu_enabled="" image_name=""
    local ws_path="${WS_PATH:-}"

    detect_user_info       user_name user_group user_uid user_gid
    detect_hardware        hardware
    detect_docker_hub_user docker_hub_user
    detect_gpu             gpu_enabled
    detect_image_name      image_name "${_base_path}"

    if [[ -z "${ws_path}" ]] || [[ ! -d "${ws_path}" ]]; then
        detect_ws_path ws_path "${_base_path}"
    fi
    ws_path="$(cd "${ws_path}" && pwd -P)"

    write_env "${_env_file}" \
        "${user_name}" "${user_group}" "${user_uid}" "${user_gid}" \
        "${hardware}" "${docker_hub_user}" "${gpu_enabled}" \
        "${image_name}" "${ws_path}"

    printf "[setup] .env 更新完成\n"
    printf "[setup] USER=%s (%s:%s)  GPU=%s  IMAGE=%s  WS=%s\n" \
        "${user_name}" "${user_uid}" "${user_gid}" \
        "${gpu_enabled}" "${image_name}" "${ws_path}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
# LCOV_EXCL_START
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi
# LCOV_EXCL_STOP
