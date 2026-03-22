# ICU AI Fuzzer — Claude Code Workflow

이 프로젝트는 Claude Code (Max Plan)가 AI 두뇌 역할을 하고,
Docker 컨테이너가 컴파일/퍼징/GDB 실행 엔진 역할을 하는 구조입니다.

## Architecture

```
Claude Code (Host)          Docker Container (icu-ai-fuzzer)
─────────────────          ──────────────────────────────────
1. ICU 헤더 읽기      ───→   /opt/icu-install/include/
2. 하네스 C++ 생성    ───→   workspace/harnesses/<target>.cpp
3. 컴파일 명령        ───→   scripts/compile.sh
4. 퍼징 시작          ───→   scripts/fuzz.sh (runs for days)
   ... 며칠 후 ...
5. 크래시 수집/dedup  ───→   scripts/reproduce.py
6. ASan/GDB 로그 읽기 ←───   workspace/crashes/<target>/results.json
7. RCA 분석 작성      ───→   workspace/reports/<crash>_triage.md
8. 익스플로잇 평가    ───→   workspace/reports/<crash>_exploit.md
```

## Container Name

`icu-ai-fuzzer` — 모든 docker exec 명령에 이 이름 사용.

## Key Paths (Inside Container)

| Path | Purpose |
|------|---------|
| `/opt/icu-install/include/unicode/` | ICU 헤더 파일들 |
| `/opt/icu-src/` | ICU 소스코드 전체 |
| `/app/workspace/harnesses/` | 하네스 .cpp + 컴파일된 바이너리 |
| `/app/workspace/corpus/<target>/` | 퍼저 코퍼스 (tmpfs) |
| `/app/workspace/crashes/<target>/` | 크래시 파일들 (tmpfs) |
| `/app/workspace/reports/` | 분석 리포트 출력 |
| `/app/scripts/` | compile.sh, fuzz.sh, reproduce.py |

## High-Value ICU Targets (V8 Attack Surface)

우선순위 순:
1. `ucnv.h` — Converter (buffer boundary bugs)
2. `uregex.h` — RegExp (V8 Intl 연동, complex state machine)
3. `ucol.h` — Collation (lookup table corruption)
4. `ubrk.h` — BreakIterator (V8 direct calls)
5. `ucal.h` — Calendar
6. `udat.h` — DateFormat
7. `unum.h` — NumberFormat
8. `unorm2.h` — Normalizer2
9. `uset.h` — UnicodeSet
10. `ustring.h` — low-level string ops

## Step-by-Step Commands

### Phase 1: 하네스 생성 & 퍼징 시작

```bash
# 1. 컨테이너 시작
docker compose up -d

# 2. ICU 헤더 읽기 (Claude Code가 직접)
docker exec icu-ai-fuzzer cat /opt/icu-install/include/unicode/ucnv.h

# 3. 하네스 작성 후 컨테이너에 복사 (Claude Code가 workspace/에 write)
#    → workspace/harnesses/ucnv/harness.cpp

# 4. 컴파일
docker exec icu-ai-fuzzer bash /app/scripts/compile.sh \
    /app/workspace/harnesses/ucnv/harness.cpp \
    /app/workspace/harnesses/ucnv/harness_bin

# 5. 퍼징 시작 (백그라운드, 0=무한)
docker exec -d icu-ai-fuzzer bash /app/scripts/fuzz.sh \
    /app/workspace/harnesses/ucnv/harness_bin ucnv 0
```

### Phase 2: 크래시 분석 (며칠 후)

```bash
# 1. 크래시 확인
docker exec icu-ai-fuzzer ls /app/workspace/crashes/ucnv/

# 2. 재현 + 디듑 + GDB 추출
docker exec icu-ai-fuzzer python3 /app/scripts/reproduce.py \
    /app/workspace/harnesses/ucnv/harness_bin ucnv

# 3. 결과 읽기 (Claude Code가 직접 분석)
#    → workspace/crashes/ucnv/results.json
#    → workspace/crashes/ucnv/summary.txt
```

## Harness Generation Guidelines

하네스 생성 시 반드시 지켜야 할 규칙:
- `extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)` 시그니처
- `<stdint.h>`, `<stddef.h>`, 타겟 헤더 include
- 퍼저 입력(raw bytes)을 ICU 타입으로 의미 있게 변환 (UChar*, locale, etc.)
- 에러/엣지케이스 경로 최대한 탐색 (UAF, OOB, integer overflow 트리거 가능성)
- 하네스 자체에서 UB(undefined behaviour) 발생하지 않을 것
- return 0으로 종료
