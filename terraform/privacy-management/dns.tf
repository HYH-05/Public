locals {
  pms_dns = {
    live_pms = "live"
    qa_pms   = "qa"
  }
  admin_dns = {
    live_admin = "live_admin"
    qa_admin   = "qa_admin"
  }
}

resource "aws_route53_record" "pms" {
  for_each = { for name, env in local.pms_dns : name => env if contains(keys(var.dns_zone_ids), name) }
  zone_id  = var.dns_zone_ids[each.key]
  name     = var.domains[each.key]
  type     = "A"
  alias {
    name                   = aws_lb.pms[each.value].dns_name
    zone_id                = aws_lb.pms[each.value].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "admin" {
  for_each = { for name, server in local.admin_dns : name => server if contains(keys(var.dns_zone_ids), name) }
  zone_id  = var.dns_zone_ids[each.key]
  name     = var.domains[each.key]
  type     = "A"
  ttl      = 60
  records  = [aws_instance.server[each.value].private_ip]
}
