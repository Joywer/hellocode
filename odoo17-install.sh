#!/bin/bash
# =============================================================================
#  Odoo 17 一键安装脚本
#  适用系统：Ubuntu 22.04 LTS
#  配置目标：2核 2GB RAM VPS
#  作者：Auto-generated deployment script
# =============================================================================

set -euo pipefail

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
log_success() { echo -e "${GREEN}[✔]${NC} $1"; }

# ─── 配置变量（按需修改）────────────────────────────────────────────────────
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
WORKERS="2"              # 建议等于CPU核心数
MAX_CRON_THREADS="1"
SWAP_SIZE="2G"
INSTALL_REDIS="true"    # 是否安装 Redis（建议 true）
SSL_EMAIL=""            # Let's Encrypt 邮箱（留空则跳过SSL申请）

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

collect_config() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Odoo 17 一键部署脚本 - 配置向导       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}\n"

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

    # 生成随机密码
    ADMIN_PASSWD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    log_info "已自动生成 Odoo 主控密码（请妥善保存）"

    echo -e "\n${YELLOW}┌─────────────── 安装配置确认 ───────────────┐${NC}"
    echo -e "${YELLOW}│${NC} 域名         : ${DOMAIN}"
    echo -e "${YELLOW}│${NC} Odoo 版本    : ${ODOO_VERSION}"
    echo -e "${YELLOW}│${NC} SSL 证书     : ${SSL_EMAIL:-跳过}"
    echo -e "${YELLOW}│${NC} Worker 数量  : ${WORKERS}"
    echo -e "${YELLOW}│${NC} Redis 缓存   : ${INSTALL_REDIS}"
    echo -e "${YELLOW}│${NC} Swap 大小    : ${SWAP_SIZE}"
    echo -e "${YELLOW}└─────────────────────────────────────────────┘${NC}\n"

    read -rp "确认开始安装? [y/N]: " final_confirm
    [[ "$final_confirm" =~ ^[Yy]$ ]] || { log_info "已取消安装。"; exit 0; }
}

# ─── Step 1: 系统初始化 ──────────────────────────────────────────────────────
step_system_init() {
    log_step "Step 1/10: 系统初始化"

    apt-get update -qq
    apt-get upgrade -y -qq

    apt-get install -y -qq \
        curl wget git unzip gnupg2 lsb-release ca-certificates \
        build-essential libssl-dev libffi-dev python3-dev \
        libxml2-dev libxslt1-dev zlib1g-dev libjpeg-dev \
        libpq-dev libldap2-dev libsasl2-dev libxrender1 \
        node-less npm xfonts-75dpi xfonts-base fontconfig \
        python3-pip python3-venv ufw fail2ban

    timedatectl set-timezone Asia/Shanghai || true

    # 创建 odoo 系统用户
    if ! id "$ODOO_USER" &>/dev/null; then
        adduser --system --home="$ODOO_HOME" --group "$ODOO_USER"
        log_success "已创建系统用户: $ODOO_USER"
    else
        log_warn "用户 $ODOO_USER 已存在，跳过创建"
    fi

    # 创建目录结构
    mkdir -p "${ODOO_HOME}"/{odoo17,custom-addons,logs,data,venv}
    chown -R "${ODOO_USER}:${ODOO_USER}" "$ODOO_HOME"

    log_success "系统初始化完成"
}

# ─── Step 2: 安装 wkhtmltopdf ────────────────────────────────────────────────
step_wkhtmltopdf() {
    log_step "Step 2/10: 安装 wkhtmltopdf"

    if command -v wkhtmltopdf &>/dev/null; then
        log_warn "wkhtmltopdf 已安装，跳过"
        return
    fi

    local DEB_FILE="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    local DL_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${DEB_FILE}"

    wget -q --show-progress -O "/tmp/${DEB_FILE}" "$DL_URL"
    apt-get install -y "/tmp/${DEB_FILE}"
    rm -f "/tmp/${DEB_FILE}"

    log_success "wkhtmltopdf $(wkhtmltopdf --version | head -1) 安装完成"
}

