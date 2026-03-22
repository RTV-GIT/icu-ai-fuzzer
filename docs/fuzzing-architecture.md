# ICU AI Fuzzer — 현재 퍼징 구조 및 한계 분석

## 1. 전체 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│ Host (WSL2, 2 cores, 1.9GB RAM)                              │
│                                                              │
│  Claude Code (Max Plan)                                      │
│  ├─ ICU 헤더/소스 읽기                                        │
│  ├─ libFuzzer 하네스 C++ 생성                                 │
│  ├─ 크래시 분석 (Triage + Exploitability)                     │
│  └─ 리포트 작성                                               │
│       │                                                      │
│       │ docker exec                                          │
│       ▼                                                      │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Docker Container (icu-ai-fuzzer)                       │  │
│  │ Ubuntu 24.04 + Clang + ASan + pwndbg                   │  │
│  │                                                        │  │
│  │  /opt/icu-install/   ← ICU 76.1 (ASan + fuzzer-no-link)│  │
│  │  /opt/icu-src/       ← ICU 소스코드 전체                 │  │
│  │                                                        │  │
│  │  scripts/                                              │  │
│  │  ├─ compile.sh       clang++ -fsanitize=address,fuzzer │  │
│  │  ├─ fuzz.sh          libFuzzer 실행 + 시드 코퍼스 준비   │  │
│  │  ├─ reproduce.py     크래시 재현 + dedup + GDB 추출     │  │
│  │  └─ gdb_extractor.py GDB 자동화 + ANSI 스트리핑         │  │
│  │                                                        │  │
│  │  workspace/                                            │  │
│  │  ├─ harnesses/       하네스 소스 + 바이너리 (호스트 공유) │  │
│  │  ├─ corpus/          코퍼스 (tmpfs, RAM)                │  │
│  │  ├─ crashes/         크래시 (호스트 영속 저장)            │  │
│  │  └─ reports/         분석 리포트                         │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## 2. 현재 퍼징 타겟

| 하네스 | 타겟 소스 | 대상 코덱 | 전략 |
|--------|-----------|-----------|------|
| `ucnv_2022` | `ucnv2022.cpp` | ISO-2022-JP/JP-2/KR/CN/CN-EXT | 상태 머신 escape sequence 퍼징, 작은 출력 버퍼로 상태 누적 |
| `ucnv_mbcs` | `ucnvmbcs.cpp` | Shift_JIS/EUC-JP/EUC-KR/GB2312/GB18030/Big5 | 가변 길이 멀티바이트 파싱 + convertEx 코덱 간 직접 변환 |
| `ucnv_scsu` | `ucnvscsu.cpp` | SCSU/UTF-7/BOCU-1 | 윈도우/모드 전환 커맨드 바이트 퍼징, 양방향 라운드트립 |

## 3. 현재 성능 측정치

측정 환경: WSL2, 2 cores, 1.9GB RAM, 퍼저 3개 동시 실행

| 지표 | ucnv_2022 | ucnv_mbcs | ucnv_scsu |
|------|-----------|-----------|-----------|
| **exec/s** | ~2,900 | ~1,700 | ~5,200 |
| **cov (edges)** | 800 | 651 | 790 |
| **ft (features)** | 3,873 | 2,968 | 4,102 |
| **corpus 크기** | 561 / 255KB | 390 / 327KB | 702 / 582KB |
| **peak RSS** | 73MB | 66MB | 90MB |
| **크래시** | 0 | 0 | 0 |

## 4. 컴파일 플래그

```bash
clang++ -std=c++17 \
    -fsanitize=address,fuzzer \     # ASan + libFuzzer
    -fno-omit-frame-pointer \       # 정확한 스택 트레이스
    -g -O1 \                        # 디버그 심볼 + 최소 최적화
    -I${ICU_HOME}/include \
    -L${ICU_HOME}/lib \
    -licuuc -licui18n -licudata
```

ICU 자체도 동일한 ASan + `fuzzer-no-link` 플래그로 정적 빌드됨.

## 5. 보안 설정

| 설정 | 값 | 목적 |
|------|-----|------|
| `SYS_PTRACE` | enabled | GDB/pwndbg ptrace 허용 |
| `seccomp` | unconfined | 디버거 시스템콜 제한 해제 |
| `ASAN_OPTIONS` | `abort_on_error=1:symbolize=1:detect_leaks=0` | 크래시 시 즉시 abort + 심볼화, leak 무시 |
| corpus | tmpfs 512MB | SSD 보호 |
| crashes | 호스트 볼륨 | 영속 저장 |

---

## 6. 구조적 한계 분석

### 6.1. 하드웨어 병목 — 2코어 / 1.9GB RAM

**문제**: 퍼저 3개가 2코어를 경쟁. ASan은 메모리를 2~3배 팽창시키므로 1.9GB에서
3개 퍼저(각 ~70-90MB RSS) + ICU 데이터 로딩 + OS 오버헤드 → swap 1.7GB 사용 중.
swap 발생 시 exec/s가 급락한다.

**영향**: exec/s가 1,700~5,200 수준. 전용 퍼징 서버(16코어, 32GB)에서는
코어당 10,000~50,000 exec/s가 일반적. 현재 환경은 약 **10~50배 느림**.

