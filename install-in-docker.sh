#!/bin/bash
# Sniper 一键安装脚本

set -e

# ================================
# 颜色
# ================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ================================
# 日志
# ================================
log_info(){ echo -e "${GREEN}[SNIPER-INSTALL]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[SNIPER-INSTALL]${NC} $1"; }
log_error(){ echo -e "${RED}[SNIPER-INSTALL]${NC} $1"; }

# ================================
# Root 检查
# ================================
check_root(){
    if [ "$EUID" -ne 0 ]; then
        log_error "必须使用 root 运行，请使用：sudo bash $0"
        exit 1
    fi
    log_info "Root 权限检查通过 ✓"
}

# ================================
# CPU 架构检查
# ================================
check_architecture(){
    log_info "检查 CPU 架构..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            log_info "CPU 架构：$ARCH ✓"
            ;;
        *)
            log_error "不支持的 CPU 架构：$ARCH（仅支持 x86_64 / amd64）"
            exit 1
            ;;
    esac
}

# ================================
# 操作系统检查
# ================================
check_os(){
    log_info "检测操作系统..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "系统：$NAME $VERSION_ID"
    else
        log_error "无法识别系统（缺少 /etc/os-release）"
        exit 1
    fi
}

# ================================
# Docker 检查与安装
# ================================
check_docker() {
    log_info "检查 Docker 环境..."
    # ============================================
    # 1. 检查是否安装 docker 命令
    # ============================================
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "未检测到 Docker，正在自动安装..."
        install_docker
    else
        log_info "检测到 Docker 命令已安装 ✓"
    fi
    # ============================================
    # 2. 检查 Docker 服务是否运行
    # ============================================
    log_info "检查 Docker 服务..."

    if systemctl is-active --quiet docker; then
        log_info "Docker 服务正在运行 ✓"
    else
        log_warn "Docker 服务未运行，尝试启动..."
        systemctl start docker

        sleep 1

        if systemctl is-active --quiet docker; then
            log_info "Docker 服务已成功启动 ✓"
        else
            log_error "Docker 服务启动失败！"
            journalctl -u docker -n 50 --no-pager
            exit 1
        fi
    fi


    # ============================================
    # 3. 设置开机自启（如果未启用）
    # ============================================
    if systemctl is-enabled --quiet docker; then
        log_info "Docker 已设置为开机自启 ✓"
    else
        log_warn "Docker 未设置开机自启，正在启用..."
        systemctl enable docker
        systemctl daemon-reload

        if systemctl is-enabled --quiet docker; then
            log_info "Docker 开机自启配置成功 ✓"
        else
            log_warn "Docker 开机自启配置失败（不影响本次执行） ✗"
        fi
    fi


    # ============================================
    # 4. 检查 Docker 权限是否正常
    # ============================================
    log_info "检查 Docker 权限..."
    if docker info >/dev/null 2>&1; then
        log_info "Docker 权限正常 ✓"
    else
        log_error "Docker 权限异常！（可能是权限问题或 Docker Daemon 未正常启动）"
        docker info || true
        exit 1
    fi

    log_info "Docker 环境检查完成 ✓"
}
# ============================================================
# Docker 自动安装函数
# ============================================================
install_docker() {
    log_info "开始自动安装 Docker..."

    if command -v apt-get >/dev/null 2>&1; then
        # ------------------------------------------------
        # Ubuntu / Debian
        # ------------------------------------------------
        log_info "检测到系统：Ubuntu / Debian"

        apt-get update -y
        apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
          "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
          > /etc/apt/sources.list.d/docker.list

        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        log_error "无法识别系统，无法自动安装 Docker！"
        exit 1
    fi


    # ------------------------------------------------
    # 启动服务
    # ------------------------------------------------
    log_info "启动 Docker 服务..."
    systemctl enable docker
    systemctl daemon-reload
    systemctl start docker
    sleep 2
    if systemctl is-active --quiet docker; then
        log_info "Docker 安装并启动成功 ✓"
    else
        log_error "Docker 服务启动失败！"
        journalctl -u docker -n 50 --no-pager
        exit 1
    fi
}
# ================================
# 安装二维码工具
# ================================
install_qr(){
    log_info "检查二维码生成工具..."

    if command -v qrencode >/dev/null 2>&1; then
        log_info "qrencode 已安装 ✓"
        return
    fi

    log_warn "qrencode 未安装，开始安装..."
    apt-get update
    apt-get install -y qrencode
    log_info "qrencode 安装完成 ✓"
}
# ================================
# 生成随机字符串
# ================================
generate_random(){
    local length=$1
    tr -dc A-Za-z0-9 </dev/urandom | head -c $length
}

# ================================
# 生成 2FA Secret（Base32）
# ================================
generate_2fa_secret(){
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    local secret=""
    for i in $(seq 1 32); do
        secret="${secret}${chars:RANDOM%32:1}"
    done
    echo "$secret"
}

