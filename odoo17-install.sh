#!/bin/bash
# =============================================================================
#  Odoo 17 一键安装脚本 v2.0
#  适用系统：Ubuntu 22.04 LTS
#  配置目标：2核 2GB RAM VPS
#  更新内容：修复 gevent/greenlet 兼容性、增加依赖检测、断点续装
# =============================================================================

set -uo pipefail

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_skip()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }
log_check()   { echo -e "${BLUE}[CHK]${NC}  $1"; }

# ─── 配置变量 ────────────────────────────────────────────────────────────────
DOMAIN="erp.n585.com"
ODOO_VERSION="17.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo17.conf"
ODOO_SERVICE="odoo17"
ODOO_PORT="8069"
LONGPOLLING_PORT="8072"
ODOO_LOG="/opt/odoo/logs/odoo17.log"
DB_USER="odoo"
WORKERS="2"
MAX_CRON_THREADS="1"
SWAP_SIZE="2G"
INSTALL_REDIS="true"
SSL_EMAIL=""
ADMIN_PASSWD=""

# Python 依赖版本锁定（修复兼容性问题）
GEVENT_VERSION="22.10.2"
GREENLET_VERSION="2.0.2"

# ─── 进度追踪文件（支持断点续装）────────────────────────────────────────────
PROGRESS_FILE="/root/.odoo17_install_progress"

mark_done()  { echo "$1" >> "$PROGRESS_FILE"; }
is_done()    { grep -qx "$1" "$PROGRESS_FILE" 2>/dev/null; }

# ─── 运行前检查 ──────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本！"
        exit 1
    fi
}

check_os() {
    if ! grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null; then
        log_warn "检测到非 Ubuntu 22.04 系统，脚本可能存在兼容性问题，继续? [y/N]"
        read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
}

# ─── 依赖检测函数 ────────────────────────────────────────────────────────────

# 检测 apt 包是否已安装
check_apt_pkg() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# 检测命令是否存在
check_cmd() {
    command -v "$1" &>/dev/null
}

# 检测 pip 包版本是否符合要求
# 返回: 0=版本匹配 1=版本不符/未安装
check_pip_pkg() {
    local pkg="$1"
    local expected_ver="$2"
    local PIP="${ODOO_HOME}/venv/bin/pip"

    if [[ ! -f "$PIP" ]]; then
        return 1
    fi

    local installed_ver
    installed_ver=$("$PIP" show "$pkg" 2>/dev/null | grep "^Version:" | awk '{print $2}')

    if [[ -z "$installed_ver" ]]; then
        log_check "${pkg}: 未安装"
        return 1
    fi

    if [[ "$installed_ver" == "$expected_ver" ]]; then
        log_check "${pkg}: ${installed_ver} [OK]"
        return 0
    else
        log_warn "${pkg}: 已安装 ${installed_ver}，期望 ${expected_ver}，将强制覆盖"
        return 1
    fi
}

# 检测 pip 包是否可正常导入（功能验证）
check_pip_importable() {
    local module="$1"
    "${ODOO_HOME}/venv/bin/python3" -c "import ${module}" 2>/dev/null
}

