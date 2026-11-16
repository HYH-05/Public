resource "aws_vpc" "this" {
  for_each             = var.vpc_cidrs
  cidr_block           = each.value
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_internet_gateway" "this" {
  for_each = var.vpc_cidrs
  vpc_id   = aws_vpc.this[each.key].id
  tags     = { Name = "${var.name_prefix}-${each.key}-igw" }
}

resource "aws_subnet" "this" {
  for_each                = local.subnets
  vpc_id                  = aws_vpc.this[each.value.env].id
  cidr_block              = each.value.cidr
  availability_zone       = local.azs[each.value.az]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_route_table" "this" {
  for_each = local.route_tables
  vpc_id   = aws_vpc.this[each.value.env].id
  tags     = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_route_table_association" "this" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this["${each.value.env}-${each.value.tier}"].id
}

resource "aws_route" "public_internet" {
  for_each               = var.vpc_cidrs
  route_table_id         = aws_route_table.this["${each.key}-public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[each.key].id
}

resource "aws_eip" "nat" {
  for_each = var.enable_temporary_nat ? var.vpc_cidrs : {}
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-${each.key}-temporary-nat" }
}

resource "aws_nat_gateway" "temporary" {
  for_each      = var.enable_temporary_nat ? var.vpc_cidrs : {}
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this["${each.key}-public-1"].id
  tags          = { Name = "${var.name_prefix}-${each.key}-temporary-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route" "private_internet" {
  for_each               = var.enable_temporary_nat ? var.vpc_cidrs : {}
  route_table_id         = aws_route_table.this["${each.key}-private"].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.temporary[each.key].id
}

resource "aws_vpc_peering_connection" "this" {
  for_each    = local.peerings
  vpc_id      = aws_vpc.this[each.value.from].id
  peer_vpc_id = aws_vpc.this[each.value.to].id
  auto_accept = true
  tags        = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_vpc_peering_connection_options" "this" {
  for_each                  = local.peerings
  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.key].id
  requester { allow_remote_vpc_dns_resolution = true }
  accepter { allow_remote_vpc_dns_resolution = true }
}

resource "aws_route" "peering" {
  for_each                  = local.peering_routes
  route_table_id            = aws_route_table.this[each.value.table].id
  destination_cidr_block    = var.vpc_cidrs[each.value.destination]
  vpc_peering_connection_id = aws_vpc_peering_connection.this[each.value.peering].id
}
