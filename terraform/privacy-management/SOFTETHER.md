# SoftEther 초기 설정

Rocky Linux 10 VPN 서버 3대에 각각 적용한다. 해당 서버의 공인 IP와 초기 SSH 허용 CIDR은 Terraform 로컬 입력·출력에서 확인한다.

## 설치

1. 공식 [Stable 릴리스](https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases)에서 Linux x64 VPN Server의 사용할 버전을 고정한다. 신뢰할 수 있는 경로에서 패키지와 체크섬을 확인하고 서버로 전달한다. 검증하지 않은 다운로드를 `curl | bash`로 실행하지 않는다.
2. 해당 릴리스의 빌드 안내에 따라 Rocky Linux 10에서 필요한 개발 도구를 설치하고 빌드한다. 배포 바이너리와 Rocky Linux 10의 호환성은 실제 서버에서 확인한다.
3. 설치 디렉터리와 설정은 root만 관리하도록 권한을 제한한다. `vpnserver`는 systemd 서비스로 등록한다. `vpn_server.config`, 인증서 개인키, 사용자 내보내기 파일은 Git에 넣지 않는다.
4. 서비스 시작 후 SSH 세션에서 로컬 `vpncmd`로 관리한다. 초기 기본 리스너는 AWS 보안 그룹에서 공개하지 않으므로 외부에서 접근할 수 없다.

## 초기 구성

관리 명령은 `vpncmd`의 대화형 모드에서 실행하고, 비밀번호는 프롬프트에 직접 입력한다. `ServerPasswordSet`으로 서버 관리자 비밀번호를 먼저 지정한다. 실제 사용자 비밀번호를 명령행 인자로 전달하지 않는다.

```text
ServerPasswordSet
ListenerCreate 10443
HubCreate PM
Hub PM
SecureNatEnable
SecureNatHostGet
DhcpGet
```

가상 허브와 개인별 계정을 생성하고 인증서를 포함한 사용할 인증 방식을 적용한다. 허브의 확장 옵션에서 `DisableKernelModeSecureNAT`와 `DisableIpRawModeSecureNAT`를 각각 `1`로 지정하고 사용자 모드를 유지한다. AWS의 ENI·라우팅·보안 그룹이 보는 출발지가 VPN 서버 사설 IP가 되도록 하기 위한 설정이다. [공식 저장소의 설정 설명](https://github.com/SoftEtherVPN/SoftEtherVPN/issues/349)을 참조한다.

SecureNAT 가상 네트워크의 IP·DHCP 범위는 기존 네트워크와 겹치지 않게 변경한다. VPN 클라이언트가 접속할 VPC 대역의 경로를 SecureNAT 가상 게이트웨이로 설정하고, private DNS를 사용하는 경우 해당 VPC의 DNS에 질의할 수 있도록 DHCP DNS와 클라이언트 설정을 맞춘다. 필요한 split route를 DHCP의 classless route 또는 클라이언트의 명시적 경로로 배포한다.

허브 설정 후 서버 관리 모드로 돌아와 사용하지 않는 기본 리스너 `443`, `992`, `5555`를 제거한다. VPN Azure와 동적 DNS는 필요한지 확인하고, 사용하지 않으면 비활성화한다. 관리 접속은 로컬 SSH 세션 또는 SSH 터널을 사용한다. VPN 클라이언트는 TCP 10443에 연결하고 서버 인증서를 검증해야 한다.

## 동작 확인

- VPN 인증 전 내부 PMS·운영툴에 접근할 수 없는지 확인한다.
- 각 VPN에서 해당 VPC의 내부 서비스에 접속한다. live VPN에서는 PMS 두 포트와 배포 서버, admin VPN에서는 운영툴, QA VPN에서는 QA 서비스에 접속한다.
- SecureNAT 접속 시 내부 서버가 보는 source가 VPN 서버의 사설 IP인지 확인하고 사용자 모드 설정과 실제 패킷을 점검한다.
- VPC2 NodeJS에서 live PMS 8444는 연결되고 8443·DB 3306은 차단되는지 확인한다.
- QA에서 live DB 3306 접속이 차단되는지 확인한다.
- DNS 조회·서버 인증서·허브 사용자 권한을 확인한 후 임시 SSH 접근 범위를 재검토한다.

SecureNAT는 VPN 사용자별 원본 IP가 내부 서비스에 전달되지 않는다. 사용자 식별은 VPN 인증·접속 로그로 관리한다. 원본 IP 기반 정책이 필요하면 별도 라우팅형 설계로 변경해야 한다.

공식 설명: [SecureNAT](https://www.softether.org/4-docs/1-manual/3/3.7).
