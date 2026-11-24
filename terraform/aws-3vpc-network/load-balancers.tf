resource "aws_lb" "pms" {
  for_each                   = toset(["live", "qa"])
  name                       = "${var.name_prefix}-${each.key}-pms"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.this["${each.key}_lb"].id]
  subnets                    = [for n in [1, 2] : aws_subnet.this["${each.key}-lb-${n}"].id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "pms" {
  for_each    = local.listeners
  name        = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  vpc_id      = aws_vpc.this[each.value.env].id
  target_type = "instance"
  protocol    = "HTTP"
  port        = each.value.target

  health_check {
    enabled  = true
    protocol = "HTTP"
    port     = "traffic-port"
    path     = var.health_check_paths[each.value.service]
    matcher  = "200-399"
  }
}

resource "aws_lb_target_group_attachment" "pms" {
  for_each         = local.listeners
  target_group_arn = aws_lb_target_group.pms[each.key].arn
  target_id        = aws_instance.server[each.value.server].id
  port             = each.value.target
}

resource "aws_lb_listener" "pms" {
  for_each          = local.listeners
  load_balancer_arn = aws_lb.pms[each.value.env].arn
  port              = each.value.listener
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arns[each.value.env]

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pms[each.key].arn
  }
}
