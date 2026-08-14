#!/bin/env bash

# shellcheck disable=SC2120
# shellcheck disable=SC2154
# ! SoftEther VPN Server 자동 설치 스크립트 (Ubuntu x64)

# ! --- 설정 변수 ---
DOWNLOAD_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.44-9807-rtm/softether-vpnserver-v4.44-9807-rtm-2025.04.16-linux-x64-64bit.tar.gz"
SERVICE_NAME="vpnserver"
INSTALL_DIR="/usr/local/vpnserver"
SERVICE_USER="root"
SERVICE_GROUP="root"
TEMP_DIR="/tmp/softether_install"
SERVICE_FILE="/etc/systemd/system/vpnserver.service"
INIT_D_SCRIPT="/etc/init.d/vpnserver"

# ! --- 함수 정의 ---

# ! 필요한 의존성 패키지 설치
install_dependencies() {
    echo "--- 시스템 업데이트 및 필수 의존성 설치 중 ---"
    apt update -y
    apt upgrade -y
    apt install -y build-essential
    if [ $? -ne 0 ]; then
        echo "오류: 의존성 패키지 설치에 실패했습니다."
        exit 1
    fi
    echo "--- 의존성 설치 완료 ---"
}

# ! SoftEther 다운로드 및 압축 해제
download_and_extract() {
    echo "--- SoftEther VPN Server 다운로드 및 압축 해제 중 ---"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1

    wget "$DOWNLOAD_URL" -O softether.tar.gz
    if [ $? -ne 0 ]; then
        echo "오류: SoftEther VPN Server 다운로드에 실패했습니다. URL을 확인하세요."
        exit 1
    fi

    tar -xzf softether.tar.gz
    if [ $? -ne 0 ]; then
        echo "오류: 압축 해제에 실패했습니다."
        exit 1
    fi
    echo "--- 다운로드 및 압축 해제 완료 ---"
}

# ! SoftEther 컴파일
compile_softether() {
    echo "--- SoftEther VPN Server 컴파일 중 ---"
    cd vpnserver || exit 1
    # ! SoftEther 컴파일러는 라이선스 동의를 묻습니다 (3번)
    # ! 'yes 1'을 사용하여 자동으로 '1'을 입력하여 동의합니다.
    yes 1 | make
    if [ $? -ne 0 ]; then
        echo "오류: SoftEther VPN Server 컴파일에 실패했습니다."
        exit 1
    fi
    echo "--- 컴파일 완료 ---"
}

# ! 설치 디렉토리 생성
create_install_dir() {
    echo "--- 설치 디렉토리 생성 중 ---"
    mkdir -p "$INSTALL_DIR"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
    echo "--- 디렉토리 생성 완료 ---"
}

