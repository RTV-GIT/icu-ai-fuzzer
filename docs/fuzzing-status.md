# ICU AI Fuzzer — 현재 퍼징 상태 및 고도화 방안

**작성일**: 2026-03-22
**ICU 버전**: 78.3 (release-78.3)
**환경**: WSL2, 8 cores, 8GB RAM, Docker

---

## 1. 현재 퍼저 구조

### 아키텍처
```
Claude Code (Host, Max Plan)
  │
  │  docker exec
  ▼
Docker Container (icu-ai-fuzzer)
  │
  ├─ ICU 78.3 (ASan + fuzzer-no-link 정적 빌드)
  │
  ├─ 하네스 (clang++ -fsanitize=address,fuzzer)
  │   ├─ uregex/harness_bin     RegexMatcher
  │   ├─ mf2/harness_bin        MessageFormat 2.0
  │   ├─ utfiter/harness_bin    UTF Iterator (safe only)
  │   ├─ ucnv_2022/harness_bin  ISO-2022 (ICU 76 빌드, 현재 미가동)
  │   ├─ ucnv_mbcs/harness_bin  MBCS (ICU 76 빌드, 현재 미가동)
  │   └─ ucnv_scsu/harness_bin  SCSU/UTF-7 (ICU 76 빌드, 현재 미가동)
  │
  ├─ scripts/
  │   ├─ compile.sh             ASan+libFuzzer 컴파일
  │   ├─ fuzz.sh                퍼징 실행 + 시드 코퍼스 + 10분 백업
  │   ├─ round_robin.sh         시간 분할 순차 실행
  │   ├─ reproduce.py           크래시 재현 + dedup + GDB 추출
  │   └─ gdb_extractor.py       GDB 자동화 + ANSI 스트리핑
  │
  └─ workspace/
      ├─ corpus/       (tmpfs, 10분마다 corpus_backup/으로 동기화)
      ├─ corpus_backup/ (호스트 영속)
      ├─ crashes/       (호스트 영속)
      └─ reports/       (호스트 영속)
```

### 현재 가동 현황

| 퍼저 | ICU 버전 | 상태 | 코퍼스 | 딕셔너리 | FDP |
|------|----------|------|--------|----------|-----|
| **mf2** | 78.3 | 가동 중 | 2,154 | 없음 | O |
| **utfiter** | 78.3 | 가동 중 | 1,907 | 없음 | O |
| **uregex** | 78.3 | 크래시 후 중단 | 2,443 | 없음 | O |
| ucnv_2022 | 76→78 미재빌드 | 미가동 | 8,134 | O | O |
| ucnv_mbcs | 76→78 미재빌드 | 미가동 | 983 | O | O |
| ucnv_scsu | 76→78 미재빌드 | 미가동 | 1,440 | O | O |

### 리소스 사용량
- CPU: 8코어 중 2코어 사용 (퍼저 2개), 6코어 유휴
- RAM: 3.4GB / 7.8GB 사용, swap 없음
- 코퍼스: tmpfs 512MB + 호스트 백업

---

## 2. 하네스별 퍼징 전략

### uregex (RegexMatcher)
- **타겟**: `uregex_open` → `uregex_findNext` → `uregex_group` / `uregex_replaceAll` / `uregex_split`
- **FDP 구조**: flags(uint32) + doFind/doReplace/doSplit/setRegion(bool) + pattern(UChar[]) + text(UChar[])
- **핵심 전략**: `setRegion()`으로 매칭 범위 제한 → `MatchChunkAt` 경계 처리 스트레스
- **약점**: 딕셔너리 없음. 정규식 메타문자(`.*`, `[`, `(`, `|` 등)를 퍼저가 우연히 생성해야 함

### mf2 (MessageFormat 2.0)
- **타겟**: `MessageFormatter::Builder::setPattern` → `build` → `formatToString`
- **FDP 구조**: locale(선택) + doGetPattern/doGetModel(bool) + pattern(UTF-8 string) + argValue(UTF-8 string)
- **핵심 전략**: MF2 파서에 임의의 포맷 문자열 투입. "기술 미리보기" 상태의 불안정 코드
- **약점**: 딕셔너리 없음. MF2 문법 토큰(`{`, `}`, `.match`, `.input` 등)이 없으면 파서 초입에서 reject

### utfiter (UTF Iterator, safe only)
- **타겟**: `utfStringCodePoints<UChar32, NEGATIVE/FFFD>` — forward/backward 반복
- **FDP 구조**: mode(uint8) + rawBytes → UTF-8(string_view) + UTF-16(u16string_view) 동시 퍼징
- **핵심 전략**: ill-formed UTF-8/16 시퀀스를 safe API에 투입. 경계 처리 검증
- **약점**: header-only 코드라 코드 경로가 비교적 단순. 빠르게 커버리지 포화될 가능성