# 检测并修复关键 pip 依赖
verify_pip_deps() {
    log_info "正在验证关键 Python 依赖..."
    local need_fix=0
    local PIP="${ODOO_HOME}/venv/bin/pip"

    # 检测 gevent
    if ! check_pip_pkg "gevent" "$GEVENT_VERSION"; then
        need_fix=1
        log_info "修复 gevent -> ${GEVENT_VERSION}..."
        sudo -u "$ODOO_USER" "$PIP" install -q \
            "gevent==${GEVENT_VERSION}" --no-build-isolation --force-reinstall
    fi

    # 检测 greenlet（必须 >=2.0.0）
    local gl_ver
    gl_ver=$("$PIP" show greenlet 2>/dev/null | grep "^Version:" | awk '{print $2}')
    local gl_major
    gl_major=$(echo "${gl_ver:-0}" | cut -d. -f1)
    if [[ -z "$gl_ver" ]] || [[ "$gl_major" -lt 2 ]]; then
        need_fix=1
        log_warn "greenlet: 已安装 ${gl_ver:-未安装}，需要 >=2.0.0，强制升级..."
        sudo -u "$ODOO_USER" "$PIP" install -q \
            "greenlet>=${GREENLET_VERSION}" --force-reinstall
    else
        log_check "greenlet: ${gl_ver} [OK]"
    fi

    # 验证 gevent 可以正常导入
    if ! check_pip_importable "gevent"; then
        log_error "gevent 安装后无法导入，尝试重新安装..."
        sudo -u "$ODOO_USER" "$PIP" install -q \
            "gevent==${GEVENT_VERSION}" "greenlet>=${GREENLET_VERSION}" \
            --no-build-isolation --force-reinstall
    fi

    # 检测其他关键包是否可导入
    local critical_modules=("psycopg2" "lxml" "PIL" "werkzeug" "cryptography")
    for mod in "${critical_modules[@]}"; do
        if check_pip_importable "$mod"; then
            log_check "${mod}: 导入正常 [OK]"
        else
            log_warn "${mod}: 导入失败，尝试重新安装..."
            need_fix=1
            local pkg_line
            pkg_line=$(grep -i "^${mod}\|^Pillow\|^Werkzeug\|^psycopg2\|^lxml\|^cryptography" \
                "${ODOO_HOME}/odoo17/requirements.txt" 2>/dev/null | head -1)
            if [[ -n "$pkg_line" ]]; then
                sudo -u "$ODOO_USER" "$PIP" install -q "$pkg_line" --force-reinstall
            fi
        fi
    done

    if [[ $need_fix -eq 0 ]]; then
        log_success "所有关键依赖验证通过"
    else
        log_success "依赖修复完成"
    fi
}

# ─── 配置向导 ────────────────────────────────────────────────────────────────
collect_config() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Odoo 17 一键部署脚本 v2.0 - 配置向导    ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}\n"

    # 断点续装提示
    if [[ -f "$PROGRESS_FILE" ]]; then
        log_warn "检测到上次安装记录，是否继续上次安装（断点续装）? [Y/n]"
        read -r resume_confirm
        if [[ ! "$resume_confirm" =~ ^[Nn]$ ]]; then
            log_info "继续上次安装..."
            if [[ -f /root/.odoo17_install_config ]]; then
                # shellcheck disable=SC1091
                source /root/.odoo17_install_config
                log_info "已读取上次配置: 域名=${DOMAIN}, SSL=${SSL_EMAIL:-无}"
                return
            fi
        else
            rm -f "$PROGRESS_FILE" /root/.odoo17_install_config
            log_info "已清除上次记录，重新开始安装"
        fi
    fi

    read -rp "请输入绑定域名 [默认: ${DOMAIN}]: " input
    DOMAIN="${input:-$DOMAIN}"

    read -rp "是否申请 Let's Encrypt SSL 证书? [y/N]: " ssl_confirm
    if [[ "$ssl_confirm" =~ ^[Yy]$ ]]; then
        read -rp "请输入 SSL 证书邮箱: " SSL_EMAIL
        while [[ -z "$SSL_EMAIL" ]]; do
            log_warn "邮箱不能为空！"
            read -rp "请输入 SSL 证书邮箱: " SSL_EMAIL
        done
    fi

    # 生成随机主控密码
    ADMIN_PASSWD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

    echo -e "\n${YELLOW}┌─────────────── 安装配置确认 ────────────────┐${NC}"
    echo -e "${YELLOW}│${NC} 域名         : ${DOMAIN}"
    echo -e "${YELLOW}│${NC} Odoo 版本    : ${ODOO_VERSION}"
    echo -e "${YELLOW}│${NC} SSL 证书     : ${SSL_EMAIL:-跳过}"
    echo -e "${YELLOW}│${NC} Worker 数量  : ${WORKERS}"
    echo -e "${YELLOW}│${NC} Redis 缓存   : ${INSTALL_REDIS}"
    echo -e "${YELLOW}│${NC} Swap 大小    : ${SWAP_SIZE}"
    echo -e "${YELLOW}│${NC} gevent 版本  : ${GEVENT_VERSION}（兼容 Python 3.10）"
    echo -e "${YELLOW}└──────────────────────────────────────────────┘${NC}\n"

    read -rp "确认开始安装? [y/N]: " final_confirm
    [[ "$final_confirm" =~ ^[Yy]$ ]] || { log_info "已取消安装。"; exit 0; }

    # 保存配置供断点续装使用
    cat > /root/.odoo17_install_config << EOF
