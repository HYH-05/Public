resource "aws_security_group" "this" {
  for_each    = local.security_groups
  name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  description = "Explicit traffic rules for ${each.key}"
  vpc_id      = aws_vpc.this[each.value].id
  tags        = { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}" }
}

resource "aws_vpc_security_group_ingress_rule" "internal" {
  for_each                     = local.connections
  security_group_id            = aws_security_group.this[each.value.target].id
  referenced_security_group_id = aws_security_group.this[each.value.source].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key

  # 다른 VPC의 보안 그룹은 피어링 활성화 후에 참조한다.
  depends_on = [aws_vpc_peering_connection.this]
}

resource "aws_vpc_security_group_egress_rule" "internal" {
  for_each                     = local.connections
  security_group_id            = aws_security_group.this[each.value.source].id
  referenced_security_group_id = aws_security_group.this[each.value.target].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key

  depends_on = [aws_vpc_peering_connection.this]
}

resource "aws_vpc_security_group_ingress_rule" "vpn_public" {
  for_each          = local.vpn_public_rules
  security_group_id = aws_security_group.this[each.value.server].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Restricted VPN or bootstrap SSH access"
}

resource "aws_vpc_security_group_egress_rule" "temporary_internet" {
  for_each          = local.internet_egress
  security_group_id = aws_security_group.this[each.value.server].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Temporary package download access"
}