### ucnv (Converter, 현재 미가동)
- **타겟**: `ucnv_toUnicode` / `ucnv_fromUnicode` / `ucnv_convertEx`
- **FDP 구조**: codec 선택 + callback 선택 + bufSize(가변) + doRoundTrip/doFlush + raw data
- **핵심 전략**: 작은 출력 버퍼로 상태 누적, 코덱 간 직접 변환(convertEx)
- **딕셔너리**: 3개 (ISO-2022 escape sequences, MBCS lead bytes, SCSU command bytes)

---

## 3. 발견된 크래시 요약

| # | 타겟 | 타입 | 함수 | 심각도 | 신규 여부 |
|---|------|------|------|--------|-----------|
| 1 | uregex | Heap OOB READ 2 (underflow) | `MatchChunkAt:5676` | High | 기존 (OSV-2025-251) |
| 2 | utfiter | Heap OOB READ 1 | `UnsafeUTFImpl::readAndInc:939` | Medium | Unsafe API, by-design |

**신규 0-day: 0건**

---

## 4. 구조적 한계

### 4.1. 유휴 자원 — 8코어 중 2코어만 사용
현재 퍼저 2개만 가동 중이라 6코어가 놀고 있다. uregex를 재시작하고 ucnv 3개를
78.3으로 재빌드하면 총 6개 퍼저를 동시 실행 가능.

### 4.2. 딕셔너리 부재 — uregex, mf2, utfiter
ucnv에는 딕셔너리를 적용했으나 신규 타겟 3개에는 없다.
특히 uregex와 mf2는 구조화된 입력(정규식 문법, MF2 포맷 문법)을 기대하므로
랜덤 바이트만으로는 파서 깊숙한 경로에 도달하기 어렵다.

### 4.3. 코퍼스 품질
- uregex: 2,443개이나 실제 유효한 정규식 비율은 낮을 것
- mf2: 2,154개이나 MF2 파서를 통과하는 패턴 비율 미확인
- ucnv: ICU testdata 시드가 있어 초기 코퍼스 품질이 상대적으로 양호

### 4.4. OSS-Fuzz와의 중복
ICU는 Google OSS-Fuzz 타겟이므로, 단순 libFuzzer 퍼징은 OSS-Fuzz와 동일한 접근.
동일한 전략으로는 OSS-Fuzz가 이미 찾은 것만 재발견할 확률이 높다.

---

## 5. 고도화 방안

### Phase 1: 즉시 적용 가능 (노력: 낮음)

#### 5.1. 유휴 코어 활용 — 퍼저 전체 가동
```
현재: mf2 + utfiter (2개)
목표: uregex + mf2 + utfiter + ucnv_2022 + ucnv_mbcs + ucnv_scsu (6개)
```
ucnv 3개를 ICU 78.3으로 재컴파일하고, uregex를 재시작. 8코어 중 6코어 활용.

#### 5.2. 딕셔너리 추가 — uregex, mf2

**uregex.dict** (정규식 메타문자):
```
# 핵심 메타문자
".*"  "\\d+"  "\\w+"  "\\s"  "[^]"  "()"  "(?:)"
"(?=)"  "(?!)"  "(?<=)"  "(?<!)"  "{1,3}"  "\\b"
"|"  "^"  "$"  "\\p{L}"  "\\P{Lu}"
```

**mf2.dict** (MessageFormat 2.0 문법 토큰):
```
".match"  ".input"  ".local"  "{$arg}"  "{#tag}"
"{|literal|}"  ":number"  ":string"  ":datetime"
"*"  "when"
```

딕셔너리 추가만으로 파서 깊은 경로 도달률이 크게 올라간다.

#### 5.3. 시드 코퍼스 강화

- uregex: ICU 테스트 코드에서 정규식 패턴 추출 (`regextst.cpp`)
- mf2: MF2 spec의 예제 패턴 수집 (ABNF grammar 기반)
- utfiter: 다양한 언어의 실제 텍스트 (한/중/일/아랍어 + 이모지 + 특수 유니코드)

### Phase 2: 전략 차별화 (노력: 중간)

#### 5.4. Structure-aware 퍼징 (Custom Mutator)

OSS-Fuzz와 차별화되는 핵심 전략. libFuzzer의 `LLVMFuzzerCustomMutator`를 구현하여
**문법적으로 유효한 입력을 더 높은 확률로 생성**.

