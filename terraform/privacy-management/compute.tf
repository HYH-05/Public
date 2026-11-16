data "aws_ami" "rocky" {
  most_recent = false
  owners      = ["792107900819"]

  filter {
    name   = "name"
    values = ["Rocky-10-EC2-Base-10.2-20260525.0.x86_64*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  dynamic "filter" {
    for_each = var.rocky_ami_id == null ? [] : [var.rocky_ami_id]
    content {
      name   = "image-id"
      values = [filter.value]
    }
  }
}

locals {
  root_volume_gib = {
    for name, cfg in local.servers : name => (
      cfg.windows ? var.root_volume_sizes.windows : (cfg.public ? var.root_volume_sizes.vpn : var.root_volume_sizes.linux)
    )
  }
  rocky_minimum_root_gib = tonumber(one([
    for mapping in data.aws_ami.rocky.block_device_mappings : mapping.ebs["volume_size"]
    if mapping.device_name == data.aws_ami.rocky.root_device_name
  ]))
}

data "aws_ami" "windows" {
  count       = var.windows_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "server" {
  for_each = local.servers

  ami = each.value.windows ? (
    var.windows_ami_id != null ? var.windows_ami_id : data.aws_ami.windows[0].id
  ) : data.aws_ami.rocky.id
  instance_type               = var.instance_types[each.key]
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.this["${each.value.env}-${each.value.public ? "public" : "private"}-1"].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.this[each.key].id]

  user_data = each.value.windows ? null : templatefile("${path.module}/templates/linux-bootstrap.sh.tftpl", {
    deployment_environment = each.value.env == "qa" ? "qa" : "live"
    server_hostname        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
    data_volume_id         = each.value.data_gib > 0 ? aws_ebs_volume.data[each.key].id : ""
    data_mount_path        = var.data_mount_path
    protect_mysql          = contains(["live_mysql", "qa_pms"], each.key)
    mount_script           = file("${path.module}/scripts/mount-data-disk.sh")
  })
  user_data_replace_on_change = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = local.root_volume_gib[each.key]
    encrypted   = true
    tags        = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-os" }
  }

  tags = {
    Name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
    Environment = each.value.env
    Role        = each.key
  }

  lifecycle {
    precondition {
      condition     = each.value.windows || local.root_volume_gib[each.key] >= local.rocky_minimum_root_gib
      error_message = "${each.key}의 OS 디스크는 선택한 AMI의 최소 root 용량(${local.rocky_minimum_root_gib}GiB) 이상이어야 한다. root_volume_sizes를 조정해야 한다."
    }
  }

  depends_on = [
    aws_route.public_internet,
    aws_route.private_internet,
    aws_vpc_security_group_egress_rule.temporary_internet,
  ]
}

# 데이터 디스크는 인스턴스 교체와 분리해 관리한다.
resource "aws_ebs_volume" "data" {
  for_each          = { for name, cfg in local.servers : name => cfg if cfg.data_gib > 0 }
  availability_zone = local.azs[0]
  size              = each.value.data_gib
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  for_each    = aws_ebs_volume.data
  device_name = "/dev/sdf"
  volume_id   = each.value.id
  instance_id = aws_instance.server[each.key].id
}

resource "aws_eip" "vpn" {
  for_each   = local.vpns
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]
  tags       = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}" }
}

resource "aws_eip_association" "vpn" {
  for_each      = local.vpns
  allocation_id = aws_eip.vpn[each.key].id
  instance_id   = aws_instance.server[each.key].id
}