DOMAIN="${DOMAIN}"
SSL_EMAIL="${SSL_EMAIL}"
ADMIN_PASSWD="${ADMIN_PASSWD}"
INSTALL_REDIS="${INSTALL_REDIS}"
SWAP_SIZE="${SWAP_SIZE}"
WORKERS="${WORKERS}"
EOF
    chmod 600 /root/.odoo17_install_config
}

# ─── Step 1: 系统初始化 ──────────────────────────────────────────────────────
step_system_init() {
    log_step "Step 1/10: 系统初始化"

    if is_done "system_init"; then
        log_skip "系统初始化已完成，跳过"
        return
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq

    local pkgs=(
        curl wget git unzip gnupg2 lsb-release ca-certificates
        build-essential libssl-dev libffi-dev python3-dev
        libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev
        libpq-dev libldap2-dev libsasl2-dev libxrender1
        libsasl2-modules libcups2-dev
        node-less npm xfonts-75dpi xfonts-base fontconfig
        python3-pip python3-venv ufw fail2ban
        libc-ares2 libc-ares-dev
    )

    local missing=()
    for pkg in "${pkgs[@]}"; do
        if ! check_apt_pkg "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "安装缺少的系统包: ${missing[*]}"
        apt-get install -y -qq "${missing[@]}"
    else
        log_skip "所有系统包已安装"
    fi

    timedatectl set-timezone Asia/Shanghai || true

    if ! id "$ODOO_USER" &>/dev/null; then
        adduser --system --home="$ODOO_HOME" --group "$ODOO_USER"
        log_success "已创建系统用户: $ODOO_USER"
    else
        log_skip "用户 $ODOO_USER 已存在"
    fi

    mkdir -p "${ODOO_HOME}"/{odoo17,custom-addons,logs,data,venv}
    chown -R "${ODOO_USER}:${ODOO_USER}" "$ODOO_HOME"

    mark_done "system_init"
    log_success "系统初始化完成"
}

# ─── Step 2: 安装 wkhtmltopdf ────────────────────────────────────────────────
step_wkhtmltopdf() {
    log_step "Step 2/10: 安装 wkhtmltopdf"

    if is_done "wkhtmltopdf"; then
        log_skip "wkhtmltopdf 已安装，跳过"
        return
    fi

    if check_cmd wkhtmltopdf; then
        local ver
        ver=$(wkhtmltopdf --version 2>&1 | head -1)
        log_skip "wkhtmltopdf 已安装: ${ver}"
        mark_done "wkhtmltopdf"
        return
    fi

    local DEB_FILE="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    local DL_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${DEB_FILE}"

    log_info "下载 wkhtmltopdf..."
    wget -q --show-progress -O "/tmp/${DEB_FILE}" "$DL_URL"
    apt-get install -y -qq "/tmp/${DEB_FILE}"
    rm -f "/tmp/${DEB_FILE}"

    mark_done "wkhtmltopdf"
    log_success "wkhtmltopdf 安装完成"
}

