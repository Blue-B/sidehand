[English](benchmark.md) | **한국어**

# Sidehand 측정 방법

모든 숫자는 Windows 11 PC 한 대(2560x1440, 배율 100%)에서 쟀습니다. 토큰은 `o200k_base` 기준입니다.

## 모든 도구로 같은 작업

메모 창이 키보드를 가진 채로 계속 입력을 받고, 그 뒤에 주문서(WinForms)가 있습니다. 각 도구가 자기 안내서대로 주문서를 채웁니다: 창 읽기, 고객과 수량 입력, 드롭다운에서 지역 선택, 체크, 제출, 결과 확인. 맨 앞 창과 실제 커서는 따로 기록했습니다. 실제 화면에서 도구마다 한 번씩 쟀습니다.

| 도구 | 완료 | 메모가 키보드를 잃은 시간 | 앞으로 온 창 | 커서 움직임 | 시간 | 토큰 |
|---|:-:|--:|--:|--:|--:|--:|
| Sidehand | ✅ | 0초 | 0 | 0 | 2.0초 | 277 |
| agent-desktop 1.0.2 | ❌ 지역 선택 실패 | 2.3초 | 4 | 0 | 2.7초 | 3,411 |
| Windows-MCP 0.8.8 | ✅ | 49.7초 | 1 | 6 | 65.5초 | 13,425 |
| Terminator 0.24.28 | ✅ | 67.9초 | 8 | 2 | 68.0초 | 2,488 |

- agent-desktop: 드롭다운에 `select`와 `expand`를 하면 `ACTION_NOT_SUPPORTED`를 돌려줬습니다.
- Terminator: `select_option`이 드롭다운을 찾지 못해 클릭으로 열었습니다. `click_element`는 실제 커서를 옮겼다가 되돌려 놓습니다.
- Windows-MCP: 앱을 앞으로 가져온 뒤(`App` switch) 실제 마우스로 클릭합니다. 화면을 읽을 때 데스크톱의 모든 창을 함께 읽어서, 열린 창이 많을수록 토큰이 늘어납니다.
- Cua Driver 0.28.2는 이 작업에서 뺐습니다. 호출할 때마다 사용 통계용 콘솔 창이 떠서 맨 앞 창을 가져갑니다.

스크립트: [demo/compare.ps1](../demo/compare.ps1)이 실행하고, [demo/compare-task.mjs](../demo/compare-task.mjs)에 도구별 호출이 있고, [demo/compare_score.py](../demo/compare_score.py)가 [demo/compare-results.json](../demo/compare-results.json)을 만듭니다.

## 앱 7개 읽기

보이지 않는 테스트 데스크톱에서 같은 창을 세 번씩 읽고 중앙값을 썼습니다. Terminator와 Windows-MCP는 이 데스크톱에서 읽지 못했습니다. Windows-MCP는 조작 표시를 띄우려면 실제 커서가 필요해서, 커서가 없으면 모든 호출을 거부합니다.

| 앱 | 토큰 (Sidehand / agent-desktop) | 찾은 요소 | 읽기 시간 |
|---|--:|--:|--:|
| WinForms 테스트 앱 | 250 / 1,289 | 27 / 21 | 559 / 726 ms |
| WPF 테스트 앱 | 221 / 968 | 26 / 17 | 544 / 867 ms |
| 주문서 (데모) | 161 / 740 | 18 / 11 | 539 / 739 ms |
| 문자표 | 268 / 1,069 | 24 / 17 | 505 / 814 ms |
| 시스템 정보 | 1,215 / 4,632 | 105 / 70 | 618 / 1849 ms |
| Edge 웹 페이지 | 436 / 8,662 | 37 / 117 | 626 / 1114 ms |
| VS Code | 1,925 / 7,538 | 169 / 107 | 844 / 1519 ms |

찾은 요소는 각 도구가 ref를 붙여 보여 준 개수입니다. Edge 웹 페이지에서는 agent-desktop이 브라우저 자체 버튼까지 포함해 더 많이 찾았고, 나머지 앱에서는 모두 Sidehand가 더 많이 찾았습니다.

## 재현

```bash
npm test                           # 보이지 않는 데스크톱, 화면에 아무것도 뜨지 않음, 몇 분
npm test -- -Bench                 # 앱 7개 읽기, test/isolated/bench_score.py로 채점
powershell -File demo/compare.ps1  # 실제 화면: 모든 도구로 같은 작업, 약 4분 동안 PC 비우기
powershell -File demo/measure.ps1  # 실제 화면: WinForms, Edge, VS Code에서 포커스와 커서, 약 3분
powershell -File demo/record.ps1 -Recordly [-Lang ko]   # 데모 영상, 약 3분
python3 demo/benchmark_chart.py    # assets/benchmark.svg 다시 그리기
```

실제 화면 스크립트는 누가 PC를 쓰면 스스로 멈추고, 띄운 프로세스는 모두 함께 닫힙니다.
