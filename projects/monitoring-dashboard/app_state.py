# ! 애플리케이션 상태 관리 모듈

import config_manager
from logger import get_logger

log = get_logger()


class AppState:
  """애플리케이션의 공유 상태를 관리하는 클래스"""

  def __init__(self):
    self.config = config_manager.load_config()
    self.monitors = {}           # {service_address: ServiceMonitor}
    self.service_statuses = {}   # {service_address: status_string}
    self.last_check_times = {}   # {service_address: "HH:MM:SS"}
    self.heatmap_cells = {}
    self.heatmap_group_labels = {}
    self.heatmap_scrollable_frame = None
    self.heatmap_window = None

  def clear_all_states(self):
    """모든 모니터링 상태 초기화"""
    for monitor in self.monitors.values():
      monitor.stop()
    self.monitors.clear()
    self.service_statuses.clear()
    self.last_check_times.clear()
    self.heatmap_cells.clear()
    self.heatmap_group_labels.clear()
    self.heatmap_scrollable_frame = None
    self.heatmap_window = None
    log.info("모든 모니터링 상태가 초기화되었습니다.")

  def save_config(self):
    """현재 설정을 파일에 저장"""
    config_manager.save_config(self.config)