# ─── Step 3: 安装 PostgreSQL ─────────────────────────────────────────────────
step_postgresql() {
    log_step "Step 3/10: 安装并配置 PostgreSQL"

    if is_done "postgresql"; then
        log_skip "PostgreSQL 已配置，跳过"
        return
    fi

    if ! check_apt_pkg postgresql; then
        apt-get install -y -qq postgresql postgresql-client
    else
        log_skip "PostgreSQL 已安装"
    fi

    systemctl enable postgresql
    systemctl start postgresql

    if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" 2>/dev/null | grep -q 1; then
        su - postgres -c "createuser -d -R -S ${DB_USER}"
        log_success "已创建 PostgreSQL 用户: ${DB_USER}"
    else
        log_skip "PostgreSQL 用户 ${DB_USER} 已存在"
    fi

    PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

    # 幂等写入，避免重复追加
    if ! grep -q "Odoo 性能优化" "$PG_CONF"; then
        cat >> "$PG_CONF" << 'PGEOF'

# ── Odoo 性能优化 (2核2GB) ──
shared_buffers = 256MB
effective_cache_size = 768MB
work_mem = 16MB
maintenance_work_mem = 64MB
max_connections = 50
wal_buffers = 16MB
checkpoint_completion_target = 0.9
checkpoint_timeout = 10min
random_page_cost = 1.1
effective_io_concurrency = 200
PGEOF
        log_success "PostgreSQL 性能参数已写入"
    else
        log_skip "PostgreSQL 性能参数已存在"
    fi

    systemctl restart postgresql
    mark_done "postgresql"
    log_success "PostgreSQL 配置完成（版本 ${PG_VERSION}）"
}

# ─── Step 4: 配置 Swap ───────────────────────────────────────────────────────
step_swap() {
    log_step "Step 4/10: 配置 Swap 交换空间"

    if is_done "swap"; then
        log_skip "Swap 已配置，跳过"
        return
    fi

    if swapon --show | grep -q /swapfile; then
        log_skip "Swap 已启用"
        mark_done "swap"
        return
    fi

    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    mark_done "swap"
    log_success "已配置 ${SWAP_SIZE} Swap"
}

# ─── Step 5: 系统内核优化 ────────────────────────────────────────────────────
step_sysctl() {
    log_step "Step 5/10: 系统内核优化"

    if is_done "sysctl"; then
        log_skip "内核参数已优化，跳过"
        return
    fi

    if ! grep -q "Odoo VPS 性能优化" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'SYSEOF'

# ── Odoo VPS 性能优化 ──
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 100000
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSEOF
    fi

    sysctl -p > /dev/null

    if ! grep -q "odoo.*nofile" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << 'LIMEOF'
odoo soft nofile 65536
odoo hard nofile 65536
LIMEOF
    fi

    mark_done "sysctl"
    log_success "内核参数优化完成"
}

# ─── Step 6: 克隆 Odoo 源码 ──────────────────────────────────────────────────
step_odoo_clone() {
    log_step "Step 6/10: 克隆 Odoo ${ODOO_VERSION} 源码"

    if is_done "odoo_clone"; then
        log_skip "Odoo 源码已存在，跳过克隆"
        return
    fi

    if [[ -f "${ODOO_HOME}/odoo17/odoo-bin" ]]; then
        log_skip "Odoo 源码目录已存在"
        mark_done "odoo_clone"
        return
    fi

    log_info "正在克隆 Odoo ${ODOO_VERSION}（请耐心等待）..."
    sudo -u "$ODOO_USER" git clone \
        https://github.com/odoo/odoo \
        --depth 1 \
        --branch "$ODOO_VERSION" \
        --single-branch \
        "${ODOO_HOME}/odoo17"

    chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO_HOME}/odoo17"
    mark_done "odoo_clone"
    log_success "Odoo 源码克隆完成"
}

