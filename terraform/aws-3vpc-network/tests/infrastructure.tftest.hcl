# 포트 기대값은 locals.tf의 예시 포트다. (README '포트 예시 값')
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_ebs_volume" {
    defaults = { id = "vol-00000000000000000" }
  }
  mock_data "aws_ami" {
    defaults = {
      root_device_name = "/dev/sda1"
      block_device_mappings = [{
        device_name  = "/dev/sda1"
        ebs          = { volume_size = "10" }
        no_device    = ""
        virtual_name = ""
      }]
    }
  }
}

variables {
  aws_account_id = "000000000000"
  rocky_ami_id   = "ami-00000000000000000"
  windows_ami_id = "ami-00000000000000001"
  key_pair_name  = "test-key-pair"
  vpc_cidrs = {
    live  = "172.20.0.0/22"
    admin = "172.20.4.0/22"
    qa    = "172.20.8.0/22"
  }
  vpn_ingress_cidrs = ["203.0.113.10/32"]
  vpn_ssh_cidrs     = ["203.0.113.10/32"]
  certificate_arns = {
    live = "arn:aws:acm:ap-northeast-2:000000000000:certificate/00000000-0000-0000-0000-000000000000"
    qa   = "arn:aws:acm:ap-northeast-2:000000000000:certificate/00000000-0000-0000-0000-000000000001"
  }
  domains = {
    live_pms   = "pms.example.com"
    live_admin = "pms-admin.example.com"
    qa_pms     = "qa-pms.example.com"
    qa_admin   = "qa-pms-admin.example.com"
  }
}

run "isolated_infrastructure" {
  command = plan

  assert {
    condition = (
      length(aws_vpc.this) == 3 && length(aws_subnet.this) == 18 &&
      aws_subnet.this["live-public-1"].cidr_block == "172.20.0.0/25" &&
      aws_subnet.this["live-private-2"].cidr_block == "172.20.1.128/25" &&
      aws_subnet.this["live-lb-1"].cidr_block == "172.20.3.128/26" &&
      aws_subnet.this["qa-lb-2"].cidr_block == "172.20.11.192/26"
    )
    error_message = "VPC·서브넷 개수 또는 CIDR 배치가 요구사항과 다르다."
  }

  assert {
    condition = (
      length(aws_instance.server) == 9 && length(aws_eip.vpn) == 3 &&
      alltrue([for name in keys(local.vpns) : one(aws_instance.server[name].root_block_device).volume_size == 20]) &&
      alltrue([for s in aws_instance.server : s.associate_public_ip_address == false]) &&
      alltrue([for lb in aws_lb.pms : lb.internal && lb.load_balancer_type == "application"])
    )
    error_message = "애플리케이션 서버와 ALB는 인터넷에 공개되면 안 된다."
  }

  assert {
    condition = (
      aws_lb_listener.pms["live_web"].port == 40010 &&
      aws_lb_listener.pms["live_admin"].port == 40011 &&
      aws_lb_listener.pms["qa_web"].port == 40010 &&
      aws_lb_listener.pms["qa_admin"].port == 40011 &&
      alltrue([for l in aws_lb_listener.pms : l.protocol == "HTTPS"]) &&
      aws_lb_target_group.pms["live_web"].port == 40020 &&
      aws_lb_target_group.pms["live_admin"].port == 40021 &&
      aws_lb_target_group.pms["qa_web"].port == 40020 &&
      aws_lb_target_group.pms["qa_admin"].port == 40021
    )
    error_message = "라이브·QA의 HTTPS 리스너와 HTTP 대상 포트가 다르다."
  }

  assert {
    condition = (
      length([for c in values(local.connections) : c if c.source == "live_admin" && c.target == "live_lb"]) == 1 &&
      local.connections.admin_to_live.port == 40011 &&
      length(local.peerings) == 2 &&
      !contains(keys(local.peerings), "admin-qa") &&
      alltrue([for c in values(local.connections) : !(startswith(c.source, "qa_") && c.target == "live_mysql")])
    )
    error_message = "운영툴의 라이브 API 포트 또는 QA·라이브 DB 분리가 잘못되었다."
  }

  assert {
    condition = (
      aws_ebs_volume.data["live_pms"].size == 128 &&
      aws_ebs_volume.data["live_mysql"].size == 128 &&
      aws_ebs_volume.data["deployment"].size == 30 &&
      aws_ebs_volume.data["qa_pms"].size == 100 &&
      aws_ebs_volume.data["qa_admin"].size == 64 &&
      aws_ebs_volume.data["live_admin"].size == 128 &&
      length(aws_ebs_volume.data) == 6 &&
      alltrue([for v in aws_ebs_volume.data : v.encrypted])
    )
    error_message = "OS 제외 데이터 용량 또는 디스크 암호화가 다르다."
  }

  assert {
    condition = (
      length(aws_nat_gateway.temporary) == 3 &&
      length(aws_route.private_internet) == 3 &&
      alltrue([for r in aws_vpc_security_group_ingress_rule.vpn_public : contains([22, 40001], r.from_port)]) &&
      alltrue([for r in aws_vpc_security_group_egress_rule.temporary_internet : contains([80, 443], r.from_port)])
    )
    error_message = "임시 인터넷 경로나 공개 포트가 요구사항과 다르다."
  }
}