**완화**: 퍼저 동시 실행 수를 2개 이하로 제한하거나, 순차 실행으로 전환.

### 6.2. 커버리지 정체 (Coverage Plateau)

**문제**: `cov` 값이 빠르게 수렴 (ucnv_2022: 800, ucnv_mbcs: 651).
libFuzzer의 mutation만으로는 ISO-2022의 특정 escape sequence 조합이나
MBCS의 valid lead-byte → trail-byte 쌍을 생성하기 어려움.

**영향**: 깊은 코드 경로(다단계 상태 전이, 드문 코덱 분기)에 도달하지 못할 가능성.

**완화 방안**:
- **사전(Dictionary) 추가**: ISO-2022 escape sequence(`\x1b$B`, `\x1b(I` 등),
  MBCS lead byte 범위, SCSU command byte를 `-dict=` 옵션으로 제공
- **Structure-aware harness**: 첫 N바이트를 코덱 선택/모드 플래그로 사용하고
  나머지를 데이터로 분리하는 현재 구조를 더 정교화
- **시드 코퍼스 강화**: ICU 테스트 데이터 외에 실제 인코딩된 텍스트 파일
  (일본어/한국어/중국어 웹페이지)을 시드로 추가

### 6.3. 단일 프로세스 퍼징 (No Parallel Fuzzing)

**문제**: libFuzzer는 기본적으로 단일 프로세스. `-fork=N` 옵션으로 병렬화 가능하지만
현재 2코어 환경에서는 의미 없음.

**영향**: 코퍼스 다양성 확보 속도가 느림. AFL++의 다중 인스턴스 협업
(main + secondary) 대비 탐색 효율 저하.

**완화**: 리소스 확보 시 `-fork=N` 적용, 또는 AFL++ 퍼저를 병행 사용하여
서로 다른 mutation 전략으로 코퍼스를 공유.

### 6.4. 하네스 커버리지 범위의 한계

**문제**: 현재 하네스는 `ucnv_toUnicode()`, `ucnv_fromUnicode()`, `ucnv_convertEx()`
위주. 다음 함수들은 퍼징되지 않고 있음:
- `ucnv_open()` + 비정상 컨버터 이름 (내부 룩업 테이블 경계)
- `ucnv_setSubstString()` (substitution 문자열 처리)
- `ucnv_getUnicodeSet()` (USet 조작)
- Callback 설정 후 에러 경로 (`ucnv_setToUCallBack` → `UCNV_TO_U_CALLBACK_ESCAPE` 등)

**영향**: 변환 로직 외의 보조 함수에서 발생하는 버그를 놓칠 수 있음.

**완화**: 추가 하네스 작성. 특히 callback 변경 + 변환의 조합은 별도 하네스로 분리.

### 6.5. tmpfs에 코퍼스 저장 → 재시작 시 소실

**문제**: 코퍼스가 tmpfs에 있어서 컨테이너 재시작 시 전부 날아감.
수일간 성장한 코퍼스를 잃으면 퍼징을 처음부터 다시 시작해야 함.

**영향**: 장기 퍼징 캠페인에서 치명적. 퍼저 재시작 시 동일 커버리지까지
도달하는 데 시간 낭비.

**완화 방안**:
- 주기적으로 코퍼스를 호스트로 백업하는 cron/스크립트 추가
- 또는 corpus도 호스트 볼륨으로 변경 (SSD 부하 증가 트레이드오프)

### 6.6. 크래시 재현성 문제

**문제**: ASan + libFuzzer 환경에서 발견된 크래시가 non-ASan 빌드에서
재현되지 않을 수 있음. ASan의 메모리 레이아웃이 일반 빌드와 다르기 때문.

**영향**: 실제 익스플로잇 가능성 평가 시 ASan 없는 환경에서도 검증 필요.

**완화**: 크래시 확인 시 ASan 없는 별도 빌드로 재현 테스트 추가.
Dockerfile에 non-ASan ICU 빌드를 병행하는 것을 고려.

### 6.7. ICU 버전 고정

**문제**: `release-76-1`로 고정. 이미 패치된 취약점만 찾게 될 수 있고,
최신 코드의 새 버그를 놓칠 수 있음.

**영향**: 발견한 버그가 이미 알려진 것(known issue)일 가능성.

**완화**: `main` 브랜치 또는 최신 릴리즈로 주기적 업데이트.
발견된 크래시는 CVE DB와 대조하여 신규 여부 확인.

---

## 7. 개선 우선순위 (권장)

| 순위 | 항목 | 난이도 | 효과 |
|------|------|--------|------|
| 1 | 퍼저 딕셔너리 추가 | 낮음 | 커버리지 정체 돌파 |
| 2 | 코퍼스 백업 스크립트 | 낮음 | 장기 퍼징 안정성 |
| 3 | 동시 퍼저 수 조정 (3→2) | 낮음 | exec/s 향상 |
| 4 | 추가 하네스 (callback, open) | 중간 | 공격 표면 확대 |
| 5 | non-ASan 재현 빌드 | 중간 | 익스플로잇 검증 정확도 |
| 6 | 리소스 확보 (클라우드/전용 서버) | 높음 | 전체 성능 10~50배 향상 |