# ─── Step 7: 安装 Python 依赖（含依赖检测与自动修复）────────────────────────
step_odoo_pip() {
    log_step "Step 7/10: 安装 Python 依赖（含检测与修复）"

    local PIP="${ODOO_HOME}/venv/bin/pip"
    local PYTHON="${ODOO_HOME}/venv/bin/python3"

    # 创建或检查虚拟环境
    if [[ ! -f "$PYTHON" ]]; then
        log_info "创建 Python 虚拟环境..."
        sudo -u "$ODOO_USER" python3 -m venv "${ODOO_HOME}/venv"
    else
        log_skip "Python 虚拟环境已存在"
    fi

    # 升级基础工具
    log_info "升级 pip / wheel / setuptools..."
    sudo -u "$ODOO_USER" "$PIP" install -q --upgrade pip wheel setuptools

    # ── 关键修复：先锁定 greenlet，再装 gevent ───────────────────────────
    # gevent 21.x 与 Python 3.10 Cython 不兼容，必须用 22.10.2
    # greenlet 必须 >=2.0.0，requirements.txt 会将其降级到 1.x，故先锁定

    log_info "检测 greenlet 版本..."
    local gl_ver
    gl_ver=$(sudo -u "$ODOO_USER" "$PIP" show greenlet 2>/dev/null | grep "^Version:" | awk '{print $2}')
    local gl_major
    gl_major=$(echo "${gl_ver:-0}" | cut -d. -f1)

    if [[ "$gl_major" -lt 2 ]] || [[ -z "$gl_ver" ]]; then
        log_info "安装 greenlet>=${GREENLET_VERSION}..."
        sudo -u "$ODOO_USER" "$PIP" install -q \
            "greenlet>=${GREENLET_VERSION}" --force-reinstall
        log_success "greenlet 已安装: $(sudo -u "$ODOO_USER" "$PIP" show greenlet | grep Version | awk '{print $2}')"
    else
        log_skip "greenlet ${gl_ver} 版本符合要求"
    fi

    log_info "检测 gevent 版本..."
    local gv_ver
    gv_ver=$(sudo -u "$ODOO_USER" "$PIP" show gevent 2>/dev/null | grep "^Version:" | awk '{print $2}')
    if [[ "$gv_ver" != "$GEVENT_VERSION" ]]; then
        log_info "安装 gevent==${GEVENT_VERSION}..."
        sudo -u "$ODOO_USER" "$PIP" install -q \
            "gevent==${GEVENT_VERSION}" \
            --no-build-isolation \
            --force-reinstall
        log_success "gevent ${GEVENT_VERSION} 安装完成"
    else
        log_skip "gevent ${gv_ver} 版本符合要求"
    fi

    # ── 安装其余依赖（排除 gevent 行，防止版本被覆盖）────────────────────
    if ! is_done "odoo_pip_requirements"; then
        log_info "安装 requirements.txt 其余依赖..."

        grep -v "^gevent" "${ODOO_HOME}/odoo17/requirements.txt" \
            | grep -v "^#" \
            | grep -v "^[[:space:]]*$" \
            > /tmp/odoo17_req_fixed.txt

        sudo -u "$ODOO_USER" "$PIP" install -q \
            -r /tmp/odoo17_req_fixed.txt

        rm -f /tmp/odoo17_req_fixed.txt
        mark_done "odoo_pip_requirements"
        log_success "requirements.txt 依赖安装完成"
    else
        log_skip "requirements.txt 已安装过，跳过"
    fi

    # ── 安装后验证并自动修复 ────────────────────────────────────────────
    verify_pip_deps

    chown -R "${ODOO_USER}:${ODOO_USER}" "$ODOO_HOME"
    mark_done "odoo_pip"
    log_success "Python 依赖安装完成"
}