run "temporary_nat_disabled" {
  command = plan
  variables { enable_temporary_nat = false }
  assert {
    condition = (
      length(aws_nat_gateway.temporary) == 0 && length(aws_eip.nat) == 0 &&
      length(aws_route.private_internet) == 0 &&
      length(aws_vpc_security_group_egress_rule.temporary_internet) == 0 &&
      length(aws_route.public_internet) == 3 && length(aws_eip.vpn) == 3
    )
    error_message = "임시 NAT와 아웃바운드는 함께 제거되고 VPN 진입점은 유지되어야 한다."
  }
}

run "reject_overlapping_networks" {
  command = plan
  variables {
    vpc_cidrs = { live = "172.20.0.0/22", admin = "172.20.0.0/22", qa = "172.20.8.0/22" }
  }
  expect_failures = [var.vpc_cidrs]
}

run "reject_public_ssh" {
  command = plan
  variables { vpn_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.vpn_ssh_cidrs]
}

run "reject_root_smaller_than_image" {
  command = plan
  override_data {
    target = data.aws_ami.rocky
    values = {
      root_device_name = "/dev/sda1"
      block_device_mappings = [{
        device_name  = "/dev/sda1"
        ebs          = { volume_size = "40" }
        no_device    = ""
        virtual_name = ""
      }]
    }
  }
  expect_failures = [aws_instance.server]
}

run "lookup_official_image" {
  command = plan
  variables { rocky_ami_id = null }
  assert {
    condition = (
      toset(data.aws_ami.rocky.owners) == toset(["792107900819"]) &&
      data.aws_ami.rocky.most_recent == false &&
      local.rocky_minimum_root_gib == 10
    )
    error_message = "공식 배포자·고정 빌드·최소 디스크 검증이 유지되어야 한다."
  }
}

run "common_linux_bootstrap" {
  command = plan
  assert {
    condition = (
      aws_instance.server["deployment"].user_data == null &&
      alltrue([for name, cfg in local.servers :
        strcontains(aws_instance.server[name].user_data, "Common Linux bootstrap completed.")
        if !cfg.windows
      ]) &&
      strcontains(aws_instance.server["live_pms"].user_data, "case 'live' in") &&
      strcontains(aws_instance.server["live_admin"].user_data, "case 'live' in") &&
      strcontains(aws_instance.server["qa_pms"].user_data, "case 'qa' in") &&
      strcontains(aws_instance.server["qa_vpn"].user_data, "hostnamectl set-hostname 'pm-qa-vpn'") &&
      strcontains(aws_instance.server["live_mysql"].user_data, "if [[ 'true' == true ]]") &&
      strcontains(aws_instance.server["qa_pms"].user_data, "if [[ 'true' == true ]]") &&
      strcontains(aws_instance.server["live_pms"].user_data, "if [[ 'false' == true ]]") &&
      strcontains(aws_instance.server["live_admin"].user_data, "if [[ 'false' == true ]]") &&
      alltrue([for name, cfg in local.servers :
        length(base64encode(aws_instance.server[name].user_data)) <= 21844
        if !cfg.windows
      ])
    )
    error_message = "Linux 공통 초기 설정·환경 색상·호스트명·user data 용량 또는 Windows 제외가 잘못되었다."
  }
}
