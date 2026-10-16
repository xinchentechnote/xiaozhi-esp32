#!/usr/bin/env bash

# Bootstrap a macOS ESP-IDF v6.1 environment and build one XiaoZhi variant.
# The script intentionally does not modify shell startup files or flash a device.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly ESP_IDF_REPOSITORY="https://github.com/espressif/esp-idf.git"
readonly ESP_IDF_TAG="v6.1"

BOARD="bread-compact-wifi"
VARIANT=""
LANGUAGE=""
WAKE_WORD=""
BUILD_OPTIONS_JSON=""
IDF_DIRECTORY="${XIAOZHI_IDF_PATH:-${HOME}/esp/esp-idf-v6.1}"
LIST_BOARDS=0
PREPARE_ONLY=0
SKIP_SYSTEM_PACKAGES=0
CREATE_ZIP=0

log() {
    printf '[xiaozhi] %s\n' "$*"
}

warn() {
    printf '[xiaozhi] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[xiaozhi] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/macos_build.sh [options]

Prepare a macOS build environment and build one XiaoZhi firmware variant.
With no options, the script builds bread-compact-wifi with the project's
default language (en-US) and wake word (Hi ESP).

Options:
  --board BOARD                 Board directory under main/boards/.
  --name VARIANT               Exact build.name from the board config.json.
  --language LOCALE            Firmware locale, for example zh-CN or en-US.
  --wake-word MODEL            Model name, nihaoxiaozhi, hiesp, or disabled.
  --build-options-json JSON     Semantic board options accepted by build.py.
  --idf-path PATH              ESP-IDF checkout (default: ~/esp/esp-idf-v6.1).
  --zip                        Also create the release ZIP package.
  --list-boards                List supported boards and variants, then exit.
  --prepare-only               Install prerequisites and ESP-IDF, then exit.
  --skip-system-packages       Do not install Xcode CLT or Homebrew packages.
  -h, --help                   Show this help.

Examples:
  ./scripts/macos_build.sh
  ./scripts/macos_build.sh --language zh-CN
  ./scripts/macos_build.sh --board bread-compact-wifi \
      --name bread-compact-wifi-128x64 --language zh-CN
  ./scripts/macos_build.sh --list-boards
EOF
}

require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [ -z "${value}" ]; then
        die "${option} requires a value"
    fi
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --board)
                require_option_value "$1" "${2:-}"
                BOARD="$2"
                shift 2
                ;;
            --name)
                require_option_value "$1" "${2:-}"
                VARIANT="$2"
                shift 2
                ;;
            --language)
                require_option_value "$1" "${2:-}"
                LANGUAGE="$2"
                shift 2
                ;;
            --wake-word)
                require_option_value "$1" "${2:-}"
                WAKE_WORD="$2"
                shift 2
                ;;
            --build-options-json)
                require_option_value "$1" "${2:-}"
                BUILD_OPTIONS_JSON="$2"
                shift 2
                ;;
            --idf-path)
                require_option_value "$1" "${2:-}"
                IDF_DIRECTORY="$2"
                shift 2
                ;;
            --zip)
                CREATE_ZIP=1
                shift
                ;;
            --list-boards)
                LIST_BOARDS=1
                shift
                ;;
            --prepare-only)
                PREPARE_ONLY=1
                shift
                ;;
            --skip-system-packages)
                SKIP_SYSTEM_PACKAGES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1 (use --help for usage)"
                ;;
        esac
    done
}

ensure_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        die "this bootstrap script supports macOS only"
    fi
    log "Detected macOS $(sw_vers -productVersion) ($(uname -m))."
}

ensure_command_line_tools() {
    if xcode-select -p >/dev/null 2>&1; then
        return
    fi

    log "Apple Command Line Tools are missing; opening the macOS installer."
    xcode-select --install >/dev/null 2>&1 || true
    log "Complete the installation dialog. This terminal will wait for it."

    local wait_seconds="${XIAOZHI_CLT_WAIT_SECONDS:-1800}"
    case "${wait_seconds}" in
        ''|*[!0-9]*) die "XIAOZHI_CLT_WAIT_SECONDS must be a non-negative integer" ;;
    esac
    if [ "${wait_seconds}" -eq 0 ]; then
        die "Command Line Tools are required; install them and rerun this script"
    fi

    local deadline
    deadline=$(( $(date +%s) + wait_seconds ))
    while ! xcode-select -p >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            die "timed out waiting for Apple Command Line Tools; rerun after installation finishes"
        fi
        sleep 5
    done
    log "Apple Command Line Tools are ready."
}

load_homebrew() {
    local brew_binary=""

    if command -v brew >/dev/null 2>&1; then
        brew_binary="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
        brew_binary="/opt/homebrew/bin/brew"
    elif [ -x /usr/local/bin/brew ]; then
        brew_binary="/usr/local/bin/brew"
    fi

    if [ -n "${brew_binary}" ]; then
        eval "$(${brew_binary} shellenv)"
        return 0
    fi
    return 1
}