# ! 컴파일된 파일 설치
install_files() {
    echo "--- 컴파일된 파일 설치 중 ---"
    # @ 현재 디렉토리가 vpnserver/ 여야 합니다 (compile_softether 함수 이후)
    cp vpnserver vpncmd hamcore.se2 "$INSTALL_DIR"

    # @ 필요한 경우, 컴파일된 바이너리에만 실행 권한을 부여하고 나머지는 읽기 전용으로 두는 것이 좋습니다.
    chmod 600 "$INSTALL_DIR"/*
    chmod 700 "$INSTALL_DIR"/vpncmd
    chmod 700 "$INSTALL_DIR"/vpnserver
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$INSTALL_DIR"
    echo "--- 파일 설치 완료 ---"
}

# ! systemd 서비스 파일 생성 및 개선된 내용 적용
create_systemd_service() {
    echo "--- systemd 서비스 파일 생성 중 ---"
    cat <<EOF | sudo tee "$SERVICE_FILE"
[Unit]
Description=SoftEther VPN Server
After=network.target network-online.target

[Service]
# Type을 forking에서 simple로 변경하고 PIDFile 제거
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${INSTALL_DIR}/vpnserver execsvc
ExecStop=${INSTALL_DIR}/vpnserver stop
ExecReload=${INSTALL_DIR}/vpnserver restart
WorkingDirectory=${INSTALL_DIR}
# PIDFile=/var/lock/subsys/vpnserver.pid # PIDFile 지시자 제거
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -ne 0 ]; then
        echo "오류: systemd 서비스 파일 생성에 실패했습니다."
        exit 1
    fi
    echo "--- systemd 서비스 파일 생성 완료 ---"
}

# ! init.d 스크립트 생성 및 INIT INFO 블록 추가
create_init_d_script() {
    echo "--- /etc/init.d/vpnserver 스크립트 생성 중 ---"
    cat <<EOF | sudo tee "$INIT_D_SCRIPT"
#!/bin/sh
### BEGIN INIT INFO
# Provides:          vpnserver
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: SoftEther VPN Server
# Description:       Starts the SoftEther VPN Server daemon
### END INIT INFO

DAEMON=${INSTALL_DIR}/vpnserver
# PID_FILE=/var/lock/subsys/vpnserver.pid # init.d 스크립트에서도 PID_FILE 사용 안함

case "$1" in
  start)
    # ExecStart와 동일하게 execsvc로 실행
    $DAEMON execsvc
    ;;
  stop)
    $DAEMON stop
    ;;
  restart)
    $DAEMON stop
    $DAEMON execsvc
    ;;
  status)
    $DAEMON status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
esac

exit 0
EOF

    if [ $? -ne 0 ]; then
        echo "오류: /etc/init.d/vpnserver 스크립트 생성에 실패했습니다."
        exit 1
    fi

    chmod +x "$INIT_D_SCRIPT"
    echo "--- /etc/init.d/vpnserver 스크립트 생성 완료 ---"
}

# ! 서비스 활성화 및 시작
enable_and_start_service() {
    echo "--- SoftEther VPN Server 서비스 활성화 및 시작 중 ---"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl start "${SERVICE_NAME}"
    systemctl status "${SERVICE_NAME}" --no-pager
    if [ $? -ne 0 ]; then
        echo "경고: SoftEther VPN Server 서비스 시작에 문제가 있을 수 있습니다. status를 확인하세요."
    fi
    echo "--- 서비스 활성화 및 시작 완료 ---"
}

# # UFW (방화벽) 설정
# configure_firewall() {
#     echo "--- UFW (방화벽) 설정 중 ---"
#     ufw enable
#     # SoftEther VPN 서버의 기본 포트
#     ufw allow 443/tcp comment 'SoftEther VPN (HTTPS, SSTP)'
#     ufw allow 992/tcp comment 'SoftEther VPN (Native Client)'
#     ufw allow 5555/tcp comment 'SoftEther VPN (Management)'
#     # L2TP/IPsec 관련 포트
#     ufw allow 500/udp comment 'IPsec ISAKMP'
#     ufw allow 4500/udp comment 'IPsec NAT-T'
#     ufw allow 1701/udp comment 'L2TP'
#     # ICMP (Ping) 허용 - 서버 도달 가능성 테스트용
#     ufw allow proto icmp comment 'Allow ICMP'

#     ufw reload
#     ufw status verbose
#     echo "--- UFW 설정 완료 ---"
# }

# ! 임시 파일 정리
cleanup() {
    echo "--- 임시 파일 정리 중 ---"
    rm -rf "$TEMP_DIR"
    echo "--- 임시 파일 정리 완료 ---"
}

# ! 최종 지침 출력
print_instructions() {
    echo ""
    echo "========================================================================"
    echo "SoftEther VPN Server 설치가 완료되었습니다."
    echo ""
    echo "다음 단계는 VPN 서버를 설정하는 것입니다."
    echo ""
    echo "1. VPN 관리 도구 실행 (터미널에서):"
    echo "   sudo ${INSTALL_DIR}/vpncmd"
    echo "   (VPN Server / VPN Bridge Management Utility -> 1)"
    echo "   (Connect to local host -> Enter)"
    echo "   (Admin Password 변경 프롬프트가 나타나면 새 비밀번호 설정)"
    echo ""
    echo "2. 초기 관리자 비밀번호 설정: ServerPasswordSet"
    echo "   vpncmd에서 처음 연결 시 관리자 비밀번호 설정을 요구합니다."
    echo "   보안을 위해 강력한 비밀번호로 설정해주세요."
    echo "   예: PasswordSet"
    echo ""
    echo "3. 가상 허브 생성 및 세부 설정:"
    echo "   'vpncmd' 내부에서 HubCreate [허브이름] 등으로 허브를 생성하고,"
    echo "   UserCreate, IpTableAdd, DhcpEnable 등 필요한 설정을 진행합니다."
    echo ""
    echo "4. VPN 클라이언트에서 접속 테스트:"
    echo "   Windows, macOS, Linux, 모바일 기기용 SoftEther VPN 클라이언트를 사용하여 접속을 테스트합니다."
    echo ""
    echo "더 자세한 정보는 SoftEther VPN 공식 문서를 참조하세요."
    echo "========================================================================"
}

# ! --- 메인 스크립트 실행 흐름 ---
install_dependencies
create_install_dir
download_and_extract
compile_softether
install_files
create_systemd_service
create_init_d_script
enable_and_start_service
# configure_firewall
cleanup
print_instructions

echo "스크립트 실행 완료!"