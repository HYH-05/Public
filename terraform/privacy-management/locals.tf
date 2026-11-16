locals {
  azs = ["ap-northeast-2a", "ap-northeast-2c"]

  subnet_layout = {
    public-1  = { tier = "public", az = 0, bits = 3, number = 0 }
    public-2  = { tier = "public", az = 1, bits = 3, number = 1 }
    private-1 = { tier = "private", az = 0, bits = 3, number = 2 }
    private-2 = { tier = "private", az = 1, bits = 3, number = 3 }
    lb-1      = { tier = "lb", az = 0, bits = 4, number = 14 }
    lb-2      = { tier = "lb", az = 1, bits = 4, number = 15 }
  }
  subnets = merge([for env, cidr in var.vpc_cidrs : {
    for name, cfg in local.subnet_layout : "${env}-${name}" => merge(cfg, {
      env = env, name = name, cidr = cidrsubnet(cidr, cfg.bits, cfg.number)
    })
  }]...)
  route_tables = merge([for env in keys(var.vpc_cidrs) : {
    for tier in ["public", "private", "lb"] : "${env}-${tier}" => { env = env, tier = tier }
  }]...)

  servers = {
    live_pms   = { env = "live", public = false, windows = false, data_gib = 128 }
    live_mysql = { env = "live", public = false, windows = false, data_gib = 128 }
    deployment = { env = "live", public = false, windows = true, data_gib = 30 }
    live_vpn   = { env = "live", public = true, windows = false, data_gib = 0 }
    live_admin = { env = "admin", public = false, windows = false, data_gib = var.live_admin_data_gib }
    admin_vpn  = { env = "admin", public = true, windows = false, data_gib = 0 }
    qa_pms     = { env = "qa", public = false, windows = false, data_gib = 100 }
    qa_admin   = { env = "qa", public = false, windows = false, data_gib = 64 }
    qa_vpn     = { env = "qa", public = true, windows = false, data_gib = 0 }
  }
  vpns = { for name, cfg in local.servers : name => cfg if cfg.public }
  security_groups = merge(
    { for name, cfg in local.servers : name => cfg.env },
    { live_lb = "live", qa_lb = "qa" }
  )

  peerings = {
    live-admin = { from = "live", to = "admin" }
    live-qa    = { from = "live", to = "qa" }
  }
  peering_routes = merge([for name, peer in local.peerings : merge(
    { for tier in ["public", "private", "lb"] : "${name}-from-${tier}" => {
      table = "${peer.from}-${tier}", destination = peer.to, peering = name
    } },
    { for tier in ["public", "private", "lb"] : "${name}-to-${tier}" => {
      table = "${peer.to}-${tier}", destination = peer.from, peering = name
    } }
  )]...)

  listeners = {
    live_web   = { env = "live", service = "web", listener = 8443, target = 8080, server = "live_pms" }
    live_admin = { env = "live", service = "admin", listener = 8444, target = 8090, server = "live_pms" }
    qa_web     = { env = "qa", service = "web", listener = 8443, target = 8080, server = "qa_pms" }
    qa_admin   = { env = "qa", service = "admin", listener = 8444, target = 8090, server = "qa_pms" }
  }

  # 허용된 통신마다 수신·송신 규칙을 한 쌍으로 생성한다.
  connections = {
    live_web_target   = { source = "live_lb", target = "live_pms", port = 8080 }
    live_admin_target = { source = "live_lb", target = "live_pms", port = 8090 }
    qa_web_target     = { source = "qa_lb", target = "qa_pms", port = 8080 }
    qa_admin_target   = { source = "qa_lb", target = "qa_pms", port = 8090 }
    live_database     = { source = "live_pms", target = "live_mysql", port = 3306 }
    admin_to_live     = { source = "live_admin", target = "live_lb", port = 8444 }
    qa_admin_to_pms   = { source = "qa_admin", target = "qa_lb", port = 8444 }
    live_vpn_web      = { source = "live_vpn", target = "live_lb", port = 8443 }
    live_vpn_admin    = { source = "live_vpn", target = "live_lb", port = 8444 }
    live_vpn_pms_ssh  = { source = "live_vpn", target = "live_pms", port = 22 }
    live_vpn_db_ssh   = { source = "live_vpn", target = "live_mysql", port = 22 }
    live_vpn_rdp      = { source = "live_vpn", target = "deployment", port = 3389 }
    live_vpn_svn      = { source = "live_vpn", target = "deployment", port = 3690 }
    admin_vpn_ssh     = { source = "admin_vpn", target = "live_admin", port = 22 }
    admin_vpn_https   = { source = "admin_vpn", target = "live_admin", port = 443 }
    qa_vpn_web        = { source = "qa_vpn", target = "qa_lb", port = 8443 }
    qa_vpn_pms_admin  = { source = "qa_vpn", target = "qa_lb", port = 8444 }
    qa_vpn_pms_ssh    = { source = "qa_vpn", target = "qa_pms", port = 22 }
    qa_vpn_admin_ssh  = { source = "qa_vpn", target = "qa_admin", port = 22 }
    qa_vpn_https      = { source = "qa_vpn", target = "qa_admin", port = 443 }
    deploy_live_pms   = { source = "deployment", target = "live_pms", port = 22 }
    deploy_live_admin = { source = "deployment", target = "live_admin", port = 22 }
    deploy_qa_pms     = { source = "deployment", target = "qa_pms", port = 22 }
    deploy_qa_admin   = { source = "deployment", target = "qa_admin", port = 22 }
    svn_live_pms      = { source = "live_pms", target = "deployment", port = 3690 }
    svn_live_admin    = { source = "live_admin", target = "deployment", port = 3690 }
    svn_qa_pms        = { source = "qa_pms", target = "deployment", port = 3690 }
    svn_qa_admin      = { source = "qa_admin", target = "deployment", port = 3690 }
  }

  vpn_public_rules = merge([for name in keys(local.vpns) : merge(
    { for cidr in var.vpn_ingress_cidrs : "${name}-vpn-${cidr}" => { server = name, cidr = cidr, port = 10443 } },
    { for cidr in var.vpn_ssh_cidrs : "${name}-ssh-${cidr}" => { server = name, cidr = cidr, port = 22 } }
  )]...)
  internet_egress = var.enable_temporary_nat ? merge([for name in keys(local.servers) : {
    for port in [80, 443] : "${name}-${port}" => { server = name, port = port }
  }]...) : {}
}