ensure_homebrew() {
    if load_homebrew; then
        return
    fi

    log "Homebrew is missing; starting the official Homebrew installer."
    log "The installer may request the macOS administrator password."
    /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    load_homebrew || die "Homebrew was installed but could not be added to PATH"
}

configure_homebrew_python() {
    if ! load_homebrew; then
        return
    fi
    if brew list --versions python@3.12 >/dev/null 2>&1; then
        local python_prefix
        python_prefix="$(brew --prefix python@3.12)"
        export PATH="${python_prefix}/libexec/bin:${python_prefix}/bin:${PATH}"
    fi
}

verify_system_commands() {
    local command_name
    for command_name in git python3 cmake ninja; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            die "required command '${command_name}' is missing; rerun without --skip-system-packages"
        fi
    done
    for command_name in ccache dfu-util; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            warn "optional command '${command_name}' is unavailable; the firmware can still be built"
        fi
    done
}

prepare_system_packages() {
    if [ "${SKIP_SYSTEM_PACKAGES}" -eq 0 ]; then
        ensure_command_line_tools
        ensure_homebrew
        log "Installing build prerequisites with Homebrew."
        HOMEBREW_NO_AUTO_UPDATE=1 brew install cmake ninja ccache dfu-util python@3.12
    fi

    configure_homebrew_python
    verify_system_commands
    log "Using $(python3 --version 2>&1), $(cmake --version | sed -n '1p'), Ninja $(ninja --version)."
}

validate_board_name() {
    if ! printf '%s' "${BOARD}" | grep -Eq '^[a-z0-9._-]+(/[a-z0-9._-]+)?$'; then
        die "invalid board directory: ${BOARD}"
    fi
    if [ -n "${VARIANT}" ] && ! printf '%s' "${VARIANT}" | grep -Eq '^[a-z0-9.-]+$'; then
        die "invalid variant name: ${VARIANT}"
    fi
}

read_board_target() {
    local config_path="${PROJECT_ROOT}/main/boards/${BOARD}/config.json"
    [ -f "${config_path}" ] || die "board config not found: ${config_path}"

    python3 - "${config_path}" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
try:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    target = config["target"]
except (OSError, KeyError, json.JSONDecodeError) as error:
    raise SystemExit(f"Cannot read target from {config_path}: {error}")
if not isinstance(target, str) or not target.startswith("esp32"):
    raise SystemExit(f"Invalid target in {config_path}: {target!r}")
print(target)
PY
}

select_default_variant() {
    local config_path="${PROJECT_ROOT}/main/boards/${BOARD}/config.json"

    python3 - "${config_path}" "${BOARD}" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
board = sys.argv[2]
try:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    names = [item["name"] for item in config.get("builds", [])]
except (OSError, KeyError, json.JSONDecodeError) as error:
    raise SystemExit(f"Cannot read variants from {config_path}: {error}")

basename = board.rsplit("/", 1)[-1]
if basename in names:
    print(basename)
elif len(names) == 1:
    print(names[0])
else:
    choices = ", ".join(names) if names else "none"
    raise SystemExit(
        f"Board {board!r} has no unambiguous default variant. "
        f"Pass --name with one of: {choices}"
    )
PY
}

prepare_idf_source() {
    if [ ! -e "${IDF_DIRECTORY}" ]; then
        log "Cloning ESP-IDF ${ESP_IDF_TAG} into ${IDF_DIRECTORY}."
        mkdir -p "$(dirname "${IDF_DIRECTORY}")"
        git clone --branch "${ESP_IDF_TAG}" --depth 1 --recursive --shallow-submodules \
            "${ESP_IDF_REPOSITORY}" "${IDF_DIRECTORY}"
    elif [ -d "${IDF_DIRECTORY}" ] && [ -z "$(ls -A "${IDF_DIRECTORY}")" ]; then
        log "Cloning ESP-IDF ${ESP_IDF_TAG} into the empty directory ${IDF_DIRECTORY}."
        git clone --branch "${ESP_IDF_TAG}" --depth 1 --recursive --shallow-submodules \
            "${ESP_IDF_REPOSITORY}" "${IDF_DIRECTORY}"
    fi

    if [ ! -f "${IDF_DIRECTORY}/export.sh" ] || [ ! -f "${IDF_DIRECTORY}/install.sh" ]; then
        die "${IDF_DIRECTORY} exists but is not an ESP-IDF checkout; choose another --idf-path"
    fi

    if [ -d "${IDF_DIRECTORY}/.git" ] && \
        git -C "${IDF_DIRECTORY}" submodule status --recursive 2>/dev/null | grep -q '^-'; then
        log "Initializing missing ESP-IDF submodules."
        git -C "${IDF_DIRECTORY}" submodule update --init --recursive
    fi
}