**uregex 예시**:
```cpp
// 정규식 AST를 생성하고 직렬화하는 custom mutator
// → 파서를 통과해서 RegexMatcher 깊은 경로까지 도달
extern "C" size_t LLVMFuzzerCustomMutator(
    uint8_t *data, size_t size, size_t maxSize, unsigned int seed) {
    // 기존 입력을 정규식 AST로 파싱 시도
    // → AST 노드를 랜덤 변이 (그룹 추가, 반복자 변경, 문자 클래스 확장)
    // → 다시 직렬화하여 반환
}
```

**mf2 예시**:
```cpp
// MF2 ABNF 문법에 기반한 생성형 퍼저
// {.match {$var :number} when 1 {{one}} when * {{other}}}
// → 변수명, 함수명, 리터럴 값을 랜덤 변이
```

이 방식은 OSS-Fuzz의 단순 byte-level mutation과 완전히 다른 탐색 공간을 만들어
OSS-Fuzz가 못 찾는 깊은 상태 조합의 버그를 찾을 수 있다.

#### 5.5. 크로스 API 퍼징

현재는 각 API를 독립적으로 퍼징하지만, 실제 취약점은 **API 조합**에서 발생하는 경우가 많다:

- `ucnv_toUnicode()` 결과를 `uregex`에 직접 투입
- `mf2::formatToString()` 결과를 `ucnv_fromUnicode()`로 변환
- `utfStringCodePoints()`로 반복하면서 `ubidi_setPara()`에 전달

이런 조합 하네스는 단일 API 퍼징에서 못 찾는 상태 불일치 버그를 트리거할 수 있다.

#### 5.6. Differential 퍼징

같은 입력을 ICU의 서로 다른 경로로 처리하고 결과를 비교:

- `ucnv_toUnicode(Shift_JIS)` vs `ucnv_toUnicode(windows-932)` → 같은 결과여야 함
- safe UTF iterator vs unsafe UTF iterator → well-formed 입력에서 같은 결과여야 함
- `uregex_find()` (chunk mode) vs (stream mode) → 같은 매치 결과여야 함

결과가 다르면 최소한 한쪽에 버그가 있다는 의미.

### Phase 3: 인프라 확장 (노력: 높음)

#### 5.7. AFL++ 병행

libFuzzer와 다른 mutation 전략 (havoc, splice, MOpt)을 제공.
같은 코퍼스를 공유하면서 서로 다른 탐색 경로를 커버.

```
libFuzzer (기존) ←── 코퍼스 공유 ──→ AFL++ (추가)
     │                                    │
     └─── 각자 다른 mutation 전략 ─────────┘
```

#### 5.8. 클라우드 스케일링

현재 WSL2 8코어는 연구용으로 적합하지만, 본격적인 0-day 헌팅에는 부족.
GCP/AWS spot instance로 64코어+ 환경을 띄우면 exec/s가 10배 이상 증가.

#### 5.9. 버전 비교 퍼징 (Regression Hunting)

ICU 77 → 78 사이에 변경된 코드만 추출하여 집중 퍼징.
`git diff release-77-1..release-78.3 -- icu4c/source/` 기반으로
변경된 함수만 타겟하는 하네스를 자동 생성.

---

## 6. 고도화 우선순위

| 순위 | 항목 | 효과 | 노력 | OSS-Fuzz 대비 차별화 |
|------|------|------|------|---------------------|
| **1** | 유휴 코어 활용 (6개 퍼저) | 탐색 속도 3배 | 낮음 | 없음 |
| **2** | uregex/mf2 딕셔너리 추가 | 커버리지 대폭 증가 | 낮음 | 없음 |
| **3** | 시드 코퍼스 강화 | 초기 탐색 품질 | 낮음 | 없음 |
| **4** | **Structure-aware mutator** | **깊은 상태 탐색** | 중간 | **높음** |
| **5** | **크로스 API 하네스** | **API 조합 버그** | 중간 | **높음** |
| **6** | **Differential 퍼징** | **로직 버그 발견** | 중간 | **높음** |
| **7** | AFL++ 병행 | mutation 다양성 | 중간 | 낮음 |
| **8** | 버전 비교 퍼징 | regression 집중 | 중간 | 높음 |
| **9** | 클라우드 스케일링 | 전체 처리량 | 높음 | 없음 |

**핵심 인사이트**: 1~3번은 OSS-Fuzz와 동일한 전략을 강화하는 것이라 재발견 위주.
**4~6번이 진짜 0-day를 찾을 수 있는 차별화 포인트**이며, 우리 파이프라인의 존재 의의.