# ================================
# 公网 IP 获取
# ================================
get_public_ip(){
    log_info "尝试获取公网 IP..."
    IP=$(curl -s https://api.ipify.org || true)

    if [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_info "检测到公网 IP：$IP"
        SERVER_IP="$IP"
    else
        log_warn "自动获取失败，请手动输入公网 IP："
        read -p "IP: " SERVER_IP
    fi
}

# ================================
# 部署 Sniper
# ================================
deploy_sniper(){
    IMAGE="sniper327/sniper:latest"
    CONTAINER="sniper"
	CONFIG_DIR="/data/sniper/config"
    DB_DIR="/data/sniper/db"

    log_info "创建配置文件目录"
    mkdir -p $CONFIG_DIR
    mkdir -p $DB_DIR

    log_info "生成配置：JWT + 2FA"
    JWT_SECRET=$(generate_random 32)
    TWO_FA_SECRET=$(generate_2fa_secret)
    ADMIN_PASSWORD="admin"

    # 创建 .env
    cat > $CONFIG_DIR/.env <<EOF
    PORT=8870
    SERVER_IP=$SERVER_IP
    ADMIN_PASSWORD=$ADMIN_PASSWORD
    JWT_SECRET=$JWT_SECRET
    TWO_FA_SECRET=$TWO_FA_SECRET
EOF

    log_info ".env 配置文件已生成：sniper-server/.env"
    log_info "拉取最新 Sniper 镜像..."
    docker pull $IMAGE

	log_info "停止并删除旧容器..."
	docker stop $CONTAINER 2>/dev/null || true
	docker rm $CONTAINER 2>/dev/null || true

    log_info "启动 Sniper 容器..."
    docker run -d \
        --name $CONTAINER \
        --restart always \
        --add-host=host.docker.internal:host-gateway \
        -p 8870:8870 \
        -v $CONFIG_DIR/.env:/app/server/src/.env \
        -v $DB_DIR:/app/db \
        $IMAGE
    docker run -d \
        --name watchtower \
        --restart always \
        -p 127.0.0.1:9090:8080 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        containrrr/watchtower \
        --http-api-update \
        --cleanup \
        --interval 0 \
        sniper    
	# 启动后等待 5 秒
	sleep 5
	# 1) 检查容器是否存在
	if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER$"; then
		log_error "容器未创建成功！"
		exit 1
	fi

	# 2) 检查容器是否处于 running 状态
	if ! docker ps --format '{{.Names}} {{.Status}}' | grep -q "^$CONTAINER .*Up"; then
		log_error "容器启动失败！（容器未处于 Up 状态）"
		echo -e "\n${YELLOW}=== Sniper 容器日志（最近 50 行） ===${NC}"
		docker logs --tail 50 $CONTAINER
		exit 1
	fi

	# 3) 检测端口是否监听
	if ! ss -tln | grep -q ":8870"; then
		log_warn "容器运行中，但 8870 端口未监听，可能程序未正确启动。"
		echo -e "\n${YELLOW}=== Sniper 容器日志（最近 50 行） ===${NC}"
		docker logs --tail 50 $CONTAINER
		exit 1
	fi
    log_info "Sniper 容器启动成功 ✓"
}
show_qrcode(){
    local secret=$1

    local uri="otpauth://totp/Sniper?secret=${secret}&issuer=Sniper"

    echo -e "\n${BLUE}📱 使用 Google Authenticator 扫描以下二维码：${NC}\n"
    
    qrencode -t ANSI "${uri}"
    
    echo -e "\n${GREEN}手动添加密钥：${NC} ${YELLOW}$secret${NC}"
}
# ================================
# 安装完成展示
# ================================
show_result(){
    echo -e "\n${GREEN}🎉 Sniper 安装完成！${NC}"
    echo -e "🌐 访问地址： ${GREEN}http://$SERVER_IP:8870${NC}"
    echo -e "🔑 管理密码： ${YELLOW}$ADMIN_PASSWORD${NC}"
    echo -e "📱 2FA 密钥： ${YELLOW}$TWO_FA_SECRET${NC}"
    echo -e "📁 配置文件： ${GREEN}$CONFIG_DIR/.env${NC}"
	show_qrcode "$TWO_FA_SECRET"
    echo ""
}

# ================================
# 主函数
# ================================
main(){
    echo -e "${BLUE}"
    echo "  ███████╗███╗   ██╗██╗ ██████╗███████╗██████╗ "
    echo "  ██╔════╝████╗  ██║██║ ██╔══██╗██╔════╝██╔══██╗"
    echo "  ███████╗██╔██╗ ██║██║ ██████╔╝█████╗  ██████╔╝"
    echo "  ╚════██║██║╚██╗██║██║ ██╔═══╝ ██╔══╝  ██╔══██╗"
    echo "  ███████║██║ ╚████║██║ ██║     ███████╗██║  ██║"
    echo "  ╚══════╝╚═╝  ╚═══╝╚═╝ ╚═╝     ╚══════╝╚═╝  ╚═╝ "
    echo
    echo "               🚀 SNIPER INSTALLER"
    echo -e "${NC}"
    check_root
    check_architecture
    check_os
    check_docker
	install_qr
    get_public_ip
    deploy_sniper
    show_result
}

main