read_idf_version() {
    python3 - "${IDF_DIRECTORY}/tools/cmake/version.cmake" <<'PY'
import re
import sys
from pathlib import Path

version_file = Path(sys.argv[1])
try:
    content = version_file.read_text(encoding="utf-8")
except OSError as error:
    raise SystemExit(f"Cannot read {version_file}: {error}")

parts = {}
for name, value in re.findall(r"set\(IDF_VERSION_(MAJOR|MINOR|PATCH)\s+(\d+)\)", content):
    parts[name] = int(value)
if not all(name in parts for name in ("MAJOR", "MINOR", "PATCH")):
    raise SystemExit(f"Cannot determine ESP-IDF version from {version_file}")
print(f"{parts['MAJOR']}.{parts['MINOR']}.{parts['PATCH']}")
PY
}

validate_idf_version() {
    local idf_version="$1"
    local target="$2"

    python3 - "${idf_version}" "${target}" <<'PY'
import sys

version = tuple(int(part) for part in sys.argv[1].split("."))
target = sys.argv[2]
minimum = (6, 1, 0) if target == "esp32s31" else (6, 0, 1)
if version < minimum:
    required = ".".join(str(part) for part in minimum)
    raise SystemExit(
        f"ESP-IDF {sys.argv[1]} is too old for {target}; version {required} or newer is required"
    )
PY
}

activate_esp_idf() {
    local target="$1"

    log "Installing/checking ESP-IDF tools for ${target}."
    (
        cd "${IDF_DIRECTORY}"
        ./install.sh "${target}"
    )

    # shellcheck disable=SC1090
    source "${IDF_DIRECTORY}/export.sh"
    command -v idf.py >/dev/null 2>&1 || die "idf.py is unavailable after sourcing export.sh"
    log "Activated $(idf.py --version)."
}

list_boards() {
    if [ -f "${IDF_DIRECTORY}/tools/cmake/version.cmake" ]; then
        IDF_PATH="${IDF_DIRECTORY}" python3 "${PROJECT_ROOT}/scripts/build.py" --list-boards
    else
        python3 "${PROJECT_ROOT}/scripts/build.py" --list-boards
    fi
}

run_build() {
    local build_args=(
        "${PROJECT_ROOT}/scripts/build.py"
        "${BOARD}"
        --name "${VARIANT}"
    )

    if [ -n "${LANGUAGE}" ]; then
        build_args+=(--language "${LANGUAGE}")
    fi
    if [ -n "${WAKE_WORD}" ]; then
        build_args+=(--wake-word "${WAKE_WORD}")
    fi
    if [ -n "${BUILD_OPTIONS_JSON}" ]; then
        build_args+=(--build-options-json "${BUILD_OPTIONS_JSON}")
    fi
    if [ "${CREATE_ZIP}" -eq 1 ]; then
        build_args+=(--zip)
    fi

    log "Building board=${BOARD}, variant=${VARIANT}${LANGUAGE:+, language=${LANGUAGE}}."
    (
        cd "${PROJECT_ROOT}"
        python3 "${build_args[@]}"
    )
}

print_artifacts() {
    local artifacts=(
        "build/merged-binary.bin"
        "build/xiaozhi.bin"
        "build/generated_assets.bin"
    )
    local artifact

    log "Build completed. Generated artifacts:"
    for artifact in "${artifacts[@]}"; do
        if [ -f "${PROJECT_ROOT}/${artifact}" ]; then
            (
                cd "${PROJECT_ROOT}"
                ls -lh "${artifact}"
                shasum -a 256 "${artifact}"
            )
        fi
    done
    if [ "${CREATE_ZIP}" -eq 1 ]; then
        find "${PROJECT_ROOT}/releases" -maxdepth 1 -type f -name "*_${VARIANT}.zip" -print 2>/dev/null || true
    fi
    log "No device was flashed. See docs/macos-build_zh.md for flashing instructions."
}

main() {
    parse_arguments "$@"
    ensure_macos
    prepare_system_packages

    if [ "${LIST_BOARDS}" -eq 1 ]; then
        list_boards
        exit 0
    fi

    validate_board_name
    local target
    target="$(read_board_target)"
    if [ -z "${VARIANT}" ]; then
        VARIANT="$(select_default_variant)"
    fi

    prepare_idf_source
    local idf_version
    idf_version="$(read_idf_version)"
    validate_idf_version "${idf_version}" "${target}"
    log "Using ESP-IDF ${idf_version} from ${IDF_DIRECTORY}."
    activate_esp_idf "${target}"

    if [ "${PREPARE_ONLY}" -eq 1 ]; then
        log "Environment preparation completed; build was skipped."
        exit 0
    fi

    run_build
    print_artifacts
}

main "$@"
