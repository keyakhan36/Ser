#!/bin/bash
set -e

# --- Defaults ---
USERNAME=${USERNAME:-debuguser}
PASSWORD=${PASSWORD:-$(openssl rand -base64 15 | tr -dc A-Za-z0-9 | head -c 10)}

# --- Config Paths ---
RBE_ENV_FILE="/etc/profile.d/rbe_env.sh"
PROFILE_FILE="/etc/profile"
LOCK_MARK="# [RBE_ENV_ENFORCED]"

echo "[INFO] Starting entrypoint..."
echo "[INFO] Requested user: $USERNAME"

# ───────────────────────────────
# Detect OS and SSH binary
# ───────────────────────────────
OS_TYPE="Debian/Ubuntu"
SUDO_GROUP="sudo"
SSHD_BIN="/usr/sbin/sshd"

# ───────────────────────────────
# User setup
# ───────────────────────────────
if ! getent group "$SUDO_GROUP" >/dev/null; then
    groupadd "$SUDO_GROUP"
fi

if ! id "$USERNAME" &>/dev/null; then
    echo "[DEBUG] Creating user $USERNAME..."
    useradd -m -s /bin/bash -g "$SUDO_GROUP" "$USERNAME" --no-log-init
    echo "$USERNAME:$PASSWORD" | chpasswd
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
    chmod 440 "/etc/sudoers.d/$USERNAME"
else
    echo "[DEBUG] User $USERNAME exists, updating password..."
    echo "$USERNAME:$PASSWORD" | chpasswd
fi

# Secure root
passwd -d root || true
passwd -l root || true

mkdir -p /var/run/sshd /var/empty/sshd /etc/ssh || true
chmod 755 /var/empty/sshd || true

# ───────────────────────────────
# SSH Configuration
# ───────────────────────────────
cat > /etc/ssh/sshd_config <<EOF
Port 2700
ListenAddress 0.0.0.0
Protocol 2
PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM no
Subsystem sftp internal-sftp
EOF

if ! $SSHD_BIN -t -f /etc/ssh/sshd_config; then
    echo "[ERROR] sshd config invalid!"
    exit 1
fi

# ───────────────────────────────
# Generate RBE Environment (Dynamic)
# ───────────────────────────────
# รับค่า API KEY จาก Environment Variable (ส่งมาจาก GitHub Secrets)
BUILDBUDDY_KEY=${BUILDBUDDY_API_KEY:-"WARNING_NO_KEY_PROVIDED"}

echo "[INFO] Generating /etc/profile.d/rbe_env.sh ..."
cat <<EOF > /etc/profile.d/rbe_env.sh
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache

# --- Enable RBE and General Settings ---
export USE_RBE=1

export RBE_QUIET=1
export RBE_display=0
export RBE_diagnostics=0
export RBE_errorlog=0

export RBE_DIR="/opt/reclient"
export NINJA_REMOTE_NUM_JOBS=2000

# BuildBuddy service + API key
export RBE_service="remote.buildbuddy.io:443"
export BUILDBUDDY_API_KEY="${BUILDBUDDY_KEY}"
export RBE_remote_headers="x-buildbuddy-api-key=${BUILDBUDDY_KEY}"

# Authentication
export RBE_use_rpc_credentials=false
export RBE_service_no_auth=true

# --- Execution Strategies (Base Loop) ---
for tool in R8 D8 JAVAC JAR ZIP TURBINE SIGNAPK CXX CXX_LINKS ABI_LINKER CLANG_TIDY METALAVA LINT; do
    eval "export RBE_\${tool}_EXEC_STRATEGY=remote_local_fallback"
    eval "export RBE_\${tool}=1"
done

# Resource pools
export RBE_JAVA_POOL=default
export RBE_METALAVA_POOL=default
export RBE_LINT_POOL=default

export RBE_JAVAC=0
export RBE_JAR=0
export RBE_D8=0
export RBE_TURBINE=0

export RBE_javac=0
export RBE_jar=0
export RBE_d8=0
export RBE_turbine=0

export RBE_JAVAC_EXEC_STRATEGY=local
export RBE_JAR_EXEC_STRATEGY=local

# Tools that are ALWAYS local-only
export RBE_HIDDENAPI=0
export RBE_HIDDENAPI_EXEC_STRATEGY=local
export RBE_METALAVA=0
export RBE_METALAVA_EXEC_STRATEGY=local
export RBE_LINT=0
export RBE_LINT_EXEC_STRATEGY=local
export RBE_ZIP=0
export RBE_ZIP_EXEC_STRATEGY=local
export RBE_SIGNAPK=0
export RBE_SIGNAPK_EXEC_STRATEGY=local

export RBE_CXX=1
export RBE_CXX_EXEC_STRATEGY=remote_local_fallback
export RBE_CXX_LINKS=1
export RBE_CXX_LINKS_EXEC_STRATEGY=remote_local_fallback
export RBE_R8=1
export RBE_R8_EXEC_STRATEGY=remote_local_fallback

# Safe RBE settings (Minimal Download)
export RBE_use_unified_downloads=false
export RBE_use_unified_uploads=false
export RBE_remote_download_mode=minimal

# Keep ABI tools local
export RBE_LOCAL_ONLY_REGEX="header-abi-diff|create_reference_dumps"
export RBE_HEADER_ABI_DIFF_EXEC_STRATEGY=local
export RBE_ABI_LINKER_EXEC_STRATEGY=local

EOF

chmod +x /etc/profile.d/rbe_env.sh
source /etc/profile.d/rbe_env.sh || true

# Inject into Profile to ensure it loads on login
if ! grep -q "$LOCK_MARK" "$PROFILE_FILE" 2>/dev/null; then
    cat <<EOF >> "$PROFILE_FILE"

$LOCK_MARK
if [ -f $RBE_ENV_FILE ]; then
    source $RBE_ENV_FILE
fi
EOF
fi

# ───────────────────────────────
# Enable Byobu
# ───────────────────────────────
if command -v byobu-enable >/dev/null 2>&1; then
    runuser -u "$USERNAME" -- byobu-enable || true
fi

# ───────────────────────────────
# Final Info
# ───────────────────────────────
echo "==================================================="
echo "   🚀 Neko Build Environment Ready"
echo "   👤 User: $USERNAME"
echo "   🔑 Pass: $PASSWORD"
echo "   📡 Port: 2700"
echo "   ☁️  RBE : Optimized (CXX=Remote, Java=Local)"
echo "==================================================="

exec $SSHD_BIN -D -e -f /etc/ssh/sshd_config