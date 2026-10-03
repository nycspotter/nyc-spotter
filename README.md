# NYC Spotter Board

A380·747 같은 대형기, 특별 도장기, 군용기가 **EWR, JFK, LGA에 언제 도착하고 언제 출발하는지** 미리 알려주는 자동 알림 + 스케줄 홈페이지입니다.

- **비용 0원, Claude 없이 동작:** GitHub Actions가 약 10분마다 무료 항공기 데이터를 확인하고, GitHub Pages가 홈페이지를 띄웁니다. 컴퓨터를 꺼도 계속 돌아갑니다.
- **기록이 쌓이지 않음:** 데이터는 `data` 브랜치에 매번 덮어써서 저장소 용량이 늘지 않습니다.

## 어떻게 미리 아나요?

| 알림 | 언제 오나 | 예시 |
|---|---|---|
| 도착 예정 | 레어 기체가 출발지에서 **NYC행으로 이륙하면** (장거리는 몇 시간 전) | `[XL] A388 A6-EUV DXB->JFK ETA 08:26` |
| 착륙 + 출발 예상 | 레어 기체가 세 공항에 **내리면**, 평소 출발 시간과 함께 | `JFK 도착 14:20 · 출발 예상: UAE202 22:30` |
| 1시간 전 알림 | 자주 오는 레어편의 **평소 도착·출발 시간 1시간 전** | `약 60분 후 JFK 출발 예상 · UAE202` |
| 아침 요약 | 매일 **오전 7시**(뉴욕), 오늘 예상되는 레어 도착·출발 목록 | `14:20 도착 JFK UAE201 A388 …` |
| 군용기 | NYC 근처 저공에 **나타나는 즉시** (스케줄이 공개되지 않아서 미리는 불가) | `[MIL] C17 RCH415 over NYC` |

- "자주 오는 레어편"은 이 프로그램이 직접 관측한 기록으로 학습합니다. 그래서 **처음 며칠은 목록이 비어 있고**, 같은 편이 2일 이상 관측되면 생깁니다.
- 특별 도장기는 `config.json`에 넣은 등록번호로 찾습니다. 어느 편에 들어갈지는 보통 당일에 정해지기 때문에, **이륙하는 순간** 알리는 것이 가장 빠릅니다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `config.json` | 레어 기준과 알림 설정 ← **주로 여기만 고치면 됩니다** |
| `index.html` | 홈페이지 (오늘의 레어 스케줄) |
| `scripts/spot.ps1` | 데이터 확인, 학습, 알림을 하는 스크립트 |
| `.github/workflows/spot.yml` | 10분마다 스크립트를 실행하는 설정 |

## 설치 (한 번만, 약 15분)

1. **GitHub 계정 만들기:** https://github.com/signup 에서 무료로 가입합니다.
2. **저장소 만들기:** 오른쪽 위 `+` → `New repository`를 누릅니다.
   - 이름: `nyc-spotter`
   - **Public**을 고르세요. 무료 계정은 Public이어야 홈페이지를 쓸 수 있고, Actions도 무제한 무료입니다.
   - `Add a README file`은 체크하지 않습니다.
3. **파일 올리기:** 저장소 화면에서 `uploading an existing file` 링크(또는 `Add file` → `Upload files`)를 누릅니다. `index.html`, `config.json`, `README.md`, `.nojekyll`, `scripts` 폴더를 끌어다 놓고 `Commit changes`를 누릅니다.
4. **자동 실행 파일 만들기:** 점(.)으로 시작하는 폴더는 업로드가 안 될 수 있어서 직접 만듭니다.
   `Add file` → `Create new file`을 누르고, 파일 이름 칸에 `.github/workflows/spot.yml`을 그대로 입력합니다. `spot.yml` 내용을 붙여넣고 `Commit changes`를 누릅니다.
5. **홈페이지 켜기:** `Settings` → 왼쪽 `Pages` → Source를 **`GitHub Actions`** 로 고릅니다.
6. **첫 실행:** 위쪽 `Actions` 탭 → 왼쪽 `spot` → `Run workflow` → 초록 `Run workflow` 버튼을 누릅니다. 1~2분 뒤 초록 체크가 뜨면 성공입니다.
   홈페이지 주소는 `https://<내아이디>.github.io/nyc-spotter/` 입니다. 폰 홈 화면에 추가해 두면 앱처럼 쓸 수 있어요.

## 폰 푸시 알림 켜기

1. 폰에 **ntfy** 앱(무료, iOS/Android)을 설치합니다.
2. 앱에서 `+`를 누르고, 남이 추측하기 어려운 주제 이름을 만들어 구독합니다. 예: `nyc-spot-8k2q-x7`
   (주제 이름을 아는 사람은 누구나 알림을 볼 수 있으니 길고 랜덤하게 정하세요.)
3. GitHub 저장소 `Settings` → `Secrets and variables` → `Actions` → `New repository secret`을 누릅니다.
   Name은 `NTFY_TOPIC`, Secret은 위에서 만든 주제 이름을 넣습니다.

## 기준 바꾸기 (`config.json`)

GitHub에서 `config.json`을 열고 연필 아이콘으로 바로 고칠 수 있습니다.

- `special_liveries`: 특별 도장기 **등록번호** 목록. 항공기 데이터에는 도장 정보가 없어서 직접 넣어야 합니다.
  ```json
  "special_liveries": {
    "N763JB": "JetBlue RetroJet (1960년대 스타일)",
    "N915NN": "American TWA 헤리티지",
    "N12345": "여기에 새 등록번호와 설명"
  }
  ```
- `watch_registrations`: 그 밖에 따라다니고 싶은 특정 기체 (전 세계에서 추적)
- `watch_types`: 그 밖에 보고 싶은 기종. 흔한 기종이 많아서 NYC 근처에서만 확인합니다. 예: `"watch_types": { "B788": "787-8" }`
- `xl_types`: 전 세계에서 추적할 대형기 기종
- `alert_kinds`: 알림 받을 종류. 군용 알림이 귀찮으면 `"military"`를 지우세요.
- `digest_hour`: 아침 요약 시각 (뉴욕 시간, 0~23)
- `remind_before_min`: 몇 분 전에 알릴지

## 알아둘 점

- **시간은 추정치예요.** 도착 예정은 남은 거리와 속도로, "평소 시간"은 지난 기록으로 계산합니다. 지연이나 결항은 반영되지 않아요.
- **10분 간격이라 알림이 몇 분 늦을 수 있어요.** GitHub 예약 실행은 가끔 더 늦어집니다.
- 무료 데이터 서버가 요청을 제한해서, 대형기 기종은 한 번에 4개씩 돌아가며 확인합니다(전체 한 바퀴 약 50분). 장거리 편은 몇 시간 전에 잡히니 괜찮지만, 아주 짧은 비행편은 놓칠 수 있어요.
- 데이터가 40분 넘게 갱신되지 않으면 홈페이지에 경고가 뜹니다. 그럴 땐 `Actions` 탭에서 빨간 X가 있는지 보세요.
- 데이터 출처: [adsb.lol](https://adsb.lol) (ODbL), [adsb.fi](https://adsb.fi), 노선 [adsbdb](https://www.adsbdb.com).
