variable "aws_account_id" {
  description = "배포 대상 AWS 계정 ID. 다른 계정으로의 배포를 방지한다."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS 계정 ID는 숫자 12자리여야 한다."
  }
}

variable "name_prefix" {
  type    = string
  default = "pm"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.name_prefix))
    error_message = "접두사는 영문 소문자로 시작하는 1~16자의 소문자·숫자·하이픈이어야 한다."
  }
}

variable "vpc_cidrs" {
  description = "live, admin, qa의 실제 /22 네트워크. 로컬 tfvars에서 지정한다."
  type = object({
    live  = string
    admin = string
    qa    = string
  })
  validation {
    condition = alltrue([for cidr in values(var.vpc_cidrs) :
      can(cidrnetmask(cidr)) && try(split("/", cidr)[1] == "22" && cidrhost(cidr, 0) == split("/", cidr)[0], false)
    ]) && length(toset(values(var.vpc_cidrs))) == 3
    error_message = "VPC마다 서로 다른 정규화된 IPv4 /22 CIDR을 지정해야 한다."
  }
}

variable "rocky_ami_id" {
  description = "null이면 Rocky 공식 계정의 Rocky 10.2 EC2 Base 20260525.0 x86_64 이미지를 조회한다. 검증 후 동일 공식 이미지의 ID를 고정할 수 있다."
  type        = string
  default     = null
  validation {
    condition     = var.rocky_ami_id == null || can(regex("^ami-[0-9a-f]{8}([0-9a-f]{9})?$", var.rocky_ami_id))
    error_message = "AMI ID 또는 자동 조회용 null을 지정해야 한다."
  }
}

variable "windows_ami_id" {
  description = "Windows Server AMI. null이면 AWS 공식 Windows Server 2022 최신 이미지를 조회한다."
  type        = string
  default     = null
  validation {
    condition     = var.windows_ami_id == null || can(regex("^ami-[0-9a-f]{8}([0-9a-f]{9})?$", var.windows_ami_id))
    error_message = "올바른 Windows AMI ID를 지정해야 한다."
  }
}

variable "key_pair_name" {
  description = "서울 리전에 등록된 기존 EC2 키 페어 이름. 개인키는 Terraform에서 생성하거나 읽지 않는다."
  type        = string
  validation {
    condition     = length(trimspace(var.key_pair_name)) > 0
    error_message = "기존 EC2 키 페어 이름이 필요하다."
  }
}

variable "vpn_ingress_cidrs" {
  description = "VPN TCP 40001 접속을 허용할 외부 IPv4 CIDR."
  type        = set(string)
  validation {
    condition     = length(var.vpn_ingress_cidrs) > 0 && alltrue([for c in var.vpn_ingress_cidrs : can(cidrnetmask(c))])
    error_message = "VPN에 접속할 외부 IPv4 CIDR을 하나 이상 지정해야 한다."
  }
}

variable "vpn_ssh_cidrs" {
  description = "VPN 서버 초기 설정용 SSH 허용 외부 IPv4 CIDR. 기본은 외부 SSH 차단이다."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.vpn_ssh_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "VPN SSH는 제한된 외부 IPv4 CIDR만 허용한다."
  }
}

variable "certificate_arns" {
  description = "live와 qa 내부 ALB에 적용할 기존 서울 리전 ACM 인증서 ARN. 각 도메인을 포함해야 한다."
  type        = object({ live = string, qa = string })
  validation {
    condition = alltrue([for arn in values(var.certificate_arns) :
      can(regex("^arn:aws:acm:ap-northeast-2:[0-9]{12}:certificate/[0-9a-f-]+$", arn))
    ])
    error_message = "서울 리전의 ACM 인증서 ARN을 지정해야 한다."
  }
}

variable "domains" {
  description = "서비스 FQDN. 실제 도메인은 로컬 tfvars에서만 지정한다."
  type = object({
    live_pms   = string
    live_admin = string
    qa_pms     = string
    qa_admin   = string
  })
  validation {
    condition = length(toset(values(var.domains))) == 4 && alltrue([
      for d in values(var.domains) : can(regex("^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}$", d))
    ])
    error_message = "서로 다른 서비스 FQDN 네 개를 지정해야 한다."
  }
}

variable "dns_zone_ids" {
  description = "Terraform에서 레코드를 관리할 기존 Route 53 영역 ID. 미지정 시 DNS 변경 없이 설정값만 출력한다."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.dns_zone_ids) : contains(["live_pms", "live_admin", "qa_pms", "qa_admin"], k)])
    error_message = "DNS 키는 live_pms, live_admin, qa_pms, qa_admin만 가능하다."
  }
}

variable "enable_temporary_nat" {
  description = "각 VPC의 임시 NAT Gateway와 서버 TCP 80/443 인터넷 아웃바운드를 함께 생성한다."
  type        = bool
  default     = true
}

variable "instance_types" {
  description = "Core 요구는 우선 vCPU 기준으로 해석한다. 메모리·부하 확인 후 변경한다."
  type = object({
    live_pms   = optional(string, "c6i.2xlarge")
    live_mysql = optional(string, "c6i.xlarge")
    deployment = optional(string, "t3.small")
    live_vpn   = optional(string, "t3.micro")
    live_admin = optional(string, "t3.small")
    admin_vpn  = optional(string, "t3.micro")
    qa_pms     = optional(string, "t3.small")
    qa_admin   = optional(string, "t3.small")
    qa_vpn     = optional(string, "t3.micro")
  })
  default = {}
}

variable "root_volume_sizes" {
  description = "OS 디스크 용량(GiB). 요청된 데이터 용량과 별개다."
  type = object({
    linux   = optional(number, 30)
    vpn     = optional(number, 20)
    windows = optional(number, 40)
  })
  default = {}
  validation {
    condition     = var.root_volume_sizes.linux >= 30 && var.root_volume_sizes.vpn >= 10 && var.root_volume_sizes.windows >= 40
    error_message = "일반 Linux는 최소 30GiB, VPN은 최소 10GiB, Windows는 최소 40GiB다. 모든 OS 디스크는 선택한 AMI의 최소 용량 이상이어야 한다."
  }
}

variable "live_admin_data_gib" {
  description = "VPC2 NodeJS 서버의 OS 제외 데이터 용량(GiB)."
  type        = number
  default     = 128
  validation {
    condition     = var.live_admin_data_gib >= 0 && floor(var.live_admin_data_gib) == var.live_admin_data_gib
    error_message = "데이터 용량은 0 이상의 정수여야 한다."
  }
}

variable "data_mount_path" {
  description = "Linux 데이터 디스크 공통 마운트 경로. 실제 운영 경로는 로컬 tfvars에 지정한다."
  type        = string
  default     = "/data"
  validation {
    condition     = can(regex("^(/[a-zA-Z0-9_-]+)+$", var.data_mount_path)) && !contains(["etc", "usr", "var", "home", "root", "boot", "dev", "proc", "sys", "run", "tmp"], try(split("/", var.data_mount_path)[1], ""))
    error_message = "시스템 경로가 아닌 절대 디렉터리 경로를 지정해야 한다. 공백·점·셸 특수문자는 허용하지 않는다."
  }
}

variable "health_check_paths" {
  description = "PMS의 HTTP 헬스체크 경로. 실제 애플리케이션 경로에 맞춰 지정한다."
  type = object({
    web   = optional(string, "/")
    admin = optional(string, "/")
  })
  default = {}
  validation {
    condition     = alltrue([for p in values(var.health_check_paths) : startswith(p, "/")])
    error_message = "헬스체크 경로는 /로 시작해야 한다."
  }
}