# ─── Step 3: 安装 PostgreSQL ─────────────────────────────────────────────────
step_postgresql() {
    log_step "Step 3/10: 安装并配置 PostgreSQL"

    apt-get install -y -qq postgresql postgresql-client
    systemctl enable postgresql
    systemctl start postgresql

    # 创建 Odoo 数据库用户
    if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1; then
        su - postgres -c "createuser -d -R -S ${DB_USER}"
        log_success "已创建 PostgreSQL 用户: ${DB_USER}"
    else
        log_warn "PostgreSQL 用户 ${DB_USER} 已存在，跳过"
    fi

    # 获取 PostgreSQL 版本目录
    PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

    # 性能调优（针对2GB RAM）
    cat >> "$PG_CONF" << 'EOF'

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
EOF

    systemctl restart postgresql
    log_success "PostgreSQL 安装并调优完成（版本 ${PG_VERSION}）"
}

# ─── Step 4: 配置 Swap ───────────────────────────────────────────────────────
step_swap() {
    log_step "Step 4/10: 配置 Swap 交换空间"

    if swapon --show | grep -q /swapfile; then
        log_warn "Swap 已配置，跳过"
        return
    fi

    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # 调整内存策略
    {
        echo "vm.swappiness=10"
        echo "vm.vfs_cache_pressure=50"
    } >> /etc/sysctl.conf

    sysctl -p > /dev/null
    log_success "已配置 ${SWAP_SIZE} Swap"
}

# ─── Step 5: 安装 Odoo 17 ───────────────────────────────────────────────────
step_odoo_install() {
    log_step "Step 5/10: 安装 Odoo ${ODOO_VERSION}"

    # 克隆源码
    if [[ ! -f "${ODOO_HOME}/odoo17/odoo-bin" ]]; then
        log_info "正在克隆 Odoo ${ODOO_VERSION}（仅最新提交，请耐心等待）..."
        sudo -u "$ODOO_USER" git clone \
            https://github.com/odoo/odoo \
            --depth 1 \
            --branch "$ODOO_VERSION" \
            --single-branch \
            "${ODOO_HOME}/odoo17"
        log_success "Odoo 源码克隆完成"
    else
        log_warn "Odoo 源码已存在，跳过克隆"
    fi

    # 创建虚拟环境并安装依赖
    log_info "正在创建 Python 虚拟环境..."
    sudo -u "$ODOO_USER" python3 -m venv "${ODOO_HOME}/venv"

    log_info "正在安装 Python 依赖（可能需要5-10分钟）..."
    sudo -u "$ODOO_USER" "${ODOO_HOME}/venv/bin/pip" install -q --upgrade pip wheel setuptools

    # 预先安装兼容版本的 gevent（原版与 Python 3.10 存在 Cython 兼容性问题）
    log_info "预装兼容版本 gevent..."
    sudo -u "$ODOO_USER" "${ODOO_HOME}/venv/bin/pip" install -q \
        "gevent==22.10.2" --no-build-isolation

    sudo -u "$ODOO_USER" "${ODOO_HOME}/venv/bin/pip" install -q \
        --ignore-installed gevent \
        -r "${ODOO_HOME}/odoo17/requirements.txt"

    chown -R "${ODOO_USER}:${ODOO_USER}" "$ODOO_HOME"
    log_success "Odoo ${ODOO_VERSION} 安装完成"
}

# ─── Step 6: 安装 Redis（可选）──────────────────────────────────────────────
step_redis() {
    if [[ "$INSTALL_REDIS" != "true" ]]; then
        return
    fi

    log_step "Step 6/10: 安装 Redis"

    apt-get install -y -qq redis-server

    # Redis 内存限制配置
    sed -i 's/^# maxmemory <bytes>/maxmemory 128mb/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

    systemctl enable redis-server
    systemctl start redis-server

    # 安装 Odoo redis 依赖
    sudo -u "$ODOO_USER" "${ODOO_HOME}/venv/bin/pip" install -q redis

    log_success "Redis 安装完成（最大内存 128MB）"
}

# ─── Step 7: 生成 Odoo 配置文件 ─────────────────────────────────────────────
step_odoo_config() {
    log_step "Step 7/10: 生成 Odoo 配置文件"

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

    log_success "Odoo 配置文件生成: ${ODOO_CONF}"
}

