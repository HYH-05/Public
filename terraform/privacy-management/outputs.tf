output "rocky_image" {
  description = "plan에서 조회한 공식 Rocky AMI. 첫 부팅 검증 후 이 ID를 로컬 tfvars에 고정한다."
  value = {
    id               = data.aws_ami.rocky.id
    name             = data.aws_ami.rocky.name
    owner_id         = data.aws_ami.rocky.owner_id
    minimum_root_gib = local.rocky_minimum_root_gib
  }
}

output "vpc_ids" {
  value = { for name, vpc in aws_vpc.this : name => vpc.id }
}

output "server_private_ips" {
  value     = { for name, server in aws_instance.server : name => server.private_ip }
  sensitive = true
}

output "vpn_public_ips" {
  value     = { for name, ip in aws_eip.vpn : name => ip.public_ip }
  sensitive = true
}

output "data_volume_ids" {
  value = { for name, volume in aws_ebs_volume.data : name => volume.id }
}

output "dns_configuration" {
  description = "외부 DNS에서는 PMS CNAME과 운영툴 A 레코드로 등록한다. Private DNS이면 각 VPC와 VPN 클라이언트의 이름 해석도 구성해야 한다."
  value = {
    live_pms   = { name = var.domains.live_pms, type = "CNAME", target = aws_lb.pms["live"].dns_name }
    qa_pms     = { name = var.domains.qa_pms, type = "CNAME", target = aws_lb.pms["qa"].dns_name }
    live_admin = { name = var.domains.live_admin, type = "A", target = aws_instance.server["live_admin"].private_ip }
    qa_admin   = { name = var.domains.qa_admin, type = "A", target = aws_instance.server["qa_admin"].private_ip }
  }
  sensitive = true
}