# ─── Step 8: 安装 Redis（可选）──────────────────────────────────────────────
step_redis() {
    log_step "Step 8/10: Redis 缓存"

    if [[ "$INSTALL_REDIS" != "true" ]]; then
        log_skip "已跳过 Redis 安装"
        return
    fi

    if is_done "redis"; then
        log_skip "Redis 已配置，跳过"
        return
    fi

    if ! check_apt_pkg redis-server; then
        apt-get install -y -qq redis-server
    else
        log_skip "redis-server 已安装"
    fi

    # 幂等配置内存限制
    if ! grep -q "^maxmemory 128mb" /etc/redis/redis.conf; then
        sed -i 's/^# maxmemory <bytes>/maxmemory 128mb/' /etc/redis/redis.conf
        grep -q "^maxmemory 128mb" /etc/redis/redis.conf || \
            echo "maxmemory 128mb" >> /etc/redis/redis.conf
    fi
    if ! grep -q "^maxmemory-policy allkeys-lru" /etc/redis/redis.conf; then
        sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
        grep -q "^maxmemory-policy allkeys-lru" /etc/redis/redis.conf || \
            echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf
    fi

    systemctl enable redis-server
    systemctl restart redis-server

    local PIP="${ODOO_HOME}/venv/bin/pip"
    if ! sudo -u "$ODOO_USER" "$PIP" show redis &>/dev/null; then
        sudo -u "$ODOO_USER" "$PIP" install -q redis
    else
        log_skip "redis python 包已安装"
    fi

    mark_done "redis"
    log_success "Redis 安装配置完成（最大内存 128MB）"
}

# ─── Step 9: Odoo 配置文件 & systemd 服务 ────────────────────────────────────
step_odoo_config() {
    log_step "Step 9/10: 生成 Odoo 配置 & 启动服务"

    if [[ ! -f "$ODOO_CONF" ]]; then
        cat > "$ODOO_CONF" << EOF
[options]
;; ── 基础配置 ──
admin_passwd = ${ADMIN_PASSWD}
db_host = localhost
db_port = 5432
db_user = ${DB_USER}
db_password = False
db_name = False

;; ── 路径 ──
addons_path = ${ODOO_HOME}/odoo17/addons,${ODOO_HOME}/custom-addons
data_dir = ${ODOO_HOME}/data
logfile = ${ODOO_LOG}

;; ── 网络 ──
xmlrpc_interface = 127.0.0.1
xmlrpc_port = ${ODOO_PORT}
longpolling_port = ${LONGPOLLING_PORT}

;; ── 性能优化（2核2GB）──
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = 1342177280
limit_memory_soft = 671088640
limit_time_cpu = 60
limit_time_real = 120
limit_request = 8192

;; ── 日志 ──
log_level = warn
log_handler = :WARNING

;; ── 安全 ──
list_db = False
EOF
        chmod 640 "$ODOO_CONF"
        chown "${ODOO_USER}:${ODOO_USER}" "$ODOO_CONF"
        log_success "Odoo 配置文件已生成"
    else
        log_skip "Odoo 配置文件已存在（如需重置请删除 ${ODOO_CONF}）"
    fi

    if [[ ! -f "/etc/systemd/system/${ODOO_SERVICE}.service" ]]; then
        cat > "/etc/systemd/system/${ODOO_SERVICE}.service" << EOF
[Unit]
Description=Odoo ${ODOO_VERSION} ERP
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO_HOME}/venv/bin/python3 ${ODOO_HOME}/odoo17/odoo-bin -c ${ODOO_CONF}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
PrivateTmp=true
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        log_success "systemd 服务文件已创建"
    else
        log_skip "systemd 服务文件已存在"
    fi

    systemctl daemon-reload
    systemctl enable "$ODOO_SERVICE"
    systemctl restart "$ODOO_SERVICE"

    log_info "等待 Odoo 启动..."
    local retry=0
    while [[ $retry -lt 15 ]]; do
        if systemctl is-active --quiet "$ODOO_SERVICE"; then
            log_success "Odoo 服务启动成功"
            break
        fi
        sleep 2
        ((retry++))
    done

    if ! systemctl is-active --quiet "$ODOO_SERVICE"; then
        log_error "Odoo 服务启动失败！查看最近日志："
        journalctl -u "$ODOO_SERVICE" -n 30 --no-pager
        exit 1
    fi

    mark_done "odoo_config"
}