# ─── Step 8: 配置 systemd 服务 ──────────────────────────────────────────────
step_systemd() {
    log_step "Step 8/10: 配置 systemd 服务"

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

[Install]
WantedBy=multi-user.target
EOF

    # 增加文件描述符限制
    mkdir -p "/etc/systemd/system/${ODOO_SERVICE}.service.d"
    cat > "/etc/systemd/system/${ODOO_SERVICE}.service.d/limits.conf" << EOF
[Service]
LimitNOFILE=65536
EOF

    systemctl daemon-reload
    systemctl enable "$ODOO_SERVICE"
    systemctl start "$ODOO_SERVICE"

    # 等待启动
    sleep 5
    if systemctl is-active --quiet "$ODOO_SERVICE"; then
        log_success "Odoo 服务已启动"
    else
        log_error "Odoo 服务启动失败，请查看日志: journalctl -u ${ODOO_SERVICE} -n 50"
        exit 1
    fi
}

# ─── Step 9: 配置 Nginx ──────────────────────────────────────────────────────
step_nginx() {
    log_step "Step 9/10: 安装配置 Nginx"

    apt-get install -y -qq nginx

    # 先创建 HTTP 配置（用于 certbot 验证）
    cat > "/etc/nginx/sites-available/${ODOO_SERVICE}" << EOF
upstream odoo17 {
    server 127.0.0.1:${ODOO_PORT};
}

upstream odoo17-longpolling {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

# HTTP → HTTPS 重定向 / certbot 验证
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

# HTTPS 主配置
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

    location ~* /web/static/ {
        proxy_cache_valid 200 90d;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo17;
    }

    gzip on;
    gzip_min_length 1100;
    gzip_buffers 4 32k;
    gzip_types text/css text/less text/plain text/xml
               application/xml application/json application/javascript
               image/svg+xml;
    gzip_vary on;

    client_max_body_size 100m;

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
EOF

    # 仅HTTP配置（SSL申请前或跳过SSL时使用）
    cat > "/etc/nginx/sites-available/${ODOO_SERVICE}-http-only" << EOF
upstream odoo17_http {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoo17-longpolling-http {
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

    location ~* /web/static/ {
        expires 7d;
        proxy_pass http://odoo17_http;
    }

    location /websocket {
        proxy_pass http://odoo17-longpolling-http;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /longpolling/ {
        proxy_pass http://odoo17-longpolling-http;
    }

    location / {
        proxy_pass http://odoo17_http;
        proxy_redirect off;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default

    # 先用 HTTP-only 配置启动
    ln -sf "/etc/nginx/sites-available/${ODOO_SERVICE}-http-only" \
           "/etc/nginx/sites-enabled/${ODOO_SERVICE}"

    systemctl enable nginx
    nginx -t && systemctl restart nginx

    log_success "Nginx 配置完成"
}

# ─── Step 10: 申请 SSL 证书 ──────────────────────────────────────────────────
step_ssl() {
    log_step "Step 10/10: SSL 证书配置"

    if [[ -z "$SSL_EMAIL" ]]; then
        log_warn "未提供邮箱，跳过 SSL 证书申请"
        log_warn "Odoo 将以 HTTP 模式运行，生产环境请手动申请 SSL"
        log_warn "申请命令: certbot --nginx -d ${DOMAIN} --email your@email.com --agree-tos --no-eff-email"
        return
    fi

    apt-get install -y -qq certbot python3-certbot-nginx

    log_info "正在申请 Let's Encrypt 证书..."
    certbot certonly --webroot \
        -w /var/www/html \
        -d "$DOMAIN" \
        --email "$SSL_EMAIL" \
        --agree-tos \
        --no-eff-email \
        --non-interactive

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        # 切换到 HTTPS 配置
        rm -f "/etc/nginx/sites-enabled/${ODOO_SERVICE}"
        ln -sf "/etc/nginx/sites-available/${ODOO_SERVICE}" \
               "/etc/nginx/sites-enabled/${ODOO_SERVICE}"

        nginx -t && systemctl reload nginx
        log_success "SSL 证书申请成功，已切换到 HTTPS 配置"

        # 配置自动续期钩子
        cat > /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh

        systemctl enable certbot.timer
        log_success "SSL 自动续期已配置"
    else
        log_error "证书申请失败，请检查域名 DNS 是否已解析到本服务器"
        log_warn "Odoo 将继续以 HTTP 模式运行"
    fi
}

# ─── 系统内核优化 ────────────────────────────────────────────────────────────
step_sysctl() {
    log_info "应用系统内核优化参数..."

    cat >> /etc/sysctl.conf << 'EOF'

# ── Odoo VPS 性能优化 ──
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 100000
EOF

    sysctl -p > /dev/null
    log_success "内核参数优化完成"
}

# ─── 配置防火墙 ──────────────────────────────────────────────────────────────
step_firewall() {
    log_info "配置 UFW 防火墙..."

    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow 22/tcp > /dev/null    # SSH
    ufw allow 80/tcp > /dev/null    # HTTP
    ufw allow 443/tcp > /dev/null   # HTTPS
    ufw --force enable > /dev/null

    log_success "防火墙配置完成（开放 22/80/443）"
}

# ─── 配置定期维护 Cron ───────────────────────────────────────────────────────
step_maintenance() {
    log_info "配置数据库定期维护..."

    # 每周日凌晨3点 VACUUM
    (crontab -u postgres -l 2>/dev/null; \
     echo "0 3 * * 0 vacuumdb --all --analyze -q") | crontab -u postgres -

    log_success "已配置每周日 03:00 自动数据库维护"
}

# ─── 输出部署摘要 ────────────────────────────────────────────────────────────
print_summary() {
    local PROTOCOL="http"
    [[ -n "$SSL_EMAIL" ]] && PROTOCOL="https"

    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              🎉  Odoo 17 部署完成！                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${CYAN}── 访问信息 ────────────────────────────────────────────────${NC}"
    echo -e "  访问地址   : ${PROTOCOL}://${DOMAIN}"
    echo -e "  Odoo 端口  : ${ODOO_PORT} (仅本地，由Nginx代理)"
    echo -e ""
    echo -e "${CYAN}── 重要密码（请立即保存！）────────────────────────────────${NC}"
    echo -e "  Odoo 主控密码 : ${RED}${ADMIN_PASSWD}${NC}"
    echo -e "  ${YELLOW}⚠️  此密码用于创建/删除数据库，请务必记录！${NC}"
    echo -e ""
    echo -e "${CYAN}── 配置文件位置 ────────────────────────────────────────────${NC}"
    echo -e "  Odoo 配置   : ${ODOO_CONF}"
    echo -e "  Odoo 日志   : ${ODOO_LOG}"
    echo -e "  Nginx 配置  : /etc/nginx/sites-available/${ODOO_SERVICE}"
    echo -e ""
    echo -e "${CYAN}── 常用命令 ─────────────────────────────────────────────────${NC}"
    echo -e "  启停服务    : systemctl [start|stop|restart] ${ODOO_SERVICE}"
    echo -e "  查看日志    : journalctl -u ${ODOO_SERVICE} -f"
    echo -e "  查看日志    : tail -f ${ODOO_LOG}"
    echo -e "  Nginx重载   : systemctl reload nginx"
    echo -e ""
    echo -e "${CYAN}── 首次使用步骤 ─────────────────────────────────────────────${NC}"
    echo -e "  1. 打开浏览器访问 ${PROTOCOL}://${DOMAIN}"
    echo -e "  2. 创建数据库，主控密码填写上方红色密码"
    echo -e "  3. 设置数据库名、管理员邮箱和密码"
    echo -e "  4. 开始使用 Odoo 17！"
    echo -e ""

    # 将摘要写入文件
    cat > /root/odoo17-deploy-info.txt << EOF
Odoo 17 部署信息
================
部署时间   : $(date)
访问地址   : ${PROTOCOL}://${DOMAIN}
主控密码   : ${ADMIN_PASSWD}
配置文件   : ${ODOO_CONF}
Odoo 日志  : ${ODOO_LOG}
EOF
    chmod 600 /root/odoo17-deploy-info.txt
    echo -e "  ${GREEN}✔ 部署信息已保存至 /root/odoo17-deploy-info.txt${NC}\n"
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
    step_odoo_install
    step_redis
    step_odoo_config
    step_systemd
    step_nginx
    step_ssl
    step_firewall
    step_maintenance

    print_summary
}

main "$@"
