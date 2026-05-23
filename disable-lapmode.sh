#!/usr/bin/env bash
# =============================================================================
# disable-lapmode.sh
# Disables the ThinkPad lap detection sensor by patching the thinkpad_acpi
# kernel module via DKMS. Survives kernel updates automatically.
#
# Tested on: Fedora 44 (kernel 7.x), should work on Fedora 34+, Ubuntu 20.04+,
#            Arch/Manjaro, and other systemd-based distros.
#
# Usage:   sudo ./disable-lapmode.sh
# Revert:  sudo ./disable-lapmode.sh --uninstall
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

DKMS_NAME="thinkpad_acpi"
DKMS_VERSION="1.0"
SRC_DIR="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Uninstall mode
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    info "Uninstalling patched thinkpad_acpi DKMS module..."
    dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null && {
        dkms uninstall "${DKMS_NAME}/${DKMS_VERSION}" || true
        dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all || true
    }
    [[ -d "$SRC_DIR" ]] && rm -rf "$SRC_DIR"
    ok "Uninstalled. Reboot to restore the stock thinkpad_acpi module."
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Use: sudo $0"
fi

if [[ ! -f /sys/devices/platform/thinkpad_acpi/dytc_lapmode ]]; then
    error "This system does not appear to have a ThinkPad lap mode sensor."
fi

KERNEL_VERSION=$(uname -r)
KERNEL_BASE="${KERNEL_VERSION%%-*}"
info "Detected kernel: ${KERNEL_VERSION} (base: ${KERNEL_BASE})"

CURRENT_LAPMODE=$(cat /sys/devices/platform/thinkpad_acpi/dytc_lapmode)
info "Current dytc_lapmode value: ${CURRENT_LAPMODE}"

# Check if already installed
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q "installed"; then
    warn "Patched module is already installed."
    echo -e "  Run ${YELLOW}sudo $0 --uninstall${NC} to remove, or reboot if you haven't yet."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
info "Installing build dependencies..."

if command -v dnf &>/dev/null; then
    dnf install -y make automake gcc gcc-c++ kernel-devel dkms wget openssl
elif command -v apt-get &>/dev/null; then
    apt-get update
    apt-get install -y build-essential dkms git wget
elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm --needed base-devel dkms git wget openssl linux-headers
else
    warn "Unknown package manager. Make sure you have: gcc, make, dkms, wget, kernel-devel"
fi

ok "Dependencies ready."

# ---------------------------------------------------------------------------
# Clean up any previous failed DKMS state
# ---------------------------------------------------------------------------
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    info "Cleaning up previous DKMS state..."
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi
[[ -d "$SRC_DIR" ]] && rm -rf "$SRC_DIR"

# ---------------------------------------------------------------------------
# Prepare source directory
# ---------------------------------------------------------------------------
info "Setting up DKMS source at ${SRC_DIR}..."
mkdir -p "${SRC_DIR}/scripts"

# --- Makefile ---
cat > "${SRC_DIR}/Makefile" << 'EOF'
obj-m += thinkpad_acpi.o

all:
	make -C /lib/modules/$(uname -r)/build M=$(PWD) modules
	xz thinkpad_acpi.ko

clean:
	make -C /lib/modules/$(uname -r)/build M=$(PWD) clean
EOF

# --- Determine correct DEST_MODULE_LOCATION ---
# Kernel 5.17+ moved thinkpad_acpi into a lenovo/ subdirectory
DEST_LOC="/kernel/drivers/platform/x86/"
MAJOR=$(echo "$KERNEL_BASE" | cut -d. -f1)
MINOR=$(echo "$KERNEL_BASE" | cut -d. -f2)
if [[ "$MAJOR" -gt 5 ]] || { [[ "$MAJOR" -eq 5 ]] && [[ "$MINOR" -ge 17 ]]; }; then
    DEST_LOC="/kernel/drivers/platform/x86/lenovo/"
fi
info "Module destination: ${DEST_LOC}"

