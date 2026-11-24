# Rocky AMI 선정

선정 대상은 **Rocky Linux 10.2, EC2 Base, 20260525.0, x86_64, 비-LVM, 공식 Community AMI**다. 자동으로 최신 빌드로 변경하지 않고 버전·빌드를 고정한다.

| 항목 | 설정 |
|---|---|
| 리전 | ap-northeast-2 |
| 공식 배포자 AWS 계정 | 792107900819 |
| 이미지 이름 필터 | Rocky-10-EC2-Base-10.2-20260525.0.x86_64* |
| 아키텍처 | x86_64 |
| 부팅 볼륨 | EBS |
| 기본 SSH 계정 | rocky, sudo 사용 |
| 조회 실패·중복 시 | plan 실패, 다른 이미지로 대체하지 않음 |

Rocky 공식 다운로드 페이지에는 서울 리전 10.2 x86_64 이미지가 제공된다. 공식 배포 계정과 Base 이름 조건을 함께 조회해 LVM이나 다른 판매자 이미지를 선택하지 않는다. 공식 Marketplace 일반 이미지도 검토했으나, 공개 지원 목록에 t3.micro가 없어 VPN 사양을 유지할 수 있는 공식 Community 배포 경로를 선택했다. 실제 t3.micro 부팅·메모리 여유는 배포 후 검증해야 한다.

공식 cloud 이미지 빌드 정의의 EC2 Base 프로파일은 데스크톱이 없는 core 패키지에 cloud-init·chrony·AWS 도구 등을 추가하고 디스크를 10G로 정의한다. ISO의 Minimal Install과 완전히 같은 패키지 목록은 아니며, 클라우드 구동용 최소 베이스로 사용한다. 현재 빌드 정의에는 Cockpit 구성요소도 포함되어 있으므로, 엄격한 패키지 최소화가 필요하면 실제 이미지의 설치 목록을 점검해 불필요한 항목을 제거해야 한다. 호스트에서 9090 등 추가 포트를 열지 않는다.

빌드 정의는 현재 소스의 근거이며 특정 AMI 스냅샷을 직접 검사한 결과는 아니다. 실제 root 최소 용량은 Terraform이 DescribeImages로 조회하고, 지정한 OS 디스크가 작으면 인스턴스 생성을 차단한다. VPN의 OS 디스크는 20GiB를 유지한다.

`rocky_ami_id = null`로 두면 인증된 Terraform plan에서 위 조건으로 AMI ID를 조회한다. 실제 사용한 ID는 `rocky_image` 출력으로 확인하고, 첫 부팅 검증 후 로컬 terraform.tfvars에 고정할 수 있다. 고정한 ID도 같은 공식 배포자·버전·빌드 조건으로 검증한다. 인증 없이 추측한 AMI ID는 입력하지 않는다.

아직 실제 AWS 조회·인스턴스 생성·패키지 목록 점검은 수행하지 않았다. AWS 계정 ID·인증·인증서 등 나머지 로컬 입력이 준비되어야 실제 plan이 가능하다.

근거:

- [Rocky 공식 다운로드](https://rockylinux.org/download): 서울 리전 배포 목록.
- [공식 배포 계정 확인](https://forums.rockylinux.org/t/rocky-linux-official-aws-ami/3049/25).
- [Rocky 공식 EC2 Base 빌드 정의](https://git.resf.org/sig_core/rocky-kiwi-descriptions/src/branch/r10/cloud/cloud.xml).
- [공식 Marketplace 일반 이미지](https://aws.amazon.com/marketplace/pp/prodview-z7hzo3jvdgrmi): 무료 소프트웨어, cloud-init, SSH 계정 및 지원 인스턴스 목록.