# ─── Step 10: Nginx + SSL ─────────────────────────────────────────────────────
step_nginx_ssl() {
    log_step "Step 10/10: Nginx 反向代理 & SSL"

    if ! check_apt_pkg nginx; then
        apt-get install -y -qq nginx
    else
        log_skip "Nginx 已安装"
    fi

    # HTTPS 版配置（证书申请成功后启用）
    cat > "/etc/nginx/sites-available/${ODOO_SERVICE}" << NGINXEOF
upstream odoo17 {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoo17-longpolling {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    access_log /var/log/nginx/${ODOO_SERVICE}_access.log;
    error_log  /var/log/nginx/${ODOO_SERVICE}_error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    client_max_body_size 100m;

    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/less text/plain text/xml
               application/xml application/json application/javascript image/svg+xml;
    gzip_vary on;

    location ~* /web/static/ {
        proxy_cache_valid 200 90d;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo17;
    }

    location /websocket {
        proxy_pass http://odoo17-longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /longpolling/ {
        proxy_pass http://odoo17-longpolling;
    }

    location / {
        proxy_pass http://odoo17;
        proxy_redirect off;
    }
}
NGINXEOF

    # HTTP-only 版配置（SSL 前或跳过时使用）
    cat > "/etc/nginx/sites-available/${ODOO_SERVICE}-http" << NGINXEOF2
upstream odoo17_h {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoo17_lp_h {
    server 127.0.0.1:${LONGPOLLING_PORT};
}
server {
    listen 80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/${ODOO_SERVICE}_access.log;
    error_log  /var/log/nginx/${ODOO_SERVICE}_error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    client_max_body_size 100m;

    gzip on;
    gzip_types text/css text/plain application/json application/javascript image/svg+xml;

    location ~* /web/static/ { expires 7d; proxy_pass http://odoo17_h; }
    location /websocket {
        proxy_pass http://odoo17_lp_h;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /longpolling/ { proxy_pass http://odoo17_lp_h; }
    location / { proxy_pass http://odoo17_h; proxy_redirect off; }
}
NGINXEOF2

    rm -f /etc/nginx/sites-enabled/default

    # 先启用 HTTP-only 配置
    ln -sf "/etc/nginx/sites-available/${ODOO_SERVICE}-http" \
           "/etc/nginx/sites-enabled/${ODOO_SERVICE}"

    systemctl enable nginx
    nginx -t && systemctl restart nginx
    log_success "Nginx HTTP 配置已启用"

    # 申请 SSL 证书
    if [[ -n "$SSL_EMAIL" ]]; then
        if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            log_skip "SSL 证书已存在，跳过申请"
        else
            apt-get install -y -qq certbot python3-certbot-nginx

            log_info "申请 Let's Encrypt 证书..."
            certbot certonly --webroot \
                -w /var/www/html \
                -d "$DOMAIN" \
                --email "$SSL_EMAIL" \
                --agree-tos \
                --no-eff-email \
                --non-interactive || true
        fi

        if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
            rm -f "/etc/nginx/sites-enabled/${ODOO_SERVICE}"
            ln -sf "/etc/nginx/sites-available/${ODOO_SERVICE}" \
                   "/etc/nginx/sites-enabled/${ODOO_SERVICE}"

            nginx -t && systemctl reload nginx
            log_success "已切换到 HTTPS 配置"

            # 自动续期钩子
            mkdir -p /etc/letsencrypt/renewal-hooks/post
            cat > /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
            chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh
            systemctl enable certbot.timer 2>/dev/null || true
            log_success "SSL 自动续期已配置"
        else
            log_warn "证书申请失败，请确认域名 DNS 已解析到本机，Odoo 暂以 HTTP 运行"
            log_warn "后续手动申请: certbot --nginx -d ${DOMAIN} --email ${SSL_EMAIL} --agree-tos --no-eff-email"
        fi
    else
        log_warn "未配置 SSL 邮箱，Odoo 以 HTTP 运行"
        log_warn "后续申请命令: certbot --nginx -d ${DOMAIN} --email 邮箱 --agree-tos --no-eff-email"
    fi

    mark_done "nginx_ssl"
}

# ─── 防火墙 ──────────────────────────────────────────────────────────────────
step_firewall() {
    if is_done "firewall"; then
        log_skip "防火墙已配置，跳过"
        return
    fi

    log_info "配置 UFW 防火墙..."
    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow 22/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw allow 443/tcp > /dev/null
    ufw --force enable > /dev/null

    mark_done "firewall"
    log_success "防火墙配置完成（开放 22/80/443）"
}

# ─── 定期维护 ─────────────────────────────────────────────────────────────────
step_maintenance() {
    if is_done "maintenance"; then
        log_skip "维护任务已配置，跳过"
        return
    fi

    (crontab -u postgres -l 2>/dev/null | grep -v "vacuumdb"; \
     echo "0 3 * * 0 vacuumdb --all --analyze -q") | crontab -u postgres -

    mark_done "maintenance"
    log_success "已配置每周日 03:00 数据库自动维护"
}

# ─── 部署摘要 ─────────────────────────────────────────────────────────────────
print_summary() {
    local PROTOCOL="http"
    [[ -n "$SSL_EMAIL" && -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] && PROTOCOL="https"

    # 断点续装时从配置文件恢复密码
    local display_passwd="${ADMIN_PASSWD}"
    if [[ -z "$display_passwd" && -f /root/.odoo17_install_config ]]; then
        display_passwd=$(grep "ADMIN_PASSWD" /root/.odoo17_install_config | cut -d'"' -f2)
    fi

    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Odoo 17 部署完成！                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${CYAN}访问地址      :${NC} ${PROTOCOL}://${DOMAIN}"
    echo -e "${CYAN}Odoo 主控密码 :${NC} ${RED}${display_passwd}${NC}"
    echo -e "${YELLOW}⚠️  主控密码用于创建/删除数据库，请立即保存！${NC}\n"

    echo -e "${CYAN}配置文件 :${NC} ${ODOO_CONF}"
    echo -e "${CYAN}Odoo日志 :${NC} ${ODOO_LOG}"
    echo -e "${CYAN}Nginx    :${NC} /etc/nginx/sites-available/${ODOO_SERVICE}\n"

    echo -e "${CYAN}常用命令：${NC}"
    echo -e "  systemctl [start|stop|restart] ${ODOO_SERVICE}"
    echo -e "  journalctl -u ${ODOO_SERVICE} -f"
    echo -e "  tail -f ${ODOO_LOG}\n"

    echo -e "${CYAN}首次使用：${NC}"
    echo -e "  1. 打开 ${PROTOCOL}://${DOMAIN}"
    echo -e "  2. 创建数据库（主控密码填上方红色密码）"
    echo -e "  3. 设置管理员账号，开始使用 Odoo 17\n"

    cat > /root/odoo17-deploy-info.txt << EOF
Odoo 17 部署信息
================
部署时间   : $(date)
访问地址   : ${PROTOCOL}://${DOMAIN}
主控密码   : ${display_passwd}
配置文件   : ${ODOO_CONF}
Odoo 日志  : ${ODOO_LOG}
gevent版本 : ${GEVENT_VERSION}
EOF
    chmod 600 /root/odoo17-deploy-info.txt
    echo -e "${GREEN}部署信息已保存至 /root/odoo17-deploy-info.txt${NC}"

    # 清理临时配置文件
    rm -f /root/.odoo17_install_config
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
main() {
    check_root
    check_os
    collect_config

    step_system_init
    step_wkhtmltopdf
    step_postgresql
    step_swap
    step_sysctl
    step_odoo_clone
    step_odoo_pip        # 含依赖检测 & 自动修复
    step_redis
    step_odoo_config
    step_nginx_ssl
    step_firewall
    step_maintenance

    print_summary
}

main "$@"