# --- dkms.conf ---
cat > "${SRC_DIR}/dkms.conf" << EOF
PACKAGE_NAME="${DKMS_NAME}"
PACKAGE_VERSION="${DKMS_VERSION}"
BUILT_MODULE_NAME[0]="${DKMS_NAME}"
DEST_MODULE_LOCATION[0]="${DEST_LOC}"
AUTOINSTALL="yes"
PRE_BUILD="scripts/download.sh"
EOF

# --- version_check.sh (no-op, kept for compatibility) ---
cat > "${SRC_DIR}/scripts/version_check.sh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SRC_DIR}/scripts/version_check.sh"

# --- download.sh (the main patching script, with all fixes) ---
cat > "${SRC_DIR}/scripts/download.sh" << 'DLSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

VERSION=$(uname -r)
VERSION="${VERSION%%-*}"
DO_ACCEL=true

# dual_accel_detect.h only exists in kernel >= 5.14
printf '%s\n' "$VERSION" "5.14" | sort -CV
if [ "$?" -ne 1 ]; then
    echo "Kernel version is < 5.14, dual_accel_detect.h not required"
    DO_ACCEL=false
fi

# kernel.org uses x.y for x.y.0 releases, but uname returns x.y.0
if [[ ${#VERSION} -ge 4 ]] && [[ $VERSION == *.0 ]]; then
    echo "Version ends in .0, trimming for kernel.org URL"
    VERSION="${VERSION::-2}"
fi

echo "Downloading kernel source for v${VERSION}..."

# Determine correct path (kernel 5.17+ moved to lenovo/ subdir)
USE_LENOVO_PATH=false
ACPI_PATH="drivers/platform/x86/lenovo/thinkpad_acpi.c"
if wget -q --spider "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/${ACPI_PATH}?h=v$VERSION" 2>/dev/null; then
    USE_LENOVO_PATH=true
else
    echo "Not found at lenovo/ path, using legacy path..."
    ACPI_PATH="drivers/platform/x86/thinkpad_acpi.c"
fi

echo "Downloading thinkpad_acpi.c from ${ACPI_PATH}..."
wget -q "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/${ACPI_PATH}?h=v$VERSION" -O "thinkpad_acpi.c"

if [ "$DO_ACCEL" = true ]; then
    HEADER_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/platform/x86/dual_accel_detect.h?h=v$VERSION"
    if [ "$USE_LENOVO_PATH" = true ]; then
        # Source does #include "../dual_accel_detect.h" — place it one dir up
        mkdir -p ../
        echo "Downloading dual_accel_detect.h (to parent dir for ../include)..."
        wget -q "$HEADER_URL" -O "../dual_accel_detect.h"
    else
        echo "Downloading dual_accel_detect.h..."
        wget -q "$HEADER_URL" -O "dual_accel_detect.h"
    fi
fi

echo "Patching thinkpad_acpi.c to disable lap detection..."

# Force lapmode sensor to always return false
sed -i 's/\*state = output \& BIT(DYTC_GET_LAPMODE_BIT) ? true : false/\*state = output \& BIT(DYTC_GET_LAPMODE_BIT) ? false : false/' thinkpad_acpi.c

# Tag the version so we can identify the patched module
sed -i '/#define TPACPI_VERSION "/c\#define TPACPI_VERSION "420.26"' thinkpad_acpi.c

echo "Patching complete!"
DLSCRIPT
chmod +x "${SRC_DIR}/scripts/download.sh"

ok "Source files prepared."

# ---------------------------------------------------------------------------
# Build and install via DKMS
# ---------------------------------------------------------------------------
info "Registering with DKMS..."
dkms add -m "${DKMS_NAME}/${DKMS_VERSION}"

info "Building module (this downloads & patches kernel source — requires internet)..."
dkms build "${DKMS_NAME}/${DKMS_VERSION}"

info "Installing module..."
dkms install "${DKMS_NAME}/${DKMS_VERSION}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
ok "======================================"
ok "  Lap detection patch installed!"
ok "======================================"
echo ""
info "Verify with: sudo modinfo thinkpad_acpi | grep version"
echo -e "  Expected: ${GREEN}version: 420.26${NC}"
echo ""
info "To uninstall: sudo $0 --uninstall"
echo ""
echo -e "${YELLOW}>>> REBOOT NOW to load the patched module <<<${NC}"
echo ""
