
# ! 이 파일은 통합 모니터링 시스템 애플리케이션의 메인 진입점입니다.
# ! Tkinter GUI를 생성하고 실행하는 역할을 합니다.

import tkinter as tk
from gui import MonitoringApp
from logger import get_logger

# @ 이 스크립트가 직접 실행될 때만 아래 코드를 실행합니다.
if __name__ == "__main__":
  log = get_logger()
  log.info("모니터링 프로그램이 시작되었습니다.")

  # @ Tkinter의 메인 윈도우(root)를 생성합니다.
  root = tk.Tk()

  # @ MonitoringApp 클래스의 인스턴스를 생성하여 애플리케이션을 초기화하고 실행합니다.
  app = MonitoringApp(root)

  # @ Tkinter의 이벤트 루프를 시작하여 GUI가 사용자 입력을 기다리게 합니다.
  root.mainloop()
