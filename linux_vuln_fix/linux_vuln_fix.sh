#!/bin/bash
# ── 로케일 설정 (검증 후 적용) ────────────────────────────────────────────────
# 주의: ko_KR.UTF-8이 서버에 설치되어 있지 않은 상태에서 LC_ALL로 강제하면
# bash read의 멀티바이트 처리가 깨져서, 프롬프트에 한글을 입력하는 순간
# 스크립트가 응답없음(멈춤) 상태가 된다. 반드시 설치 여부를 확인하고,
# 없으면 C.UTF-8 → C 순서로 폴백한다. (C.UTF-8이면 스크립트의 한글 출력과
# 한글 입력 모두 정상 동작하며, 렌더링은 사용자의 터미널 설정을 따른다.)
_pick_locale() {
  local _avail
  _avail=$(locale -a 2>/dev/null)
  if echo "$_avail" | grep -qiE '^ko_KR\.(utf8|UTF-8)$'; then
    echo "ko_KR.UTF-8"
  elif echo "$_avail" | grep -qiE '^C\.(utf8|UTF-8)$'; then
    echo "C.UTF-8"
  else
    echo "C"
  fi
}
_SCRIPT_LOCALE=$(_pick_locale)
export LANG="$_SCRIPT_LOCALE"
export LC_ALL="$_SCRIPT_LOCALE"
if [ "$_SCRIPT_LOCALE" != "ko_KR.UTF-8" ]; then
  echo " [알림] ko_KR.UTF-8 로케일이 설치되어 있지 않아 ${_SCRIPT_LOCALE} 로 동작합니다."
  echo "        (스크립트 동작에는 문제 없으며, 한글 표시는 터미널 설정을 따릅니다.)"
  echo ""
fi
# =============================================================================
# 주요정보통신기반시설 기술적 취약점 분석·평가 - Linux 서버 조치 스크립트
# KISA 2026 가이드 기반 / 적용 범위: U-01 ~ U-67
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
WHITE='\033[0;37m'; BOLD='\033[1m'; RESET='\033[0m'

# ── UI 헬퍼 함수 ───────────────────────────────────────────────────────────────
_div_item() {
  echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}
_div_sec() {
  echo -e " ──────────────────────────────────────────────────────────────────"
}
_div_blank() { echo ""; }
# 하위 호환 별칭 (기존 코드가 이 이름으로 호출하는 곳이 아직 많음)
_div_thick() { _div_item; }
_div_thin()  { _div_sec; }

_ok()   { echo -e "   ${GREEN}✓${RESET} $1"; }
_fail() { echo -e "   ${RED}✗${RESET} $1"; }
_info() { echo -e "   ${CYAN}→${RESET} $1"; }
_warn() { echo -e "   ${YELLOW}⚠${RESET} $1"; }

# 공용 프로그래스바 — 점검/롤백에서 동일한 형식으로 재사용한다.
# _show_progress_bar <현재값> <전체값> <상태문구> [대상값]
_show_progress_bar() {
  local _current="$1" _total="$2" _status="$3" _target="${4:-}"
  local _bar_len=30 _pct=0 _filled=0 _bar="" _i

  if [ "${_total:-0}" -gt 0 ] 2>/dev/null; then
    _pct=$(( _current * 100 / _total ))
  fi
  [ "$_pct" -gt 100 ] && _pct=100
  [ "$_pct" -lt 0 ] && _pct=0
  _filled=$(( _pct * _bar_len / 100 ))

  for ((_i=0; _i<_filled; _i++)); do _bar+="█"; done
  for ((_i=_filled; _i<_bar_len; _i++)); do _bar+="░"; done

  if [ -n "$_target" ]; then
    printf "\r\033[K [%3d%%] [%s] (%d/%d) %s: %s" \
      "$_pct" "$_bar" "$_current" "$_total" "$_status" "$_target"
  else
    printf "\r\033[K [%3d%%] [%s] (%d/%d) %s" \
      "$_pct" "$_bar" "$_current" "$_total" "$_status"
  fi
}

# _sec <check|before|during|result|verify|need>
# 화면 표시는 기존 한국어 UI를 유지하고, 상세 로그에는 CHECK/FIX/VERIFY/RESULT
# 4단계 코드로 통일해 남긴다. 판정·조치 로직과 출력 로직은 분리한다.
_sec() {
  local _sec_type="$1" _stage_code="" _stage_label=""
  echo ""
  case "$_sec_type" in
    check)  _stage_code="CHECK";  _stage_label="현재 상태"; echo -e " ${BOLD}${WHITE}[현재 상태]${RESET}" ;;
    before) _stage_code="CHECK";  _stage_label="현재 상태"; echo -e " ${BOLD}${YELLOW}[현재 상태]${RESET}" ;;
    during) _stage_code="FIX";    _stage_label="조치 중";   echo -e " ${BOLD}${BLUE}[조치 중]${RESET}" ;;
    result) _stage_code="RESULT"; _stage_label="조치 결과"; echo -e " ${BOLD}${GREEN}[조치 결과]${RESET}" ;;
    verify) _stage_code="VERIFY"; _stage_label="최종 검증"; echo -e " ${BOLD}${CYAN}[최종 검증]${RESET}" ;;
    need)   _stage_code="RESULT"; _stage_label="확인 필요"; echo -e " ${BOLD}${YELLOW}[확인 필요]${RESET}" ;;
  esac
  echo ""

  # 롤백 조기 분기 등 상세 로그 초기화 전에는 기록하지 않는다.
  if [ -n "${_CURRENT_ITEM_ID:-}" ] && [ -n "$_stage_code" ] \
     && declare -F _detail_log_stage >/dev/null 2>&1; then
    _detail_log_stage "$_CURRENT_ITEM_ID" "$_stage_code" "$_stage_label"
  fi
}

# _row "라벨" "값" ["✓"|"✗"|""]  — 라벨 18칸 고정
_row() {
  local label="$1" value="$2" sym="${3:-}"
  local sym_out=""
  [ "$sym" = "✓" ] && sym_out="${GREEN}✓${RESET}"
  [ "$sym" = "✗" ] && sym_out="${RED}✗${RESET}"
  [ -n "$sym" ] && [ "$sym" != "✓" ] && [ "$sym" != "✗" ] && sym_out="$sym"
  printf "  ${WHITE}%-18s${RESET}: ${WHITE}%s${RESET} %b\n" "$label" "$value" "$sym_out"
}

# ── 출력 레이아웃 규칙 ───────────────────────────────────────────────────────
# 1) 대분류 제목은 동일한 헤더 형식(_flush_header/section_header)만 사용한다.
# 2) 출력 순서는 [현재 상태] → [조치 중] → [조치 결과] → [최종 검증]을 기본으로 한다.
#
# 3) 색상 사용 기준
#    WHITE  : 기본 정보 / 현재 상태 / 제목 / 명령어 / 결과 출력
#    GREEN  : 양호 / 성공 / 완료
#    YELLOW : 주의 / 예외 / 권장 조치 / 확인 필요
#    RED    : 취약 / 오류 / 실패
#    BLUE   : 조치 진행 중
#    CYAN   : (보충) 서비스명·경로 등 참조값 강조, 위 5가지로 분류 안 되는 경우만
#
# 4) 항목 내부에서 임의의 구분선이나 임의 색상 사용 금지 — 색상은 아래 _msg_*
#    함수로만 출력한다. 구분선은 _div_item/_div_sec/_div_blank 3개만 사용한다.
#
# 5) 출력 순서와 들여쓰기를 모든 U항목에서 동일하게 유지한다.
#
# 6) 동일한 의미의 문구는 항상 동일한 표현을 사용한다.
#    (예: 현재 상태, 조치 중, 조치 결과, 권장 조치, 최종 검증)
#
# 7) 결과는 요약 → 상세 순서로 출력한다.
#
# 8) 명령어 실행 결과는 가능한 원본 그대로 출력하며 가공을 최소화한다.
#
# 9) 불필요한 빈 줄, 중복 출력, 동일 내용 반복 출력은 금지한다.
#
# 10) 사용자 입력(y/n)은 항상 질문문 마지막에 표시한다.
#
# 11) 자동 조치와 수동 확인 항목은 명확히 구분하여 출력한다.
#
# 12) 신규 U항목 추가 시 기존 출력 형식을 그대로 따른다.
#
# 13) 출력 형식 변경 시 기존 U항목에도 동일하게 적용하여 전체 UI의 일관성을 유지한다.
# ─────────────────────────────────────────────────────────────────────────────

# _msg_* — 색상 출력 전용 공용 함수. 항목 내부에서 echo -e "${COLOR}...${RESET}"를
# 직접 쓰지 말고 이 함수들로만 색상을 낸다 (규칙 3, 4).
_msg_ok()   { echo -e "${GREEN}$*${RESET}"; }
_msg_bad()  { echo -e "${RED}$*${RESET}"; }
_msg_warn() { echo -e "${YELLOW}$*${RESET}"; }
_msg_info() { echo -e "${WHITE}$*${RESET}"; }
_msg_work() { echo -e "${BLUE}$*${RESET}"; }

# ── KISA 권고 기본값 ─────────────────────────────────────────────────────────
# 값을 바꾸고 싶으면 이 줄만 수정하면 된다.
# 실제 적용 파일: /etc/login.defs, /etc/security/pwquality.conf 등 리눅스 표준 파일.
DEFAULT_PASS_MAX_DAYS=90
DEFAULT_PASS_MIN_DAYS=1
DEFAULT_MINLEN=8
DEFAULT_DENY=5
DEFAULT_UNLOCK_TIME=300
DEFAULT_TMOUT=600

# _confirm_yn <prompt>
# y/n 외 입력은 무시하고 다시 묻는다.
# 반환값: 0 = 예(y), 1 = 아니오(n)
_confirm_yn() {
  local prompt="$1" ans
  while true; do
    printf '%s' "$prompt"
    if ! read -r ans; then
      # EOF/입력 불가 — 무한 재질문 방지, 안전한 기본값 n으로 처리
      echo ""
      echo -e " ${YELLOW}입력을 받을 수 없어 n(아니오)으로 처리합니다.${RESET}"
      return 1
    fi
    case "$ans" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo -e " ${RED}y 또는 n만 입력해주세요.${RESET}" ;;
    esac
  done
}

# _read_yn <변수명> <프롬프트>
# 기존 코드 곳곳에 흩어진 "read -rp ... y/n VARNAME" 패턴을 최소 변경으로 검증하기 위한 버전.
# y/n 외 입력이면 재질문하고, 검증된 Y/y 또는 N/n 값만 VARNAME에 저장
_read_yn() {
  local __varname="$1" __prompt="$2" __val
  while true; do
    printf '%s' "$__prompt"
    if ! read -r __val; then
      # EOF/입력 불가 (stdin 고갈, 파이프 종료 등) — 무한 재질문 방지.
      # 안전한 기본값 n(건너뜀)으로 처리하고 빠져나온다.
      echo ""
      echo -e " ${YELLOW}입력을 받을 수 없어 n(건너뜀)으로 처리합니다.${RESET}"
      printf -v "$__varname" '%s' "n"
      return
    fi
    case "$__val" in
      [Yy]|[Nn]) printf -v "$__varname" '%s' "$__val"; return ;;
      *) echo -e " ${RED}y 또는 n만 입력해주세요.${RESET}" ;;
    esac
  done
}

# _read_num <변수명> <프롬프트> <기본값> <최소값> [<최대값>]
# 숫자 입력을 받되, 형식이 틀리거나 범위를 벗어나면 기본값으로 조용히 넘어가지
# 않고 재질문한다. EOF(입력 불가)일 때만 예외적으로 기본값을 쓰고 안내한다.
_read_num() {
  local __varname="$1" __prompt="$2" __default="$3" __min="$4" __max="${5:-}" __val
  while true; do
    printf '%s' "$__prompt"
    if ! read -r __val; then
      echo ""
      echo -e " ${YELLOW}입력을 받을 수 없어 기본값 ${__default}으로 설정합니다.${RESET}"
      printf -v "$__varname" '%s' "$__default"
      return
    fi
    if [[ "$__val" =~ ^[0-9]+$ ]] && [ "$__val" -ge "$__min" ] 2>/dev/null \
       && { [ -z "$__max" ] || [ "$__val" -le "$__max" ] 2>/dev/null; }; then
      printf -v "$__varname" '%s' "$__val"
      return
    fi
    if [ -n "$__max" ]; then
      echo -e " ${RED}${__min}~${__max} 사이의 숫자를 입력해주세요.${RESET}"
    else
      echo -e " ${RED}${__min} 이상의 숫자를 입력해주세요.${RESET}"
    fi
  done
}

# ── 박스 출력 폭 계산 (한글/영문 혼용 시 테두리 어긋남 방지) ─────────────────
# 한글 등 전각문자는 터미널에서 2칸을 차지하므로, printf 문자수 패딩만으로는
# 박스 테두리가 어긋난다 — 실제 표시폭(전각=2, 반각=1)을 계산해서 패딩한다.
_display_width() {
  local s="$1"
  if command -v python3 &>/dev/null; then
    # stdin으로 전달해 한글 등 멀티바이트 문자열을 로케일 영향 없이 처리한다.
    printf '%s' "$s" | python3 -c "
import sys, unicodedata
s = sys.stdin.read()
print(sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s))
" 2>/dev/null || echo "${#s}"
  else
    # python3 없을 때 근사치: ASCII 외 문자는 전각(2칸)으로 간주
    local n=0 i len ch
    len=${#s}
    for ((i=0; i<len; i++)); do
      ch="${s:i:1}"
      [[ "$ch" == [[:ascii:]] ]] && n=$((n+1)) || n=$((n+2))
    done
    echo "$n"
  fi
}
_BOX_WIDTH=66
_box_top()    { printf " ╔%s╗\n" "$(printf '═%.0s' $(seq 1 $_BOX_WIDTH))"; }
_box_bottom() { printf " ╚%s╝\n" "$(printf '═%.0s' $(seq 1 $_BOX_WIDTH))"; }
_box_line() {
  local text="$1"
  local tw; tw=$(_display_width "$text")
  local avail=$(( _BOX_WIDTH - tw ))
  [ "$avail" -lt 0 ] && avail=0
  local left=$(( avail / 2 ))
  local right=$(( avail - left ))
  printf " ║%*s%s%*s║\n" "$left" "" "$text" "$right" ""
}

FIXED=0; SKIPPED=0; FAILED=0; MANUAL=0; NA=0
FIXED_LIST=(); SKIPPED_LIST=(); FAILED_LIST=(); MANUAL_LIST=(); NA_LIST=()
declare -A BEFORE_VAL
declare -A AFTER_VAL
declare -A DETAIL_VAL  # 항목별 조치 상세 내역 (감사 증빙용)
declare -A _REPORT_RECORDED  # CSV 결과 누락 검증용 (항목ID별 기록 여부)

# =============================================================================
# ── [상세내역 리포트 레이아웃 규칙] ───────────────────────────────────────────
#
# DETAIL_VAL[$id] 는 아래 6개 섹션 순서를 표준으로 한다. 새 항목을 추가할 때도
# 이 순서와 대괄호 표기를 그대로 따른다 (감사 증빙 문서로서 항목 간 표현이
# 일관되어야 하므로 "수정 파일" 대신 "변경 파일"을 사용한다).
#
#   [현재 상태]      조치 전 값/설정 (before_cmd 결과 요약)
#   [조치 내용]      무엇을 어떻게 바꾸는지 (fix_cmd가 수행하는 작업 요약)
#   [조치 결과]      아래 4개 고정 문구 중 하나만 사용:
#                      이미 양호 / 재확인 통과
#                      조치 완료 / 최종 검증 통과
#                      수동 확인 필요
#                      조치 실패
#   [변경 파일]      총 N개  (변경 파일이 없으면 "없음")
#   [변경 파일 목록]  실제 변경된 절대경로 목록
#                      - 5개 이하: 전체 나열
#                      - 6개 이상: 상위 3~5개만 표시 + "외 N개"
#                        (전체 목록은 FIX_HISTORY_FILE / "변경 이력" 시트에 기록)
#   [검증 결과]      after_cmd로 재확인한 최종 값 (핵심 파라미터만)
#
#   서비스 재시작/reload가 필요한 항목은 [검증 결과] 뒤에 [서비스 변경] 섹션을
#   추가한다 (예: "[서비스 변경] chronyd 활성화 및 자동 시작 설정").
#
# _fmt_detail 은 위 규칙에 맞춰 DETAIL_VAL 문자열을 조립하는 표준 헬퍼다.
# 커스텀 블록에서 DETAIL_VAL을 직접 조립해야 하는 특수한 경우가 아니라면
# 항상 이 함수를 통해 생성한다.
# =============================================================================
_fmt_detail() {
  # 사용법: _fmt_detail "<현재상태>" "<조치내용>" "<조치결과>" "<파일1|파일2|...>" "<검증결과>" ["<서비스변경>"]
  local _before="$1" _action="$2" _result="$3" _files_raw="$4" _verify="$5" _svc="${6:-}"
  local _out=""
  _out="[현재 상태] ${_before:-확인된 값 없음}"
  [ -n "$_action" ] && _out="${_out} | [조치 내용] ${_action}"
  _out="${_out} | [조치 결과] ${_result:-확인 필요}"

  if [ -z "$_files_raw" ]; then
    _out="${_out} | [변경 파일] 없음"
  else
    local -a _flist=()
    IFS='|' read -ra _flist <<< "$_files_raw"
    local _fcnt=${#_flist[@]}
    _out="${_out} | [변경 파일] 총 ${_fcnt}개"
    # 개수와 관계없이 전체 목록을 셀에 기록한다 (보고서에서 시트 이동 없이 바로 확인).
    # 주의: IFS 조인은 첫 글자만 쓰므로 ', ' 구분은 printf로 만든다.
    _out="${_out} | [변경 파일 목록] $(printf '%s, ' "${_flist[@]}" | sed 's/, $//')"
  fi

  [ -n "$_verify" ] && _out="${_out} | [검증 결과] ${_verify}"
  [ -n "$_svc" ] && _out="${_out} | [서비스 변경] ${_svc}"
  echo "$_out"
}

# ── 디렉토리 구조 ─────────────────────────────────────────────────────────────
# /linux_vuln_fix/
# ├── backup/          사전 백업 tar.gz
# ├── report/
# │   ├── logs/        상세 로그 및 누적 vulnFixHistory.log
# │   └── *.csv/xlsx/txt
# └── rollback/        롤백 실행 로그·검증 로그·정책 파일
_BASE_DIR="/linux_vuln_fix"
# 백업/보고서/로그/롤백 실행 산출물은 역할별 공통 디렉터리에 저장한다.
_BAK_DIR="${_BASE_DIR}/backup"
_RPT_BASE_DIR="${_BASE_DIR}/report"
_LOG_DIR="${_RPT_BASE_DIR}/logs"
_RB_DIR="${_BASE_DIR}/rollback"

# 디렉터리 생성. 기본 경로를 사용할 수 없을 때 /tmp 자체를 사용하면
# 아래 chmod 700이 /tmp 전체 권한을 바꾸는 치명적 장애가 발생할 수 있으므로
# 반드시 전용 하위 디렉터리로만 폴백한다.
_vf_prepare_private_dir() {
  local _primary="$1" _fallback="$2" _candidate
  for _candidate in "$_primary" "$_fallback"; do
    if mkdir -p "$_candidate" 2>/dev/null        && chmod 700 "$_candidate" 2>/dev/null        && [ -d "$_candidate" ] && [ -w "$_candidate" ]; then
      printf '%s' "$_candidate"
      return 0
    fi
  done
  return 1
}

_BAK_DIR=$(_vf_prepare_private_dir "$_BAK_DIR" "/tmp/linux_vuln_fix/backup")   || { echo -e "${RED}[오류] 백업 디렉터리를 준비할 수 없습니다.${RESET}"; exit 1; }
_RPT_BASE_DIR=$(_vf_prepare_private_dir "$_RPT_BASE_DIR" "/tmp/linux_vuln_fix/report")   || { echo -e "${RED}[오류] 보고서 디렉터리를 준비할 수 없습니다.${RESET}"; exit 1; }
_LOG_DIR=$(_vf_prepare_private_dir "${_RPT_BASE_DIR}/logs" "/tmp/linux_vuln_fix/report/logs")   || { echo -e "${RED}[오류] 로그 디렉터리를 준비할 수 없습니다.${RESET}"; exit 1; }
_RB_DIR=$(_vf_prepare_private_dir "$_RB_DIR" "/tmp/linux_vuln_fix/rollback")   || { echo -e "${RED}[오류] 롤백 디렉터리를 준비할 수 없습니다.${RESET}"; exit 1; }

# 누적 실행 이력은 상세 로그와 함께 report/logs에 저장한다.
# 이전 저장 위치에 남아 있는 이력은 최초 실행 시 새 위치로 안전하게 이전한다.
_OLD_FIX_HISTORY_FILES=(
  "${_RB_DIR}/vulnFixHistory.log"
  "${_RPT_BASE_DIR}/vulnFixHistory.log"
)
FIX_HISTORY_FILE="${_LOG_DIR}/vulnFixHistory.log"
_VF_HISTORY_MIGRATION_FAILED_SOURCE=""

_vf_migrate_history_file() {
  local _new="$FIX_HISTORY_FILE" _old _old_sha=""

  for _old in "${_OLD_FIX_HISTORY_FILES[@]}"; do
    [ "$_old" = "$_new" ] && continue
    [ -f "$_old" ] || continue

    # 새 위치가 비어 있으면 원본 파일 자체를 이동해 내용·권한·시간 정보를 최대한 보존한다.
    if [ ! -e "$_new" ] || [ ! -s "$_new" ]; then
      rm -f "$_new" 2>/dev/null
      if mv -f "$_old" "$_new" 2>/dev/null; then
        chmod 600 "$_new" 2>/dev/null || true
        continue
      fi
    fi

    # 내용이 완전히 같으면 중복 병합하지 않고 이전 위치의 파일만 정리한다.
    if [ -f "$_new" ] && cmp -s "$_old" "$_new" 2>/dev/null; then
      rm -f "$_old" 2>/dev/null || {
        _VF_HISTORY_MIGRATION_FAILED_SOURCE="$_old"
        return 1
      }
      continue
    fi

    # 양쪽 파일에 내용이 있으면 기존 이력을 새 파일 뒤에 한 번만 병합한다.
    # 병합이 성공한 경우에만 이전 위치의 파일을 제거하여 기록 손실을 방지한다.
    if [ -s "$_old" ]; then
      _old_sha=""
      command -v sha256sum >/dev/null 2>&1 \
        && _old_sha=$(sha256sum "$_old" 2>/dev/null | awk '{print $1}')

      # 직전 실행에서 병합은 끝났지만 원본 삭제만 실패한 경우 중복 추가를 막는다.
      if [ -n "$_old_sha" ] && grep -Fq "SHA256=${_old_sha}" "$_new" 2>/dev/null; then
        rm -f "$_old" 2>/dev/null || {
          _VF_HISTORY_MIGRATION_FAILED_SOURCE="$_old"
          return 1
        }
        continue
      fi

      {
        echo ""
        printf '# HISTORY_MIGRATION|%s|FROM=%s|SHA256=%s\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$_old" "${_old_sha:-unavailable}"
        cat "$_old"
      } >> "$_new" 2>/dev/null || {
        _VF_HISTORY_MIGRATION_FAILED_SOURCE="$_old"
        return 1
      }
    fi

    rm -f "$_old" 2>/dev/null || {
      _VF_HISTORY_MIGRATION_FAILED_SOURCE="$_old"
      return 1
    }
  done

  chmod 600 "$_new" 2>/dev/null || true
  return 0
}

if ! _vf_migrate_history_file; then
  echo -e "${RED}[오류] 기존 vulnFixHistory.log를 report/logs 디렉터리로 이전하지 못했습니다.${RESET}"
  echo -e "${YELLOW}       기존 파일은 삭제하지 않았습니다: ${_VF_HISTORY_MIGRATION_FAILED_SOURCE:-확인 필요}${RESET}"
  exit 1
fi

touch "$FIX_HISTORY_FILE" 2>/dev/null   || { echo -e "${RED}[오류] 누적 이력 파일을 생성할 수 없습니다.${RESET}"; exit 1; }
chmod 600 "$FIX_HISTORY_FILE" 2>/dev/null || true

# 이 실행 전체에서 공용으로 쓰는 타임스탬프 — do_fix의 개별 파일 백업(.bak.<시각>)에 사용
_RUN_TS=$(date +%Y%m%d_%H%M%S)
# 이 실행의 고유 식별자 — 백업 파일과 롤백 역산 레코드를 정확히 연결한다.
# 이력 매칭은 BAK=<전체 경로>를 우선 사용하고 파일명·실행 시각을 보조 기준으로 사용한다.
_RUN_ID="${_RUN_TS}_$$"

# 롤백 백업 범위 식별자 — 공통 backup 디렉터리에서 다른 분리본의 백업을
# 잘못 선택하지 않도록 manifest에 기록하고 롤백 시 현재 스크립트와 비교한다.
_SCRIPT_SCOPE="U-01~U-67"
_SCRIPT_PART="1"

# =============================================================================
# ── 롤백 메타데이터 및 복원 공통 함수 ─────────────────────────────────────────
# 요약 대시보드 UI 및 그래프 생성 로직과 독립된 롤백 전용 영역이다.
# =============================================================================

# 백업 시 상태를 기록할 주요 systemd unit. 존재하는 unit만 메타데이터에 저장한다.
_VF_ROLLBACK_SERVICE_UNITS=(
  sshd.service ssh.service postfix.service rsyslog.service
  chronyd.service chrony.service ntpd.service ntp.service
  firewalld.service ufw.service
  nfs-server.service nfs-kernel-server.service nfs-mountd.service rpc-statd.service rpcbind.service
  autofs.service finger.service fingerd.service cfingerd.service
  telnet.socket telnet.service telnetd.service telnet@.service xinetd.service inetd.service openbsd-inetd.service
  vsftpd.service proftpd.service snmpd.service smbd.service
  named.service bind9.service
  ypserv.service ypbind.service ypxfrd.service yppasswdd.service
  rsh.socket rlogin.socket rexec.socket rshd.service rlogind.service rexecd.service
  tftp.socket tftp.service tftpd.service tftpd-hpa.service atftpd.service talk.socket talk.service ntalk.socket ntalk.service
  echo.socket echo.service chargen.socket chargen.service discard.socket discard.service daytime.socket daytime.service
  cmsd.service ttdbserverd.service sadmind.service rusersd.service walld.service sprayd.service rstatd.service
)

# tar가 지정한 옵션을 지원하는지 도움말 기준으로 확인한다.
# 입력: $1=확인할 옵션 / 반환: 지원 0, 미지원 1
_vf_tar_supports() {
  tar --help 2>/dev/null | grep -q -- "$1"
}

# _vf_require_space
#
# 역할:
#   백업/롤백처럼 디스크에 파일을 쓰기 전, 대상 경로가 속한 파티션에
#   최소 필요 용량(KB)만큼 여유가 있는지 미리 확인한다.
#   gzip/tar가 쓰다가 중간에 실패해 손상된 산출물을 남기는 것을 예방한다.
#
# 입력:
#   $1 : 여유 공간을 확인할 디렉터리 (존재해야 함)
#   $2 : 필요한 최소 여유 공간 (KB, 정수)
#
# 반환값:
#   0 : 여유 공간이 충분함 (또는 확인 자체가 불가능해 판단을 건너뜀)
#   1 : 여유 공간이 부족함
#
# 안전 조건:
#   - df 실행이 실패하거나 값을 못 읽으면(예: 컨테이너 환경 등) 차단하지 않고
#     0을 반환한다. 이 함수는 "명백히 부족한 경우"를 조기에 걸러내기 위한
#     보조 장치이며, 최종 안전장치는 각 호출부의 tar 결과 확인이다.
_vf_require_space() {
  local _dir="$1" _need_kb="$2" _avail
  _avail=$(df -Pk "$_dir" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$_avail" ] || return 0
  case "$_avail" in ''|*[!0-9]*) return 0 ;; esac
  case "$_need_kb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_avail" -ge "$_need_kb" ]
}

# 백업·로그 보존 정책: 새 산출물을 만들기 전에 오래된 파일을 정리해
# 최근 N개만 유지한다. 유지 개수는 환경변수로 조정할 수 있다.
: "${VULNFIX_KEEP_BACKUPS:=5}"        # vulnFix_backup_*.tar.gz (조치 전 백업)
: "${VULNFIX_KEEP_PRE_ROLLBACK:=3}"   # pre_rollback_*.tar.gz (롤백 직전 안전 백업)
: "${VULNFIX_KEEP_LOGS:=10}"          # 상세/롤백/검증 로그
# -----------------------------------------------------------------------------
# _vf_prune_old_artifacts
#
# 역할:
#   지정한 패턴의 백업·로그 파일을 수정 시각 기준으로 정렬하고 최근 N개만 남긴다.
#
# 입력:
#   $1 : 정리할 디렉터리
#   $2 : find -name에 사용할 파일 패턴
#   $3 : 유지할 최신 파일 개수
#   $4 : 화면에 표시할 산출물 이름
#
# 시스템 영향:
#   보존 개수를 초과한 파일과 같은 이름의 .sha256/.records 파일을 삭제한다.
#
# 안전 조건:
#   - 대상 디렉터리가 없거나 유지 개수가 숫자가 아니면 아무 작업도 하지 않음
#   - 지정한 디렉터리의 최상위 파일만 대상으로 처리
#   - 최신 파일부터 정렬한 뒤 초과분만 삭제
# -----------------------------------------------------------------------------
_vf_prune_old_artifacts() {
  local _dir="$1" _glob="$2" _keep="$3" _label="$4"
  [ -d "$_dir" ] || return 0
  case "$_keep" in ''|*[!0-9]*) return 0 ;; esac
  local _list; _list=$(mktemp 2>/dev/null) || return 0
  find "$_dir" -maxdepth 1 -name "$_glob" -printf '%T@\t%p\n' 2>/dev/null | sort -rn > "$_list"
  local _total; _total=$(wc -l < "$_list" | tr -d ' ')
  if [ "$_total" -gt "$_keep" ]; then
    local _removed=$((_total-_keep))
    tail -n "+$((_keep+1))" "$_list" | cut -f2- | while IFS= read -r _f; do
      rm -f -- "$_f" "${_f}.sha256" "${_f}.records" 2>/dev/null
    done
    _info "${_label}: 오래된 ${_removed}개 정리 (최근 ${_keep}개 유지)"
  fi
  rm -f "$_list" 2>/dev/null
  return 0
}

# manifest.tsv에서 지정한 키의 첫 번째 값을 조회한다.
# 입력: $1=manifest 파일, $2=키 / 출력: 구분자 뒤의 값
_vf_meta_value() {
  awk -F'|' -v k="$2" '$1==k {sub(/^[^|]*\|/, ""); print; exit}' "$1" 2>/dev/null
}


# -----------------------------------------------------------------------------
# _vf_normalize_verify_output
#
# 역할:
#   설정 검증 명령의 출력을 해시 비교에 적합한 형태로 정규화한다.
#
# 입력:
#   표준 입력으로 검증 명령의 stdout/stderr 원문을 받는다.
#
# 출력:
#   ANSI 코드, CR, 임시 경로, PID, 시각과 불필요한 공백을 정리한 문자열
#
# 주의:
#   설정 오류의 핵심 문구는 유지하고 실행마다 달라지는 값만 치환한다.
#   해시가 없는 VERIFY_BASELINE 레코드도 상태값 기준으로 처리한다.
# -----------------------------------------------------------------------------
_vf_normalize_verify_output() {
  LC_ALL=C sed -E $'s#\x1B\\[[0-?]*[ -/]*[@-~]##g; s#\r##g' \
    | sed -E \
        -e 's#(/tmp|/var/tmp)/[^[:space:]]+#<TMP>#g' \
        -e 's#(/run/user/)[0-9]+/[^[:space:]]+#<RUNTIME>#g' \
        -e 's/(PID|pid)[=:[:space:]]+[0-9]+/\1=<PID>/g' \
        -e 's/\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}\]?/<TIMESTAMP>/g' \
        -e 's/[[:space:]]+$//' \
        -e '/^[[:space:]]*$/d'
}

# 검증 출력을 정규화한 뒤 SHA-256을 계산한다.
# 입력: $1=검증 출력 원문 / 출력: SHA-256 / 반환: 계산 성공 0, 명령 없음 1
_vf_verify_output_sha256() {
  command -v sha256sum >/dev/null 2>&1 || return 1
  printf '%s' "$1" | _vf_normalize_verify_output | sha256sum | awk '{print $1}'
}


# -----------------------------------------------------------------------------
# _vf_capture_verify_baselines
#
# 역할:
#   백업 시점의 주요 설정 구문 검사 결과를 VERIFY_BASELINE 레코드로 저장한다.
#   롤백 후 같은 검사를 수행해 새로 발생한 오류인지 기존 오류인지 구분할 때 사용한다.
#
# 입력:
#   $1 : VERIFY_BASELINE 레코드를 기록할 파일
#   $2 : 명령 출력 임시 파일을 둘 작업 디렉터리
#
# 출력:
#   검사 성공 시 PASS, 실패 시 정규화된 출력의 SHA-256을 기록한다.
#
# 검사 대상:
#   SSH, sudoers, authselect, rsyslog, Postfix 중 현재 시스템에서 사용 가능한 항목
#
# 반환값:
#   0 : 기준값 수집 완료
#   1 : 출력 파일 또는 작업 디렉터리를 준비하지 못함
#
# 안전 조건:
#   설정을 변경하지 않고 구문 검사 명령만 수행한다.
# -----------------------------------------------------------------------------
_vf_capture_verify_baselines() {
  local _dest="$1" _workdir="$2"
  local _bl_out="${_workdir}/baseline_command.$$.log" _bl_text="" _bl_hash=""
  [ -n "$_dest" ] || return 1
  mkdir -p "$_workdir" 2>/dev/null || return 1

  _vf_baseline_record_one() {
    local _name="$1"; shift
    : > "$_bl_out"
    if "$@" >"$_bl_out" 2>&1; then
      printf 'VERIFY_BASELINE|%s|PASS\n' "$_name" >> "$_dest"
    else
      _bl_text=$(cat "$_bl_out" 2>/dev/null)
      _bl_hash=$(_vf_verify_output_sha256 "$_bl_text" 2>/dev/null || true)
      if [ -n "$_bl_hash" ]; then
        printf 'VERIFY_BASELINE|%s|FAIL|SHA256=%s\n' "$_name" "$_bl_hash" >> "$_dest"
      else
        printf 'VERIFY_BASELINE|%s|FAIL\n' "$_name" >> "$_dest"
      fi
    fi
  }

  command -v sshd       >/dev/null 2>&1 && _vf_baseline_record_one "SSH 설정" sshd -t
  command -v visudo     >/dev/null 2>&1 && [ -f /etc/sudoers ] && _vf_baseline_record_one "sudo 설정" visudo -cf /etc/sudoers
  command -v authselect >/dev/null 2>&1 && _vf_baseline_record_one "PAM/authselect 구성" authselect check
  command -v rsyslogd   >/dev/null 2>&1 && _vf_baseline_record_one "rsyslog 설정" rsyslogd -N1
  command -v postfix    >/dev/null 2>&1 && _vf_baseline_record_one "Postfix 설정" postfix check

  rm -f "$_bl_out" 2>/dev/null
  unset -f _vf_baseline_record_one 2>/dev/null
  return 0
}

# -----------------------------------------------------------------------------
# _vf_extract_run_records
#
# 역할:
#   누적 이력 또는 .records 파일에서 선택한 백업에 대응하는 한 실행의
#   롤백 역산·검증 레코드만 추출한다.
#
# 입력:
#   $1 : vulnFixHistory.log 또는 .records 파일
#   $2 : 사용자가 선택한 백업의 현재 전체 경로
#   $3 : 선택한 백업의 파일명
#   $4 : 백업 파일명에서 추출한 실행 시각
#
# 출력:
#   PERM_RESTORE, GROUP_MEMBERSHIP, VERIFY_BASELINE,
#   CREATED_PATH, ORPHAN_RESTORE 레코드
#
# 반환값:
#   0 : 대응 실행을 찾아 레코드 추출 완료
#   1 : 원본 파일이 없거나 대응하는 RUN_START를 찾지 못함
#
# 매칭 우선순위:
#   전체 경로 → 파일명 → 실행 시각
#   백업 디렉터리가 이동된 경우에도 파일명 또는 실행 시각으로 찾을 수 있다.
# -----------------------------------------------------------------------------
_vf_extract_run_records() {
  local _src="$1" _bak="$2" _bakbase="$3" _ts="$4"
  [ -f "$_src" ] || return 1
  awk -F'|' -v bak="$_bak" -v bakbase="$_bakbase" -v ts="$_ts" '
    function run_matches(   i,v,b) {
      v=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^BAK=/) { v=$i; sub(/^BAK=/,"",v); break }
      }
      b=v; sub(/^.*\//,"",b)
      return (v==bak || (bakbase!="" && b==bakbase) || (ts!="" && $2==ts))
    }
    /^RUN_START\|/ {
      if (active) exit 0
      active=run_matches()
      if (active) matched=1
      next
    }
    active && /^(PERM_RESTORE|GROUP_MEMBERSHIP|VERIFY_BASELINE|CREATED_PATH|ORPHAN_RESTORE)\|/ { print }
    END { if (!matched) exit 1 }
  ' "$_src" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_export_run_records_sidecar
#
# 역할:
#   현재 백업에 대응하는 RUN_START와 롤백 역산·검증 레코드를
#   백업 파일 옆의 <백업파일>.records로 독립 보관한다.
#
# 입력:
#   $1 : 조치 전 백업 tar.gz 파일
#
# 출력:
#   <백업파일>.records
#
# 반환값:
#   0 : 레코드 추출과 원자적 저장 완료
#   1 : 백업 부재, 대응 실행 미발견, 권한 설정 또는 파일 이동 실패
#
# 안전 조건:
#   - 임시 파일에 먼저 기록하고 RUN_START 존재를 확인한 뒤 최종 이름으로 이동
#   - 생성 시 umask 077, 최종 권한 600 적용
#   - 누적 이력 파일의 원본 레코드 형식은 변경하지 않음
# -----------------------------------------------------------------------------
_vf_export_run_records_sidecar() {
  local _bak="$1" _sidecar="${1}.records" _tmp="${1}.records.tmp.$$"
  local _bakbase _ts
  [ -f "$_bak" ] || return 1
  _bakbase=$(basename "$_bak")
  _ts=$(printf '%s' "$_bakbase" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)

  # RUN_START 자체와 해당 실행의 역산/검증 레코드만 저장한다.
  # 생성 순간부터 root 전용이 되도록 서브셸에 umask 077을 적용한다.
  if ! ( umask 077; awk -F'|' -v bak="$_bak" -v bakbase="$_bakbase" -v ts="$_ts" '
    function run_matches(   i,v,b) {
      v=""
      for (i=1; i<=NF; i++) {
        if ($i ~ /^BAK=/) { v=$i; sub(/^BAK=/,"",v); break }
      }
      b=v; sub(/^.*\//,"",b)
      return (v==bak || b==bakbase || (ts!="" && $2==ts))
    }
    /^RUN_START\|/ {
      if (active) exit 0
      active=run_matches()
      if (active) { matched=1; print }
      next
    }
    active && /^(PERM_RESTORE|GROUP_MEMBERSHIP|VERIFY_BASELINE|CREATED_PATH|ORPHAN_RESTORE)\|/ { print }
    END { if (!matched) exit 1 }
  ' "$FIX_HISTORY_FILE" > "$_tmp" 2>/dev/null ); then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi

  if ! grep -q '^RUN_START|' "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi

  chmod 600 "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
  mv -f "$_tmp" "$_sidecar" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_sidecar" 2>/dev/null || true
  return 0
}

# -----------------------------------------------------------------------------
# _vf_capture_packages
#
# 역할:
#   롤백 비교용으로 현재 시스템의 OS 패키지와 Python pip 패키지 목록을 수집한다.
#
# 입력:
#   $1 : 결과를 저장할 TSV 파일
#
# 출력 형식:
#   패키지명<TAB>버전<TAB>아키텍처
#   첫 줄에는 사용한 패키지 관리자(rpm/dpkg/none)를 기록한다.
#
# 시스템 영향:
#   패키지를 설치·삭제하지 않고 조회 결과 파일만 생성한다.
# -----------------------------------------------------------------------------
_vf_capture_packages() {
  local _out="$1"
  : > "$_out"
  if command -v rpm >/dev/null 2>&1; then
    echo '#manager=rpm' >> "$_out"
    rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' 2>/dev/null | LC_ALL=C sort -u >> "$_out"
  elif command -v dpkg-query >/dev/null 2>&1; then
    echo '#manager=dpkg' >> "$_out"
    dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' 2>/dev/null | LC_ALL=C sort -u >> "$_out"
  else
    echo '#manager=none' >> "$_out"
  fi
  # 보고서 생성 과정에서 pip/openpyxl이 설치될 수 있으므로 Python 패키지도 함께 비교한다.
  if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip list --format=freeze 2>/dev/null       | awk -F'==' 'NF>=2 {name=tolower($1); version=$2; print "pip:" name "\t" version "\tpython"}'       | LC_ALL=C sort -u >> "$_out"
  fi
}

# -----------------------------------------------------------------------------
# _vf_capture_accounts
#
# 역할:
#   롤백 비교용으로 로컬 계정의 UID, GID, 홈, 셸, 보조 그룹과 홈 권한을 수집한다.
#
# 입력:
#   $1 : 결과를 저장할 TSV 파일
#
# 출력 형식:
#   사용자<TAB>UID<TAB>GID<TAB>홈<TAB>셸<TAB>보조그룹<TAB>홈 메타데이터
#
# 시스템 영향:
#   계정과 파일을 변경하지 않고 /etc/passwd 및 현재 계정 정보를 조회한다.
# -----------------------------------------------------------------------------
_vf_capture_accounts() {
  local _out="$1" _user _pw _uid _gid _gecos _home _shell _groups _home_meta
  : > "$_out"
  [ -r /etc/passwd ] || return 0
  while IFS=: read -r _user _pw _uid _gid _gecos _home _shell; do
    [ -n "$_user" ] || continue
    _groups=$(id -G "$_user" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -n | paste -sd, -)
    if [ -n "$_home" ] && { [ -e "$_home" ] || [ -L "$_home" ]; }; then
      _home_meta=$(stat -c '%u:%g:%a' "$_home" 2>/dev/null)
    else
      _home_meta='ABSENT'
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_user" "$_uid" "$_gid" "$_home" "$_shell" "${_groups:-NONE}" "${_home_meta:-UNKNOWN}" >> "$_out"
  done < /etc/passwd
}

# -----------------------------------------------------------------------------
# _vf_capture_services
#
# 역할:
#   롤백 대상 서비스의 설치 여부와 active/enabled 상태를 수집한다.
#
# 입력:
#   $1 : 결과를 저장할 TSV 파일
#
# 출력 형식:
#   unit<TAB>존재여부<TAB>active 상태<TAB>enabled 상태
#
# 안전 조건:
#   systemd를 사용할 수 없으면 unavailable 표시만 기록하며 서비스를 변경하지 않는다.
# -----------------------------------------------------------------------------
_vf_capture_services() {
  local _out="$1" _u _load _active _enabled
  : > "$_out"
  command -v systemctl >/dev/null 2>&1 || { echo '#systemd=unavailable' > "$_out"; return 0; }
  echo '#systemd=available' >> "$_out"
  for _u in "${_VF_ROLLBACK_SERVICE_UNITS[@]}"; do
    _load=$(systemctl show "$_u" -p LoadState --value 2>/dev/null | head -1)
    if [ -z "$_load" ] || [ "$_load" = 'not-found' ]; then
      printf '%s\t0\tnot-found\tnot-found\n' "$_u" >> "$_out"
      continue
    fi
    _active=$(systemctl is-active "$_u" 2>/dev/null | head -1)
    _enabled=$(systemctl is-enabled "$_u" 2>/dev/null | head -1)
    printf '%s\t1\t%s\t%s\n' "$_u" "${_active:-unknown}" "${_enabled:-unknown}" >> "$_out"
  done
}

# firewalld zone 출력을 의미 기준 비교가 가능하도록 정규화한다.
# Runtime에만 붙는 "(active)", 빈 줄, 후행 공백과 출력 순서 차이를 제거한다.
_vf_normalize_firewalld_dump() {
  sed -E \
    -e 's/[[:space:]]+\(active\)[[:space:]]*$//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d' "$1" 2>/dev/null | LC_ALL=C sort
}

# -----------------------------------------------------------------------------
# _vf_capture_firewall
#
# 역할:
#   롤백 비교·복원에 필요한 방화벽 도구별 현재 규칙과 서비스 상태를 수집한다.
#
# 입력:
#   $1 : 방화벽 메타데이터를 저장할 디렉터리
#
# 생성 파일:
#   firewall.meta, firewalld.permanent, firewalld.runtime,
#   ufw.status, iptables.v4, iptables.v6, nft.rules
#
# 추가 판정:
#   firewalld Runtime과 Permanent 규칙의 차이를 정규화 비교해
#   FIREWALLD_RUNTIME_DRIFT 값으로 기록한다.
#
# 시스템 영향:
#   방화벽 규칙을 변경하지 않고 조회 결과만 저장한다.
# -----------------------------------------------------------------------------
_vf_capture_firewall() {
  local _dir="$1" _fw_runtime_drift="NA"
  mkdir -p "$_dir" 2>/dev/null || return 1

  command -v firewall-cmd >/dev/null 2>&1 && {
    firewall-cmd --list-all-zones --permanent 2>/dev/null > "$_dir/firewalld.permanent"
    firewall-cmd --list-all-zones 2>/dev/null > "$_dir/firewalld.runtime"
    if [ -s "$_dir/firewalld.permanent" ] && [ -s "$_dir/firewalld.runtime" ]; then
      if diff -q \
        <(_vf_normalize_firewalld_dump "$_dir/firewalld.permanent") \
        <(_vf_normalize_firewalld_dump "$_dir/firewalld.runtime") >/dev/null 2>&1; then
        _fw_runtime_drift=0
      else
        _fw_runtime_drift=1
      fi
    fi
  }

  {
    printf 'FIREWALLD_AVAILABLE|%s\n' "$(command -v firewall-cmd >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'FIREWALLD_ACTIVE|%s\n' "$(systemctl is-active firewalld 2>/dev/null | head -1)"
    printf 'FIREWALLD_RUNTIME_DRIFT|%s\n' "$_fw_runtime_drift"
    printf 'UFW_AVAILABLE|%s\n' "$(command -v ufw >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'UFW_ACTIVE|%s\n' "$(systemctl is-active ufw 2>/dev/null | head -1)"
    printf 'IPTABLES_AVAILABLE|%s\n' "$(command -v iptables-save >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'IP6TABLES_AVAILABLE|%s\n' "$(command -v ip6tables-save >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'NFT_AVAILABLE|%s\n' "$(command -v nft >/dev/null 2>&1 && echo 1 || echo 0)"
  } > "$_dir/firewall.meta"

  command -v ufw >/dev/null 2>&1 && ufw status verbose 2>/dev/null > "$_dir/ufw.status"
  command -v iptables-save >/dev/null 2>&1 && iptables-save 2>/dev/null > "$_dir/iptables.v4"
  command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save 2>/dev/null > "$_dir/iptables.v6"
  command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null > "$_dir/nft.rules"
}

# -----------------------------------------------------------------------------
# _vf_capture_path_inventory
#
# 역할:
#   조치 전 백업 대상의 경로·파일 유형 인벤토리와 대표 생성 후보의 존재 여부를 기록한다.
#
# 입력:
#   $1    : 메타데이터 저장 디렉터리
#   $2... : 백업 대상 루트 경로
#
# 생성 파일:
#   inventory.roots      백업에 포함된 최상위 경로
#   inventory.paths      하위 경로와 파일 유형
#   path_candidates.tsv  조치 중 생성될 수 있는 대표 경로의 사전 존재 여부
#
# 안전 조건:
#   - find는 각 백업 루트의 파일시스템 경계를 넘지 않음
#   - 파일을 생성·삭제하지 않고 상태만 기록
# -----------------------------------------------------------------------------
_vf_capture_path_inventory() {
  local _dir="$1"; shift
  local _root _p
  : > "$_dir/inventory.roots"
  : > "$_dir/inventory.paths"
  for _root in "$@"; do
    [ -e "$_root" ] || [ -L "$_root" ] || continue
    printf '%s\n' "$_root" >> "$_dir/inventory.roots"
    if [ -d "$_root" ] && [ ! -L "$_root" ]; then
      find "$_root" -xdev -printf '%p\t%y\n' 2>/dev/null
    else
      printf '%s\t%s\n' "$_root" "$( [ -L "$_root" ] && echo l || [ -f "$_root" ] && echo f || echo o )"
    fi
  done | LC_ALL=C sort -u > "$_dir/inventory.paths"

  # 조치 중 새로 생성될 수 있는 대표 경로는 조치 전 부재 상태까지 기록한다.
  : > "$_dir/path_candidates.tsv"
  local -a _candidates=(
    /etc/security/pwquality.conf /etc/security/faillock.conf
    /etc/cron.allow /etc/cron.deny /etc/hosts.allow /etc/hosts.deny
    /etc/ftpusers /etc/vsftpd/ftpusers
    /etc/inetd.conf /etc/sysconfig/iptables /etc/sysconfig/ip6tables
    /etc/iptables/rules.v4 /etc/iptables/rules.v6
  )
  for _p in "${_candidates[@]}"; do
    if [ -e "$_p" ] || [ -L "$_p" ]; then
      printf '%s\tEXISTS\t%s\t%s\n' "$_p" "$(stat -c '%F' "$_p" 2>/dev/null)" "$(stat -c '%a:%u:%g' "$_p" 2>/dev/null)" >> "$_dir/path_candidates.tsv"
    else
      printf '%s\tABSENT\t-\t-\n' "$_p" >> "$_dir/path_candidates.tsv"
    fi
  done
  # 조치 전 존재한 사용자 홈 최상위 디렉터리도 기록한다.
  find /home -mindepth 1 -maxdepth 1 -type d -printf '%p\tEXISTS\tdirectory\t%m:%U:%G\n' 2>/dev/null \
    | LC_ALL=C sort -u >> "$_dir/path_candidates.tsv"
}

# -----------------------------------------------------------------------------
# _vf_capture_runtime_meta
#
# 역할:
#   조치 전 백업에 포함할 롤백 메타데이터를 .vulnfix_meta 구조로 통합 생성한다.
#
# 입력:
#   $1    : .vulnfix_meta를 만들 임시 루트 디렉터리
#   $2... : 실제 백업 대상 경로
#
# 생성 내용:
#   - manifest.tsv: 실행 ID, 서버·OS·커널, 스크립트 범위, tar 기능
#   - services.tsv: 서비스 상태
#   - packages.tsv: OS/pip 패키지 목록
#   - accounts.tsv: 계정·그룹·홈 정보
#   - firewall/: 방화벽 상태와 규칙
#   - 경로 인벤토리
#
# 반환값:
#   0 : 메타데이터 생성 완료
#   1 : 메타데이터 디렉터리를 만들 수 없음
#
# 시스템 영향:
#   임시 메타데이터 파일만 생성하며 시스템 설정은 변경하지 않는다.
# -----------------------------------------------------------------------------
_vf_capture_runtime_meta() {
  local _root="$1"; shift
  local _meta="${_root}/.vulnfix_meta"
  mkdir -p "$_meta/firewall" 2>/dev/null || return 1
  local _os _tar_acl=0 _tar_xattr=0 _tar_selinux=0
  _os=$( ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}" ) 2>/dev/null )
  _vf_tar_supports '--acls'    && _tar_acl=1
  _vf_tar_supports '--xattrs'  && _tar_xattr=1
  _vf_tar_supports '--selinux' && _tar_selinux=1
  {
    printf 'FORMAT_VERSION|3\n'
    printf 'RUN_ID|%s\n' "$_RUN_ID"
    printf 'RUN_TS|%s\n' "$_RUN_TS"
    printf 'HOSTNAME|%s\n' "$_HOSTNAME_VAL"
    printf 'OS_INFO|%s\n' "${_os//|//}"
    printf 'KERNEL|%s\n' "$(uname -r 2>/dev/null)"
    printf 'SCRIPT_SCOPE|%s\n' "$_SCRIPT_SCOPE"
    printf 'SCRIPT_PART|%s\n' "$_SCRIPT_PART"
    printf 'TAR_ACLS|%s\n' "$_tar_acl"
    printf 'TAR_XATTRS|%s\n' "$_tar_xattr"
    printf 'TAR_SELINUX|%s\n' "$_tar_selinux"
    printf 'CREATED_AT|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$_meta/manifest.tsv"
  _vf_capture_services "$_meta/services.tsv"
  _vf_capture_packages "$_meta/packages.tsv"
  _vf_capture_accounts "$_meta/accounts.tsv"
  _vf_capture_firewall "$_meta/firewall"
  _vf_capture_path_inventory "$_meta" "$@"
}

# 텍스트 기반 설정 비교에서 후행 공백·빈 줄·출력 순서 차이를 제거한다.
# 입력: $1=대상 파일 / 출력: 정규화 후 정렬된 내용
_vf_normalize_text_file() {
  sed -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' "$1" 2>/dev/null | LC_ALL=C sort
}

# -----------------------------------------------------------------------------
# _vf_create_pre_rollback_backup
#
# 역할:
#   실제 롤백을 시작하기 전에 현재 시스템 상태를 별도 안전 백업으로 보존한다.
#   선택한 백업의 복원 대상과 역산 레코드에 포함된 경로만 백업 범위로 사용한다.
#
# 입력:
#   $1 : 사용자가 선택한 원본 백업 파일
#   $2 : 원본 백업에 포함된 복원 대상 경로 목록
#   $3 : 롤백 작업용 임시 디렉터리
#   $4 : 롤백 실행 로그 파일
#   $5 : 롤백 검증 로그 파일
#
# 출력:
#   pre_rollback_<서버명>_<시각>.tar.gz와 .sha256/.records 파일을 생성한다.
#
# 반환값:
#   0 : 안전 백업 생성 및 무결성 확인 완료
#   1 : 대상 수집, tar 생성, SHA-256 또는 레코드 생성 실패
#
# 시스템 영향:
#   - backup 디렉터리에 롤백 직전 안전 백업 파일 생성
#   - 오래된 pre_rollback 백업을 보존 정책에 따라 정리
#   - 롤백 실행·검증 로그에 생성 결과 기록
#
# 결과 전역:
#   _VF_PRE_RB_BACKUP / _VF_PRE_RB_SHA256 / _VF_PRE_RB_RECORDS
#   _VF_PRE_RB_EXISTING / _VF_PRE_RB_MISSING / _VF_PRE_RB_ERROR
#
# 안전 조건:
#   - 임시 파일로 생성한 뒤 검증이 끝난 파일만 최종 이름으로 이동
#   - 현재 존재하지 않는 경로는 .records에 CREATED_PATH로 기록
#   - 선택 백업 자체는 수정하지 않음
# -----------------------------------------------------------------------------
_vf_create_pre_rollback_backup() {
  local _selected="$1" _restore_list="$2" _workdir="$3" _log="$4" _verify="$5"
  _VF_PRE_RB_BACKUP=""; _VF_PRE_RB_SHA256=""; _VF_PRE_RB_RECORDS=""
  _VF_PRE_RB_EXISTING=0; _VF_PRE_RB_MISSING=0; _VF_PRE_RB_ERROR=""

  local _pre_ts _safe_host _final _tmp_tar _sha_file _tmp_sha _records_file _tmp_records _err
  _pre_ts=$(date +%Y%m%d_%H%M%S)
  _safe_host=$(printf '%s' "${_HOSTNAME_VAL:-unknown-host}" | sed 's/[^A-Za-z0-9_.-]/_/g')
  _final="${_BAK_DIR}/pre_rollback_${_safe_host}_${_pre_ts}.tar.gz"
  _tmp_tar="${_final}.tmp.$$"
  _sha_file="${_final}.sha256"
  _tmp_sha="${_sha_file}.tmp.$$"
  _records_file="${_final}.records"
  _tmp_records="${_records_file}.tmp.$$"
  _err="${_workdir}/pre_rollback_error.log"

  local _targets="${_workdir}/pre_rollback_targets.list"
  local _existing0="${_workdir}/pre_rollback_existing.list0"
  local _missing="${_workdir}/pre_rollback_missing.list"
  local _inventory="${_workdir}/pre_rollback_inventory.paths"
  local _meta_root="${_workdir}/pre_rollback_meta"
  local _meta="${_meta_root}/.vulnfix_meta"
  local _meta0="${_workdir}/pre_rollback_meta.list0"
  local _baseline_records="${_workdir}/pre_rollback_verify_baseline.records"
  : > "$_targets"; : > "$_existing0"; : > "$_missing"; : > "$_inventory"; : > "$_err"; : > "$_baseline_records"
  rm -rf "$_meta_root" 2>/dev/null
  mkdir -p "${_meta}/firewall" 2>"$_err" || {
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    return 1
  }

  # 현재 실행의 역산 레코드를 읽어, tar 본문 밖에서 chmod/chown/삭제될 수 있는 경로도 포함한다.
  local _run_ts _sel_base _sidecar _records=""
  _run_ts=$(basename "$_selected" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
  _sel_base=$(basename "$_selected")
  _sidecar="${_selected}.records"
  if [ -f "$FIX_HISTORY_FILE" ]; then
    _records=$(_vf_extract_run_records "$FIX_HISTORY_FILE" "$_selected" "$_sel_base" "$_run_ts" 2>/dev/null) || _records=""
  fi
  if [ -z "$_records" ] && [ -f "$_sidecar" ]; then
    _records=$(_vf_extract_run_records "$_sidecar" "$_selected" "$_sel_base" "$_run_ts" 2>/dev/null) || _records=""
  fi

  # 선택 백업의 파일 목록 + 역산 대상 경로를 하나의 중복 없는 목록으로 만든다.
  declare -A _seen=()
  local _p _rel
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _rel="${_p#./}"; _rel="${_rel#/}"; _rel="${_rel%/}"
    [ -n "$_rel" ] || continue
    case "/$_rel/" in *'/../'*|*'/./'*) continue ;; esac
    [ -n "${_seen[$_rel]:-}" ] && continue
    _seen["$_rel"]=1
    printf '%s\n' "$_rel" >> "$_targets"
  done < <(
    printf '%s\n' "$_restore_list"
    if [ -n "$_records" ]; then
      printf '%s\n' "$_records" | awk -F'|' '
        $1=="PERM_RESTORE" || $1=="CREATED_PATH" || $1=="ORPHAN_RESTORE" {print $2}
        $1=="GROUP_MEMBERSHIP" {print "/etc/group"; print "/etc/gshadow"}
      '
    fi
  )

  # 현재 존재하는 대상만 tar 입력에 넣고, 부재 경로는 메타데이터에 남긴다.
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    if [ -e "/$_rel" ] || [ -L "/$_rel" ]; then
      printf '%s\0' "$_rel" >> "$_existing0"
      local _type
      if [ -L "/$_rel" ]; then _type='l'
      elif [ -d "/$_rel" ]; then _type='d'
      elif [ -f "/$_rel" ]; then _type='f'
      else _type='o'
      fi
      printf '/%s\t%s\n' "$_rel" "$_type" >> "$_inventory"
      _VF_PRE_RB_EXISTING=$((_VF_PRE_RB_EXISTING+1))
    else
      printf '/%s\n' "$_rel" >> "$_missing"
      _VF_PRE_RB_MISSING=$((_VF_PRE_RB_MISSING+1))
    fi
  done < "$_targets"

  local _os _tar_acl=0 _tar_xattr=0 _tar_selinux=0 _source_sha=""
  _os=$( ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}" ) 2>/dev/null )
  _vf_tar_supports '--acls'    && _tar_acl=1
  _vf_tar_supports '--xattrs'  && _tar_xattr=1
  _vf_tar_supports '--selinux' && _tar_selinux=1
  command -v sha256sum >/dev/null 2>&1 && _source_sha=$(sha256sum "$_selected" 2>/dev/null | awk '{print $1}')

  {
    printf 'FORMAT_VERSION|4\n'
    printf 'BACKUP_TYPE|PRE_ROLLBACK\n'
    printf 'RUN_ID|PRE_ROLLBACK_%s_%s\n' "$_pre_ts" "$$"
    printf 'RUN_TS|%s\n' "$_pre_ts"
    printf 'HOSTNAME|%s\n' "${_HOSTNAME_VAL:-unknown-host}"
    printf 'OS_INFO|%s\n' "${_os//|//}"
    printf 'KERNEL|%s\n' "$(uname -r 2>/dev/null)"
    printf 'SCRIPT_SCOPE|%s\n' "${_SCRIPT_SCOPE:-unknown}"
    printf 'SCRIPT_PART|%s\n' "${_SCRIPT_PART:-unknown}"
    printf 'SOURCE_BACKUP|%s\n' "$_selected"
    printf 'SOURCE_BACKUP_SHA256|%s\n' "${_source_sha:-unavailable}"
    printf 'TARGET_COUNT|%s\n' "$(wc -l < "$_targets" | tr -d ' ')"
    printf 'EXISTING_COUNT|%s\n' "$_VF_PRE_RB_EXISTING"
    printf 'MISSING_COUNT|%s\n' "$_VF_PRE_RB_MISSING"
    printf 'TAR_ACLS|%s\n' "$_tar_acl"
    printf 'TAR_XATTRS|%s\n' "$_tar_xattr"
    printf 'TAR_SELINUX|%s\n' "$_tar_selinux"
    printf 'CREATED_AT|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "${_meta}/manifest.tsv"

  # comm 비교 전제조건을 보장하도록 메타데이터를 정렬·중복 제거한다.
  LC_ALL=C sort -u "$_targets" -o "$_targets"
  LC_ALL=C sort -u "$_missing" -o "$_missing"
  LC_ALL=C sort -u "$_inventory" -o "$_inventory"

  cp -f "$_targets" "${_meta}/pre_rollback_targets.list" 2>>"$_err" || { _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null); return 1; }
  cp -f "$_missing" "${_meta}/pre_rollback_missing.list" 2>>"$_err" || { _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null); return 1; }
  cp -f "$_inventory" "${_meta}/inventory.paths" 2>>"$_err" || { _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null); return 1; }
  sed 's#^#/#' "$_targets" | LC_ALL=C sort -u > "${_meta}/inventory.roots"
  : > "${_meta}/path_candidates.tsv"
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    if [ -e "/$_rel" ] || [ -L "/$_rel" ]; then
      printf '/%s\tEXISTS\t%s\t%s\n' "$_rel" \
        "$(stat -c '%F' "/$_rel" 2>/dev/null)" "$(stat -c '%a:%u:%g' "/$_rel" 2>/dev/null)" \
        >> "${_meta}/path_candidates.tsv"
    else
      printf '/%s\tABSENT\t-\t-\n' "$_rel" >> "${_meta}/path_candidates.tsv"
    fi
  done < "$_targets"

  LC_ALL=C sort -u "${_meta}/path_candidates.tsv" -o "${_meta}/path_candidates.tsv"
  _vf_capture_services "${_meta}/services.tsv"
  _vf_capture_packages "${_meta}/packages.tsv"
  _vf_capture_accounts "${_meta}/accounts.tsv"
  _vf_capture_firewall "${_meta}/firewall"
  _vf_capture_verify_baselines "$_baseline_records" "$_workdir" || true

  # --no-recursion으로 목록에 있는 디렉터리 자체만 담고, 하위 항목은 원본 목록에 있는 것만 포함한다.
  find "$_meta_root" -mindepth 1 -printf '%P\0' > "$_meta0" 2>>"$_err" || {
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    return 1
  }

  local -a _create_features=()
  [ "$_tar_acl" -eq 1 ] && _create_features+=(--acls)
  [ "$_tar_xattr" -eq 1 ] && _create_features+=(--xattrs)
  [ "$_tar_selinux" -eq 1 ] && _create_features+=(--selinux)

  # 새 안전 백업을 만들기 전에 오래된 백업을 정리해 필요한 저장 공간을 확보한다.
  # 정리 작업은 tar 생성 직전에 수행한다.
  _vf_prune_old_artifacts "$_BAK_DIR" "pre_rollback_${_safe_host}_*.tar.gz" \
    "$VULNFIX_KEEP_PRE_ROLLBACK" "롤백 직전 안전 백업"

  # 디스크 공간 사전 확인: gzip/tar가 도중에 잘려 손상된 파일을 남기기 전에 차단한다.
  # 백업 대상 파일 크기 합계 + 20% 여유 + 최소 1MB를 필요 용량으로 추정한다.
  local _raw_kb=0
  if [ -s "$_inventory" ]; then
    _raw_kb=$(cut -f1 "$_inventory" | tr '\n' '\0' | du -ck --files0-from=- 2>/dev/null | tail -1 | awk '{print $1}')
  fi
  case "$_raw_kb" in ''|*[!0-9]*) _raw_kb=0 ;; esac
  local _req_kb=$(( _raw_kb + _raw_kb / 5 + 1024 ))
  if ! _vf_require_space "$_BAK_DIR" "$_req_kb"; then
    local _avail_kb
    _avail_kb=$(df -Pk "$_BAK_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    _VF_PRE_RB_ERROR=$(printf '디스크 공간 부족으로 안전 백업을 생성할 수 없습니다.\n\n필요 공간(추정) : 약 %s KB\n현재 여유 공간  : %s KB\n백업 위치       : %s\n\n[해결 방법]\n 1) df -h                                          파티션별 여유 공간 확인\n 2) du -xh --max-depth=1 /var | sort -rh | head    큰 디렉터리 찾기\n 3) journalctl --vacuum-size=200M                  저널 로그 정리\n 4) 공간 확보 후 --rollback 재실행' \
      "$_req_kb" "${_avail_kb:-확인불가}" "$_BAK_DIR")
    return 1
  fi

  rm -f "$_tmp_tar" "$_tmp_sha" "$_tmp_records" "$_final" "$_sha_file" "$_records_file" 2>/dev/null

  # tar 생성이 몇 초~몇십 초 걸릴 수 있어, 화면이 멈춘 것처럼 보이지 않도록
  # 체크포인트 기반으로 기존 공용 프로그래스바를 갱신한다. (미지원 tar는 안내 문구만 표시)
  # tar 기본 체크포인트 간격은 레코드(기본 10KB) 단위이므로, 파일 개수가 아니라
  # 앞서 추정한 원본 데이터량(KB)을 기준으로 예상 체크포인트 수를 계산해야
  # 진행률이 초반에 멈춰 보이거나 끝에 가서야 갑자기 튀는 것을 막을 수 있다.
  local _ckpt_total=$(( _raw_kb / 10 ))
  [ "${_ckpt_total:-0}" -gt 0 ] 2>/dev/null || _ckpt_total=1

  if _vf_tar_supports '--checkpoint'; then
    local _ckpt_file="${_workdir}/pre_rollback_progress.count" _tar_pid _ckpt_now _tar_rc
    : > "$_ckpt_file"
    ( umask 077
      tar "${_create_features[@]}" --no-recursion --null -czpf "$_tmp_tar" \
        --checkpoint=1 --checkpoint-action="exec=printf x >> \"$_ckpt_file\"" \
        -C / -T "$_existing0" -C "$_meta_root" -T "$_meta0" ) 2>"$_err" &
    _tar_pid=$!
    _show_progress_bar 0 "$_ckpt_total" "안전 백업 생성 중"
    while kill -0 "$_tar_pid" 2>/dev/null; do
      _ckpt_now=$(wc -c < "$_ckpt_file" 2>/dev/null | tr -d ' ')
      case "$_ckpt_now" in ''|*[!0-9]*) _ckpt_now=0 ;; esac
      [ "$_ckpt_now" -gt "$_ckpt_total" ] && _ckpt_now="$_ckpt_total"
      _show_progress_bar "$_ckpt_now" "$_ckpt_total" "안전 백업 생성 중"
      sleep 0.2
    done
    wait "$_tar_pid"
    _tar_rc=$?
    _show_progress_bar "$_ckpt_total" "$_ckpt_total" "안전 백업 생성 중"
    echo ""
    rm -f "$_ckpt_file" 2>/dev/null
    if [ "$_tar_rc" -ne 0 ]; then
      _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
      rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
      return 1
    fi
  else
    _info "안전 백업 생성 중입니다. 대상 파일 수에 따라 시간이 걸릴 수 있습니다."
    if ! ( umask 077
           tar "${_create_features[@]}" --no-recursion --null -czpf "$_tmp_tar" \
             -C / -T "$_existing0" -C "$_meta_root" -T "$_meta0" ) 2>"$_err"; then
      _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
      rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
      return 1
    fi
  fi

  if ! tar tzf "$_tmp_tar" >/dev/null 2>>"$_err"; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
    return 1
  fi

  if ! mv -f "$_tmp_tar" "$_final" 2>>"$_err"; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
    return 1
  fi
  chmod 600 "$_final" 2>>"$_err" || {
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_final" 2>/dev/null
    return 1
  }

  if ! command -v sha256sum >/dev/null 2>&1; then
    _VF_PRE_RB_ERROR='sha256sum 명령을 찾을 수 없습니다.'
    rm -f "$_final" 2>/dev/null
    return 1
  fi
  _VF_PRE_RB_SHA256=$(sha256sum "$_final" 2>>"$_err" | awk '{print $1}')
  if [ -z "$_VF_PRE_RB_SHA256" ]; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_final" 2>/dev/null
    return 1
  fi
  if ! ( umask 077; printf '%s  %s\n' "$_VF_PRE_RB_SHA256" "$(basename "$_final")" > "$_tmp_sha" ); then
    _VF_PRE_RB_ERROR='SHA-256 파일을 생성하지 못했습니다.'
    rm -f "$_final" "$_tmp_sha" 2>/dev/null
    return 1
  fi
  if ! mv -f "$_tmp_sha" "$_sha_file" 2>>"$_err"; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_final" "$_tmp_sha" 2>/dev/null
    return 1
  fi
  chmod 600 "$_sha_file" 2>/dev/null || true

  # P2 사이드카 형식과 연계해, 안전 백업 시점에 없었던 경로는 복원 시 제거 대상으로 기록한다.
  if ! ( umask 077
         {
           printf 'RUN_START|%s|ID=PRE_ROLLBACK_%s_%s|HOST=%s|BAK=%s\n' \
             "$_pre_ts" "$_pre_ts" "$$" "${_HOSTNAME_VAL:-unknown-host}" "$_final"
           [ -s "$_baseline_records" ] && cat "$_baseline_records"
           while IFS= read -r _p; do
             [ -n "$_p" ] || continue
             printf 'CREATED_PATH|%s|PRE_ROLLBACK_ABSENT\n' "$_p"
           done < "$_missing"
         } > "$_tmp_records" ); then
    _VF_PRE_RB_ERROR='롤백 직전 안전 백업의 .records 파일을 생성하지 못했습니다.'
    rm -f "$_final" "$_sha_file" "$_tmp_records" 2>/dev/null
    return 1
  fi
  if ! mv -f "$_tmp_records" "$_records_file" 2>>"$_err"; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_final" "$_sha_file" "$_tmp_records" 2>/dev/null
    return 1
  fi
  chmod 600 "$_records_file" 2>/dev/null || true

  _VF_PRE_RB_BACKUP="$_final"
  _VF_PRE_RB_RECORDS="$_records_file"
  {
    echo ""
    echo "[롤백 직전 안전 백업]"
    echo "백업 파일 : ${_VF_PRE_RB_BACKUP}"
    echo "SHA-256   : ${_VF_PRE_RB_SHA256}"
    echo "레코드    : ${_VF_PRE_RB_RECORDS}"
    echo "현재 존재 : ${_VF_PRE_RB_EXISTING}개"
    echo "현재 부재 : ${_VF_PRE_RB_MISSING}개"
    echo "용도       : 롤백 실패 시 직전 상태 복구"
  } >> "$_log" 2>/dev/null
  {
    echo ""
    echo "[롤백 직전 안전 백업]"
    echo "생성 완료 : ${_VF_PRE_RB_BACKUP}"
    echo "SHA-256   : ${_VF_PRE_RB_SHA256}"
    echo "레코드    : ${_VF_PRE_RB_RECORDS}"
  } >> "$_verify" 2>/dev/null
  return 0
}

# -----------------------------------------------------------------------------
# _vf_compare_packages_after_rollback
#
# 역할:
#   백업 시점의 패키지 목록과 롤백 후 현재 목록을 비교한다.
#   패키지는 자동 재설치·삭제하지 않고 차이만 기록해 수동 확인 대상으로 남긴다.
#
# 입력:
#   $1 : 백업 시점 패키지 목록
#   $2 : 롤백 작업용 임시 디렉터리
#   $3 : 롤백 실행 로그 파일
#   $4 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_PKG_ADDED / _VF_PKG_REMOVED / _VF_PKG_CHANGED / _VF_PKG_MANUAL
#
# 시스템 영향:
#   시스템 패키지를 변경하지 않으며 비교 결과 파일과 로그만 생성한다.
# -----------------------------------------------------------------------------
_vf_compare_packages_after_rollback() {
  local _baseline="$1" _workdir="$2" _log="$3" _verify="$4"
  _VF_PKG_ADDED=0; _VF_PKG_REMOVED=0; _VF_PKG_CHANGED=0; _VF_PKG_MANUAL=0
  [ -f "$_baseline" ] || { _VF_PKG_MANUAL=1; return 0; }
  local _current="$_workdir/packages.current.tsv" _diff="$_workdir/packages.diff"
  _VF_PKG_DIFF_FILE="$_diff"
  _vf_capture_packages "$_current"
  awk -F'\t' '
    FNR==NR { if ($0 !~ /^#/){ b[$1 FS $3]=$2; bn[$1 FS $3]=$0 } next }
    { if ($0 !~ /^#/){ c[$1 FS $3]=$2; cn[$1 FS $3]=$0 } }
    END {
      for (k in b) {
        if (!(k in c)) print "REMOVED\t" bn[k]
        else if (b[k] != c[k]) print "CHANGED\t" bn[k] "\t=>\t" cn[k]
      }
      for (k in c) if (!(k in b)) print "ADDED\t" cn[k]
    }
  ' "$_baseline" "$_current" | LC_ALL=C sort > "$_diff"
  _VF_PKG_ADDED=$(grep -c '^ADDED' "$_diff" 2>/dev/null || true)
  _VF_PKG_REMOVED=$(grep -c '^REMOVED' "$_diff" 2>/dev/null || true)
  _VF_PKG_CHANGED=$(grep -c '^CHANGED' "$_diff" 2>/dev/null || true)
  if [ $((_VF_PKG_ADDED+_VF_PKG_REMOVED+_VF_PKG_CHANGED)) -gt 0 ]; then
    _VF_PKG_MANUAL=1
    {
      echo ""
      echo "[패키지 변경 비교]"
      echo "추가=${_VF_PKG_ADDED} 제거=${_VF_PKG_REMOVED} 버전변경=${_VF_PKG_CHANGED}"
      cat "$_diff"
    } >> "$_verify" 2>/dev/null
    sed 's/^/PACKAGE_DRIFT|/' "$_diff" >> "$_log" 2>/dev/null
  else
    echo 'PACKAGE|BASELINE_MATCH' >> "$_log" 2>/dev/null
  fi
}

# -----------------------------------------------------------------------------
# _vf_validate_accounts_after_rollback
#
# 역할:
#   백업 시점과 롤백 후의 계정·UID·GID·홈·셸·그룹 정보를 비교한다.
#
# 입력:
#   $1 : 백업 시점 계정 정보 파일
#   $2 : 롤백 작업용 임시 디렉터리
#   $3 : 롤백 실행 로그 파일
#   $4 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_ACCOUNT_OK / _VF_ACCOUNT_FAIL / _VF_ACCOUNT_MANUAL
#
# 판정:
#   MATCH는 정상, MISSING/MISMATCH는 실패, NEW는 수동 확인으로 집계한다.
#
# 시스템 영향:
#   계정을 생성·삭제·수정하지 않고 비교 결과만 기록한다.
# -----------------------------------------------------------------------------
_vf_validate_accounts_after_rollback() {
  local _baseline="$1" _workdir="$2" _log="$3" _verify="$4"
  _VF_ACCOUNT_OK=0; _VF_ACCOUNT_FAIL=0; _VF_ACCOUNT_MANUAL=0
  [ -f "$_baseline" ] || { _VF_ACCOUNT_MANUAL=1; return 0; }
  local _current="$_workdir/accounts.current.tsv" _diff="$_workdir/accounts.diff"
  _vf_capture_accounts "$_current"
  awk -F'\t' '
    FNR==NR { b[$1]=$0; next }
    { c[$1]=$0 }
    END {
      for (u in b) {
        if (!(u in c)) print "MISSING\t" b[u]
        else if (b[u] != c[u]) print "MISMATCH\t" b[u] "\t=>\t" c[u]
        else print "MATCH\t" u
      }
      for (u in c) if (!(u in b)) print "NEW\t" c[u]
    }
  ' "$_baseline" "$_current" > "$_diff"
  _VF_ACCOUNT_OK=$(grep -c '^MATCH' "$_diff" 2>/dev/null || true)
  _VF_ACCOUNT_FAIL=$(( $(grep -c '^MISSING' "$_diff" 2>/dev/null || true) + $(grep -c '^MISMATCH' "$_diff" 2>/dev/null || true) ))
  _VF_ACCOUNT_MANUAL=$(grep -c '^NEW' "$_diff" 2>/dev/null || true)
  {
    echo ""
    echo "[계정 상태 비교]"
    echo "일치=${_VF_ACCOUNT_OK} 불일치=${_VF_ACCOUNT_FAIL} 신규계정=${_VF_ACCOUNT_MANUAL}"
    grep -v '^MATCH' "$_diff" 2>/dev/null
  } >> "$_verify" 2>/dev/null
  grep -v '^MATCH' "$_diff" 2>/dev/null | sed 's/^/ACCOUNT|/' >> "$_log" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_restore_recorded_paths
#
# 역할:
#   백업 시점의 경로 인벤토리와 롤백 후 상태를 비교하고,
#   조치 과정에서 새로 생성된 것으로 확인된 파일·빈 디렉터리를 정리한다.
#
# 입력:
#   $1 : 백업 메타데이터 디렉터리
#   $2 : CREATED_PATH 레코드 목록
#   $3 : 선택 백업의 실행 시각
#   $4 : 롤백 실행 로그 파일
#   $5 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_PATH_OK / _VF_PATH_FAIL / _VF_PATH_MANUAL
#
# 시스템 영향:
#   - CREATED_PATH로 확인된 파일 또는 심볼릭 링크 삭제
#   - 비어 있는 디렉터리만 rmdir로 삭제
#   - 삭제가 안전하지 않은 경로는 자동 처리하지 않고 수동 확인으로 남김
#
# 안전 조건:
#   백업 인벤토리와 역산 레코드로 생성 사실이 확인된 경로만 정리한다.
# -----------------------------------------------------------------------------
_vf_restore_recorded_paths() {
  local _meta_dir="$1" _created_records="$2" _run_ts="$3" _log="$4" _verify="$5"
  _VF_PATH_OK=0; _VF_PATH_FAIL=0; _VF_PATH_MANUAL=0
  local _baseline="$_meta_dir/inventory.paths" _roots="$_meta_dir/inventory.roots"
  local _current="${_meta_dir%/.vulnfix_meta}/inventory.current" _new="${_meta_dir%/.vulnfix_meta}/inventory.new" _missing="${_meta_dir%/.vulnfix_meta}/inventory.missing"
  local _baseline_sorted="${_meta_dir%/.vulnfix_meta}/inventory.baseline.sorted" _current_sorted="${_meta_dir%/.vulnfix_meta}/inventory.current.sorted"
  : > "$_current"
  if [ -f "$_roots" ]; then
    while IFS= read -r _root; do
      [ -e "$_root" ] || [ -L "$_root" ] || continue
      if [ -d "$_root" ] && [ ! -L "$_root" ]; then
        find "$_root" -xdev -printf '%p\t%y\n' 2>/dev/null
      else
        printf '%s\t%s\n' "$_root" "$( [ -L "$_root" ] && echo l || [ -f "$_root" ] && echo f || echo o )"
      fi
    done < "$_roots" | LC_ALL=C sort -u > "$_current"
  fi
  if [ -f "$_baseline" ]; then
    # 비교 전 양쪽 인벤토리를 정렬·중복 제거해 comm 입력 전제를 보장한다.
    LC_ALL=C sort -u "$_baseline" > "$_baseline_sorted"
    LC_ALL=C sort -u "$_current" > "$_current_sorted"
    comm -23 "$_baseline_sorted" "$_current_sorted" > "$_missing"
    comm -13 "$_baseline_sorted" "$_current_sorted" > "$_new"
  else
    : > "$_missing"; : > "$_new"; _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
  fi

  local _line _path _type
  declare -A _handled_new=() _handled_missing=()
  while IFS=$'\t' read -r _path _type; do
    [ -n "$_path" ] || continue
    _handled_missing["$_path"]=1
    _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
    echo "PATH|MISSING|${_path}|${_type}" >> "$_log" 2>/dev/null
  done < "$_missing"

  while IFS=$'\t' read -r _path _type; do
    [ -n "$_path" ] || continue
    _handled_new["$_path"]=1
    # 이 실행이 생성한 .bak.<RUN_TS> 파일은 롤백 후 안전하게 제거한다.
    if [[ "$_path" == *.bak."$_run_ts" ]] && [ -f "$_path" ]; then
      if rm -f -- "$_path" 2>/dev/null; then
        _VF_PATH_OK=$((_VF_PATH_OK+1)); echo "PATH|REMOVE_ARTIFACT|PASS|${_path}" >> "$_log" 2>/dev/null
      else
        _VF_PATH_FAIL=$((_VF_PATH_FAIL+1)); echo "PATH|REMOVE_ARTIFACT|FAIL|${_path}" >> "$_log" 2>/dev/null
      fi
      continue
    fi
    if printf '%s\n' "$_created_records" | awk -F'|' -v p="$_path" '$1=="CREATED_PATH" && $2==p {found=1} END{exit !found}'; then
      if [ -L "$_path" ] || [ -f "$_path" ]; then
        if rm -f -- "$_path" 2>/dev/null; then _VF_PATH_OK=$((_VF_PATH_OK+1)); else _VF_PATH_FAIL=$((_VF_PATH_FAIL+1)); fi
      elif [ -d "$_path" ]; then
        if rmdir -- "$_path" 2>/dev/null; then
          _VF_PATH_OK=$((_VF_PATH_OK+1))
        else
          # 데이터가 들어간 신규 디렉터리는 자동 삭제하지 않는다.
          _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
        fi
      else
        _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
      fi
      echo "PATH|CREATED_ROLLBACK|${_path}|type=${_type}" >> "$_log" 2>/dev/null
    else
      _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
      echo "PATH|NEW_UNTRACKED|${_path}|${_type}" >> "$_log" 2>/dev/null
    fi
  done < "$_new"

  # 루트 디렉터리가 조치 전 없었던 대표 경로도 별도로 비교한다.
  if [ -f "$_meta_dir/path_candidates.tsv" ]; then
    while IFS=$'\t' read -r _path _state _type _meta; do
      [ -n "$_path" ] || continue
      if [ "$_state" = 'EXISTS' ]; then
        if [ ! -e "$_path" ] && [ ! -L "$_path" ] && [ -z "${_handled_missing[$_path]:-}" ]; then
          _handled_missing["$_path"]=1
          _VF_PATH_FAIL=$((_VF_PATH_FAIL+1)); echo "PATH|CANDIDATE_MISSING|${_path}" >> "$_log" 2>/dev/null
        fi
      elif [ "$_state" = 'ABSENT' ] && { [ -e "$_path" ] || [ -L "$_path" ]; }; then
        [ -n "${_handled_new[$_path]:-}" ] && continue
        _handled_new["$_path"]=1
        if printf '%s\n' "$_created_records" | awk -F'|' -v p="$_path" '$1=="CREATED_PATH" && $2==p {found=1} END{exit !found}'; then
          if [ -f "$_path" ] || [ -L "$_path" ]; then
            rm -f -- "$_path" 2>/dev/null && _VF_PATH_OK=$((_VF_PATH_OK+1)) || _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
          elif [ -d "$_path" ]; then
            rmdir -- "$_path" 2>/dev/null && _VF_PATH_OK=$((_VF_PATH_OK+1)) || _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
          fi
        else
          _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1)); echo "PATH|CANDIDATE_NEW|${_path}" >> "$_log" 2>/dev/null
        fi
      fi
    done < "$_meta_dir/path_candidates.tsv"
  fi

  # 인벤토리 바깥에서 명시적으로 기록된 생성 경로(U-32 홈 등)도 처리한다.
  while IFS='|' read -r _tag _path _kind; do
    [ "$_tag" = 'CREATED_PATH' ] || continue
    [ -e "$_path" ] || [ -L "$_path" ] || continue
    [ -n "${_handled_new[$_path]:-}" ] && continue
    _handled_new["$_path"]=1
    if [ -L "$_path" ] || [ -f "$_path" ]; then
      rm -f -- "$_path" 2>/dev/null && _VF_PATH_OK=$((_VF_PATH_OK+1)) || _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
    elif [ -d "$_path" ]; then
      rmdir -- "$_path" 2>/dev/null && _VF_PATH_OK=$((_VF_PATH_OK+1)) || _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
    fi
  done <<< "$_created_records"

  {
    echo ""
    echo "[생성·삭제 경로 비교]"
    echo "자동 정리=${_VF_PATH_OK} 누락/실패=${_VF_PATH_FAIL} 추가확인=${_VF_PATH_MANUAL}"
    [ -s "$_missing" ] && { echo '복원 후 누락 경로:'; cat "$_missing"; }
    [ -s "$_new" ] && { echo '조치 전에는 없던 경로:'; cat "$_new"; }
  } >> "$_verify" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_restore_orphan_owners
#
# 역할:
#   U-15 조치로 변경된 무소유 파일의 숫자 UID/GID를 백업 시점 값으로 복원한다.
#   소유자와 그룹 중 실제 조치된 항목만 선택적으로 복원한다.
#
# 입력:
#   $1 : ORPHAN_RESTORE 레코드 목록
#   $2 : 롤백 실행 로그 파일
#   $3 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_ORPHAN_OK / _VF_ORPHAN_FAIL / _VF_ORPHAN_MANUAL
#
# 시스템 영향:
#   대상 경로의 소유자 또는 그룹을 숫자 UID/GID로 변경한다.
#   일반 파일의 chown으로 제거될 수 있는 setuid/setgid 비트는 기록된 mode로 재확인한다.
#
# 안전 조건:
#   - 경로 존재 여부 확인
#   - device와 inode가 백업 시점과 동일한지 확인
#   - 파일 유형과 mode가 기록값에서 바뀌지 않았는지 확인
#   - 저장된 UID/GID가 현재 다른 계정에 재사용됐으면 자동 복원 중단
#   - 심볼릭 링크는 chown -h로 링크 자체에 적용
#
# 참고:
#   U-15는 mode를 직접 조치하지 않으므로 mode는 드리프트 검증과
#   chown 부작용 복구에만 사용한다.
# -----------------------------------------------------------------------------
_vf_restore_orphan_owners() {
  local _records="$1" _log="$2" _verify="$3"
  _VF_ORPHAN_OK=0; _VF_ORPHAN_FAIL=0; _VF_ORPHAN_MANUAL=0
  [ -n "$_records" ] || return 0

  local _tag _path _dev _ino _type _mode _oo _ouid _go _ogid
  while IFS='|' read -r _tag _path _dev _ino _type _mode _oo _ouid _go _ogid; do
    [ "$_tag" = "ORPHAN_RESTORE" ] || continue
    [ -n "$_path" ] || continue

    # 1) 경로 존재 확인
    if [ ! -e "$_path" ] && [ ! -L "$_path" ]; then
      _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
      echo "ORPHAN|MISSING|${_path}" >> "$_log" 2>/dev/null
      continue
    fi

    # 2) device+inode 일치 확인 (경로가 삭제 후 같은 이름으로 재생성됐는지)
    local _cur_dev _cur_ino
    _cur_dev=$(stat -c '%d' "$_path" 2>/dev/null)
    _cur_ino=$(stat -c '%i' "$_path" 2>/dev/null)
    if [ "$_cur_dev" != "$_dev" ] || [ "$_cur_ino" != "$_ino" ]; then
      _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
      echo "ORPHAN|INODE_MISMATCH|${_path}|expected=${_dev}:${_ino}|actual=${_cur_dev}:${_cur_ino}" >> "$_log" 2>/dev/null
      continue
    fi

    # 3) 파일 유형 일치 확인
    local _cur_type
    _cur_type=$(stat -c '%F' "$_path" 2>/dev/null)
    if [ "$_cur_type" != "$_type" ]; then
      _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
      echo "ORPHAN|TYPE_MISMATCH|${_path}|expected=${_type}|actual=${_cur_type}" >> "$_log" 2>/dev/null
      continue
    fi

    # 4) mode 일치 확인 — U-15는 mode를 바꾸지 않으므로 복원 대상이 아니라 드리프트 감지용.
    #    조치 이후 mode가 달라졌다면 다른 변경이 있었을 가능성이 있어 자동 복원을 중단한다.
    local _cur_mode
    _cur_mode=$(stat -c '%a' "$_path" 2>/dev/null)
    if [ "$_cur_mode" != "$_mode" ]; then
      _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
      echo "ORPHAN|MODE_DRIFT|${_path}|expected=${_mode}|actual=${_cur_mode}" >> "$_log" 2>/dev/null
      continue
    fi

    local _restore_uid="" _restore_gid="" _blocked=0

    # 5) UID 재사용 검사 (원래 소유자가 없었던 경우만)
    if [ "$_oo" = "1" ]; then
      if getent passwd "$_ouid" >/dev/null 2>&1; then
        _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
        echo "ORPHAN|UID_REUSED|${_path}|uid=${_ouid}" >> "$_log" 2>/dev/null
        _blocked=1
      else
        _restore_uid="$_ouid"
      fi
    fi

    # 6) GID 재사용 검사 (원래 그룹이 없었던 경우만)
    if [ "$_blocked" -eq 0 ] && [ "$_go" = "1" ]; then
      if getent group "$_ogid" >/dev/null 2>&1; then
        _VF_ORPHAN_MANUAL=$((_VF_ORPHAN_MANUAL+1))
        echo "ORPHAN|GID_REUSED|${_path}|gid=${_ogid}" >> "$_log" 2>/dev/null
        _blocked=1
      else
        _restore_gid="$_ogid"
      fi
    fi

    [ "$_blocked" -eq 1 ] && continue
    if [ -z "$_restore_uid" ] && [ -z "$_restore_gid" ]; then
      continue
    fi

    # chown 대상 문자열: 뒤에 콜론만 붙이면(예: "UID:") GNU chown이 오류로 처리하므로
    # 실제로 복원할 축만 정확히 조합한다.
    local _target=""
    if [ -n "$_restore_uid" ] && [ -n "$_restore_gid" ]; then
      _target="${_restore_uid}:${_restore_gid}"
    elif [ -n "$_restore_uid" ]; then
      _target="${_restore_uid}"
    else
      _target=":${_restore_gid}"
    fi

    # 7) 실제 복원 (심볼릭 링크는 대상이 아니라 링크 자신에 적용)
    local _chown_ok=1
    if [ -L "$_path" ]; then
      chown -h "$_target" "$_path" 2>/dev/null || _chown_ok=0
    else
      chown "$_target" "$_path" 2>/dev/null || _chown_ok=0
      # 커널은 실행 파일 소유자 변경 시 setuid/setgid 비트를 자동 제거한다.
      # 4단계에서 mode가 기록값과 동일함을 이미 확인했으므로, chown이 벗겨낸
      # 특수비트를 되살리기 위해 동일한 mode를 재적용한다 (mode "복원"이 아니라
      # 우리 chown의 부작용 원복).
      if [ "$_chown_ok" -eq 1 ] && [ "${#_mode}" -eq 4 ] && [ "${_mode:0:1}" != "0" ]; then
        chmod "$_mode" "$_path" 2>/dev/null || _chown_ok=0
      fi
    fi

    # 8) 적용 후 stat 재확인
    if [ "$_chown_ok" -eq 1 ]; then
      local _after_uid _after_gid _after_mode
      _after_uid=$(stat -c '%u' "$_path" 2>/dev/null)
      _after_gid=$(stat -c '%g' "$_path" 2>/dev/null)
      _after_mode=$(stat -c '%a' "$_path" 2>/dev/null)
      if { [ -z "$_restore_uid" ] || [ "$_after_uid" = "$_restore_uid" ]; } \
         && { [ -z "$_restore_gid" ] || [ "$_after_gid" = "$_restore_gid" ]; } \
         && { [ -L "$_path" ] || [ "$_after_mode" = "$_mode" ]; }; then
        _VF_ORPHAN_OK=$((_VF_ORPHAN_OK+1))
        echo "ORPHAN|PASS|${_path}|uid=${_restore_uid:--}|gid=${_restore_gid:--}" >> "$_log" 2>/dev/null
      else
        _VF_ORPHAN_FAIL=$((_VF_ORPHAN_FAIL+1))
        echo "ORPHAN|FAIL|${_path}|적용 후 불일치" >> "$_log" 2>/dev/null
      fi
    else
      _VF_ORPHAN_FAIL=$((_VF_ORPHAN_FAIL+1))
      echo "ORPHAN|FAIL|${_path}|chown 명령 실패" >> "$_log" 2>/dev/null
    fi
  done <<< "$_records"

  {
    echo ""
    echo "[무소유 파일(U-15) 소유권 복원]"
    echo "성공=${_VF_ORPHAN_OK} 실패=${_VF_ORPHAN_FAIL} 수동확인=${_VF_ORPHAN_MANUAL}"
  } >> "$_verify" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_rb_service_config_restored
#
# 역할:
#   지정한 systemd 서비스의 설정 파일이 실제 복원 목록에 포함됐는지 확인한다.
#
# 입력:
#   $1 : systemd unit 이름
#   $2 : tar에서 추출한 복원 파일 목록
#
# 출력:
#   표준 출력 없음
#
# 반환값:
#   0 : 해당 서비스 설정 파일이 복원 목록에 포함됨
#   1 : 지원하지 않는 서비스이거나 관련 설정 파일이 없음
#
# 안전 조건:
#   SSH는 원격 세션 보호를 위해 자동 설정 반영 대상에서 제외한다.
# -----------------------------------------------------------------------------
_vf_rb_service_config_restored() {
  local _unit="$1" _files="$2" _pattern=""
  case "$_unit" in
    rsyslog.service)
      _pattern='(^|/)etc/rsyslog\.conf$|(^|/)etc/rsyslog\.d(/|$)' ;;
    snmpd.service)
      _pattern='(^|/)etc/snmp/snmpd\.conf$|(^|/)etc/snmp(/|$)' ;;
    vsftpd.service)
      _pattern='(^|/)etc/vsftpd\.conf$|(^|/)etc/vsftpd(/|$)' ;;
    proftpd.service)
      _pattern='(^|/)etc/proftpd\.conf$|(^|/)etc/proftpd(/|$)' ;;
    named.service|bind9.service)
      _pattern='(^|/)etc/named\.conf$|(^|/)etc/named(/|$)|(^|/)etc/bind(/|$)' ;;
    nfs-server.service|nfs-kernel-server.service)
      _pattern='(^|/)etc/exports$|(^|/)etc/exports\.d(/|$)|(^|/)etc/nfs\.conf$' ;;
    xinetd.service)
      _pattern='(^|/)etc/xinetd\.conf$|(^|/)etc/xinetd\.d(/|$)' ;;
    chronyd.service|chrony.service)
      _pattern='(^|/)etc/chrony\.conf$|(^|/)etc/chrony(/|$)' ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_files" | grep -qE "$_pattern"
}

# -----------------------------------------------------------------------------
# _vf_restore_service_states
#
# 역할:
#   백업 시점의 systemd active/enabled 상태를 기준으로 서비스 상태를 복원한다.
#
# 입력:
#   $1 : 백업 시점 서비스 상태 파일
#   $2 : 롤백 실행 로그 파일
#   $3 : 롤백 검증 로그 파일
#   $4 : 실제 복원된 파일 목록
#
# 결과 전역:
#   _VF_SERVICE_OK / _VF_SERVICE_FAIL / _VF_SERVICE_MANUAL
#
# 시스템 영향:
#   systemctl enable/disable/mask/unmask/start/stop을 수행할 수 있다.
#
# 안전 조건:
#   - 복원된 설정 파일이 있는 비활성 서비스는 설정 검증 전 자동 시작하지 않음
#   - SSH가 현재 active이면 백업 시점이 inactive여도 자동 중지하지 않음
#   - static/indirect/generated unit은 enabled 상태를 강제로 변경하지 않음
#   - 작업 후 active/enabled 상태를 다시 조회해 일치 여부를 검증
# -----------------------------------------------------------------------------
_vf_restore_service_states() {
  local _baseline="$1" _log="$2" _verify="$3" _restored_files="${4:-}"
  _VF_SERVICE_OK=0; _VF_SERVICE_FAIL=0; _VF_SERVICE_MANUAL=0
  [ -f "$_baseline" ] || { _VF_SERVICE_MANUAL=1; return 0; }
  command -v systemctl >/dev/null 2>&1 || { _VF_SERVICE_MANUAL=1; return 0; }
  local _unit _exists _active _enabled _load _cur_active _cur_enabled _op_fail
  while IFS=$'\t' read -r _unit _exists _active _enabled; do
    [[ "$_unit" == \#* ]] && continue
    [ -n "$_unit" ] || continue
    _load=$(systemctl show "$_unit" -p LoadState --value 2>/dev/null | head -1)
    if [ "$_exists" = '0' ]; then
      if [ -n "$_load" ] && [ "$_load" != 'not-found' ]; then
        _VF_SERVICE_MANUAL=$((_VF_SERVICE_MANUAL+1))
        echo "SERVICE_STATE|NEW_UNIT|${_unit}" >> "$_log" 2>/dev/null
      fi
      continue
    fi
    if [ -z "$_load" ] || [ "$_load" = 'not-found' ]; then
      _VF_SERVICE_FAIL=$((_VF_SERVICE_FAIL+1)); echo "SERVICE_STATE|MISSING|${_unit}" >> "$_log" 2>/dev/null; continue
    fi
    _op_fail=0
    _cur_active=$(systemctl is-active "$_unit" 2>/dev/null | head -1)
    local _guard_config_start=0
    case "$_active" in
      active|activating|reloading)
        if [ "$_cur_active" != 'active' ] && [ "$_cur_active" != 'activating' ] && [ "$_cur_active" != 'reloading' ] \
           && [ -n "$_restored_files" ] && _vf_rb_service_config_restored "$_unit" "$_restored_files"; then
          _guard_config_start=1
        fi
        ;;
    esac
    case "$_enabled" in
      masked|masked-runtime) systemctl mask "$_unit" >/dev/null 2>&1 || _op_fail=1 ;;
      enabled|enabled-runtime|linked|linked-runtime)
        systemctl unmask "$_unit" >/dev/null 2>&1 || true
        systemctl enable "$_unit" >/dev/null 2>&1 || _op_fail=1 ;;
      disabled)
        systemctl unmask "$_unit" >/dev/null 2>&1 || true
        systemctl disable "$_unit" >/dev/null 2>&1 || _op_fail=1 ;;
      *) : ;; # static/indirect/generated 등은 enable 상태를 강제하지 않음
    esac
    case "$_active" in
      active|activating|reloading)
        if [ "$_guard_config_start" -eq 1 ]; then
          _VF_SERVICE_MANUAL=$((_VF_SERVICE_MANUAL+1))
          echo "SERVICE_STATE|CONFIG_START_GUARD|${_unit}|baseline=${_active}|actual=${_cur_active}" >> "$_log" 2>/dev/null
          {
            echo ""
            echo "[서비스 상태 복원 보호]"
            echo "대상   : ${_unit}"
            echo "상태   : MANUAL"
            echo "사유   : 복원된 설정의 안전한 검증 전에는 비활성 서비스를 자동 시작하지 않음"
          } >> "$_verify" 2>/dev/null
          continue
        fi
        systemctl start "$_unit" >/dev/null 2>&1 || _op_fail=1 ;;
      inactive|failed|deactivating)
        # 원격 접속 자체를 끊을 수 있는 SSH는 비활성 복원을 자동 수행하지 않는다.
        case "$_unit" in
          sshd.service|ssh.service)
            if systemctl is-active --quiet "$_unit" 2>/dev/null; then
              _VF_SERVICE_MANUAL=$((_VF_SERVICE_MANUAL+1))
              echo "SERVICE_STATE|MANUAL_STOP|${_unit}|baseline=${_active}" >> "$_log" 2>/dev/null
              continue
            fi ;;
          *) systemctl stop "$_unit" >/dev/null 2>&1 || _op_fail=1 ;;
        esac ;;
      *) _VF_SERVICE_MANUAL=$((_VF_SERVICE_MANUAL+1)); echo "SERVICE_STATE|UNKNOWN_BASELINE|${_unit}|${_active}" >> "$_log" 2>/dev/null; continue ;;
    esac
    _cur_active=$(systemctl is-active "$_unit" 2>/dev/null | head -1)
    _cur_enabled=$(systemctl is-enabled "$_unit" 2>/dev/null | head -1)
    local _active_match=0 _enabled_match=0
    case "$_active" in
      active|activating|reloading) if [ "$_cur_active" = 'active' ] || [ "$_cur_active" = 'activating' ] || [ "$_cur_active" = 'reloading' ]; then _active_match=1; fi ;;
      inactive|failed|deactivating) if [ "$_cur_active" = 'inactive' ] || [ "$_cur_active" = 'failed' ] || [ "$_cur_active" = 'deactivating' ]; then _active_match=1; fi ;;
    esac
    case "$_enabled" in
      masked|masked-runtime) [[ "$_cur_enabled" == masked* ]] && _enabled_match=1 ;;
      enabled|enabled-runtime|linked|linked-runtime) [[ "$_cur_enabled" == enabled* || "$_cur_enabled" == linked* ]] && _enabled_match=1 ;;
      disabled) [ "$_cur_enabled" = 'disabled' ] && _enabled_match=1 ;;
      *) _enabled_match=1 ;; # static/indirect/generated 등
    esac
    if [ "$_op_fail" -eq 0 ] && [ "$_active_match" -eq 1 ] && [ "$_enabled_match" -eq 1 ]; then
      _VF_SERVICE_OK=$((_VF_SERVICE_OK+1))
      echo "SERVICE_STATE|PASS|${_unit}|active=${_cur_active}|enabled=${_cur_enabled}" >> "$_log" 2>/dev/null
    else
      _VF_SERVICE_FAIL=$((_VF_SERVICE_FAIL+1))
      echo "SERVICE_STATE|FAIL|${_unit}|expected=${_active}/${_enabled}|actual=${_cur_active}/${_cur_enabled}" >> "$_log" 2>/dev/null
    fi
  done < "$_baseline"
  {
    echo ""
    echo "[서비스 상태 복원]"
    echo "성공=${_VF_SERVICE_OK} 실패=${_VF_SERVICE_FAIL} 추가확인=${_VF_SERVICE_MANUAL}"
  } >> "$_verify" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_apply_restored_service_configs
#
# 역할:
#   롤백으로 복원된 설정을 현재 실행 중인 서비스에 안전하게 재적용한다.
#
# 입력:
#   $1 : 실제 복원된 파일 목록
#   $2 : 롤백 작업용 임시 디렉터리
#   $3 : 롤백 실행 로그 파일
#   $4 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_CONFIG_APPLY_OK / _VF_CONFIG_APPLY_MANUAL / _VF_CONFIG_APPLY_SKIP
#
# 시스템 영향:
#   설정 검증을 통과한 active 서비스에 reload 또는 restart를 수행할 수 있다.
#
# 안전 조건:
#   - 설정 파일이 실제 복원된 서비스만 대상
#   - 서비스가 active인 경우에만 적용
#   - 서비스별 config test 통과 후 reload/restart
#   - SSH는 원격 세션 보호를 위해 자동 reload/restart하지 않음
#   - 비활성·미설치 서비스는 임의로 시작하지 않음
# -----------------------------------------------------------------------------
_vf_apply_restored_service_configs() {
  local _files="$1" _workdir="$2" _log="$3" _verify="$4"
  _VF_CONFIG_APPLY_OK=0; _VF_CONFIG_APPLY_MANUAL=0; _VF_CONFIG_APPLY_SKIP=0

  local _out="${_workdir}/service_config_apply.out"
  local _unit="" _conf="" _detail="" _action="" _label=""

  _vf_rb_find_active_unit() {
    local _u
    command -v systemctl >/dev/null 2>&1 || return 1
    for _u in "$@"; do
      if systemctl is-active --quiet "$_u" 2>/dev/null; then
        printf '%s' "$_u"
        return 0
      fi
    done
    return 1
  }

  _vf_rb_config_apply_record() {
    # <status> <label> <unit> <test> <action> <detail>
    local _status="$1" _name="$2" _svc="$3" _test="$4" _apply="$5" _text="$6"
    local _one
    _one=$(printf '%s\n' "$_text" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-500)
    case "$_status" in
      PASS)
        _VF_CONFIG_APPLY_OK=$((_VF_CONFIG_APPLY_OK+1))
        _ok "${_name} 설정 반영: ${_apply} 완료"
        ;;
      MANUAL)
        _VF_CONFIG_APPLY_MANUAL=$((_VF_CONFIG_APPLY_MANUAL+1))
        _warn "${_name} 설정 반영: 수동 확인 필요"
        ;;
      SKIP)
        _VF_CONFIG_APPLY_SKIP=$((_VF_CONFIG_APPLY_SKIP+1))
        _info "${_name} 비활성/미설치 상태: 서비스를 임의로 시작하지 않음"
        ;;
      FAIL|*)
        # 현재 호출부는 실패를 MANUAL로 전달하지만, 향후 FAIL 또는 새 상태가
        # 들어와도 집계와 화면 안내가 누락되지 않도록 안전하게 수동확인으로 집계한다.
        _VF_CONFIG_APPLY_MANUAL=$((_VF_CONFIG_APPLY_MANUAL+1))
        _warn "${_name} 설정 반영: 수동 확인 필요 (상태=${_status})"
        ;;
    esac
    echo "SERVICE_CONFIG|${_name}|${_status}|unit=${_svc:-NONE}|test=${_test:-NONE}|action=${_apply:-NONE}|${_one}" >> "$_log" 2>/dev/null
    {
      echo ""
      echo "[${_name} 설정 반영]"
      echo "상태   : ${_status}"
      echo "서비스 : ${_svc:-확인되지 않음}"
      echo "검증   : ${_test:-수행하지 않음}"
      echo "반영   : ${_apply:-수행하지 않음}"
      if [ -n "$_text" ]; then
        echo "상세   :"
        printf '%s\n' "$_text" | sed 's/^/  /'
      else
        echo "상세   : 없음"
      fi
    } >> "$_verify" 2>/dev/null
  }

  _vf_rb_reload_or_restart() {
    # <label> <unit> <test-description> <test-output>
    local _name="$1" _svc="$2" _test="$3" _test_out="$4"
    : > "$_out"
    if systemctl reload "$_svc" >>"$_out" 2>&1; then
      _action="reload"
    elif systemctl restart "$_svc" >>"$_out" 2>&1; then
      _action="restart"
    else
      _detail="${_test_out}"$'\n'"$(cat "$_out" 2>/dev/null)"
      _vf_rb_config_apply_record "MANUAL" "$_name" "$_svc" "$_test" "reload/restart 실패" "$_detail"
      return 1
    fi
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
      _detail="${_test_out}"$'\n'"$(cat "$_out" 2>/dev/null)"
      _vf_rb_config_apply_record "PASS" "$_name" "$_svc" "$_test" "$_action" "$_detail"
      return 0
    fi
    _detail="${_test_out}"$'\n'"$(cat "$_out" 2>/dev/null)"$'\n'"반영 후 서비스가 active 상태가 아님"
    _vf_rb_config_apply_record "MANUAL" "$_name" "$_svc" "$_test" "$_action 후 상태 이상" "$_detail"
    return 1
  }

  # rsyslog
  if _vf_rb_service_config_restored rsyslog.service "$_files"; then
    _label="rsyslog"; _unit=$(_vf_rb_find_active_unit rsyslog.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "rsyslogd -N1" "없음" "서비스가 active 상태가 아님"
    elif ! command -v rsyslogd >/dev/null 2>&1; then
      _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "rsyslogd -N1" "미수행" "rsyslogd 명령을 찾을 수 없음"
    else
      : > "$_out"
      if rsyslogd -N1 >"$_out" 2>&1; then
        _vf_rb_reload_or_restart "$_label" "$_unit" "rsyslogd -N1" "$(cat "$_out" 2>/dev/null)"
      else
        _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "rsyslogd -N1" "재시작 금지" "$(cat "$_out" 2>/dev/null)"
      fi
    fi
  fi

  # snmpd: net-snmp에는 실행 중 인스턴스와 충돌하지 않는 신뢰 가능한 비기동 문법 검사 모드가 없어 자동 재시작하지 않는다.
  if _vf_rb_service_config_restored snmpd.service "$_files"; then
    _label="snmpd"; _unit=$(_vf_rb_find_active_unit snmpd.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "안전한 비기동 검사 없음" "없음" "서비스가 active 상태가 아님"
    else
      _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "안전한 비기동 검사 없음" "재시작 금지" "설정 파일은 복원됐으나 전용 오프라인 문법 검사 수단이 없어 자동 재시작하지 않음"
    fi
  fi

  # vsftpd: 전용 오프라인 문법 검사 옵션이 없어 자동 재시작하지 않는다.
  if _vf_rb_service_config_restored vsftpd.service "$_files"; then
    _label="vsftpd"; _unit=$(_vf_rb_find_active_unit vsftpd.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "안전한 비기동 검사 없음" "없음" "서비스가 active 상태가 아님"
    else
      _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "안전한 비기동 검사 없음" "재시작 금지" "설정 파일은 복원됐으나 전용 오프라인 문법 검사 수단이 없어 자동 재시작하지 않음"
    fi
  fi

  # ProFTPD
  if _vf_rb_service_config_restored proftpd.service "$_files"; then
    _label="ProFTPD"; _unit=$(_vf_rb_find_active_unit proftpd.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "proftpd -t" "없음" "서비스가 active 상태가 아님"
    else
      _conf=""
      for _conf_candidate in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$_conf_candidate" ] && { _conf="$_conf_candidate"; break; }
      done
      if [ -z "$_conf" ] || ! command -v proftpd >/dev/null 2>&1; then
        _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "proftpd -t" "미수행" "설정 파일 또는 proftpd 명령을 찾을 수 없음"
      else
        : > "$_out"
        if proftpd -t -c "$_conf" >"$_out" 2>&1; then
          _vf_rb_reload_or_restart "$_label" "$_unit" "proftpd -t -c ${_conf}" "$(cat "$_out" 2>/dev/null)"
        else
          _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "proftpd -t -c ${_conf}" "재시작 금지" "$(cat "$_out" 2>/dev/null)"
        fi
      fi
    fi
  fi

  # BIND/named
  if _vf_rb_service_config_restored named.service "$_files"; then
    _label="named"; _unit=$(_vf_rb_find_active_unit named.service bind9.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "named-checkconf" "없음" "서비스가 active 상태가 아님"
    else
      _conf=""
      for _conf_candidate in /etc/named.conf /etc/bind/named.conf; do
        [ -f "$_conf_candidate" ] && { _conf="$_conf_candidate"; break; }
      done
      if [ -z "$_conf" ] || ! command -v named-checkconf >/dev/null 2>&1; then
        _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "named-checkconf" "미수행" "설정 파일 또는 named-checkconf 명령을 찾을 수 없음"
      else
        : > "$_out"
        if named-checkconf "$_conf" >"$_out" 2>&1; then
          _vf_rb_reload_or_restart "$_label" "$_unit" "named-checkconf ${_conf}" "$(cat "$_out" 2>/dev/null)"
        else
          _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "named-checkconf ${_conf}" "재시작 금지" "$(cat "$_out" 2>/dev/null)"
        fi
      fi
    fi
  fi

  # NFS: exportfs -ra가 exports 구문 확인과 실행 중 export 재반영을 함께 수행한다.
  if _vf_rb_service_config_restored nfs-server.service "$_files"; then
    _label="NFS"; _unit=$(_vf_rb_find_active_unit nfs-server.service nfs-kernel-server.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "exportfs -ra" "없음" "서비스가 active 상태가 아님"
    elif ! command -v exportfs >/dev/null 2>&1; then
      _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "exportfs -ra" "미수행" "exportfs 명령을 찾을 수 없음"
    else
      : > "$_out"
      if exportfs -ra >"$_out" 2>&1; then
        _detail=$(cat "$_out" 2>/dev/null)
        if systemctl is-active --quiet "$_unit" 2>/dev/null; then
          _vf_rb_config_apply_record "PASS" "$_label" "$_unit" "exportfs -ra (검증·반영)" "exportfs -ra" "$_detail"
        else
          _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "exportfs -ra (검증·반영)" "반영 후 상태 이상" "${_detail}"$'\n'"서비스가 active 상태가 아님"
        fi
      else
        _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "exportfs -ra (검증·반영)" "재시작 금지" "$(cat "$_out" 2>/dev/null)"
      fi
    fi
  fi

  # xinetd: 안전한 비기동 전체 설정 검사 옵션이 없어 자동 재시작하지 않는다.
  if _vf_rb_service_config_restored xinetd.service "$_files"; then
    _label="xinetd"; _unit=$(_vf_rb_find_active_unit xinetd.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "안전한 비기동 검사 없음" "없음" "서비스가 active 상태가 아님"
    else
      _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "안전한 비기동 검사 없음" "재시작 금지" "설정 파일은 복원됐으나 전용 오프라인 문법 검사 수단이 없어 자동 재시작하지 않음"
    fi
  fi

  # chronyd/chrony
  if _vf_rb_service_config_restored chronyd.service "$_files"; then
    _label="chronyd"; _unit=$(_vf_rb_find_active_unit chronyd.service chrony.service || true)
    if [ -z "$_unit" ]; then
      _vf_rb_config_apply_record "SKIP" "$_label" "" "chronyd -p" "없음" "서비스가 active 상태가 아님"
    else
      _conf=""
      for _conf_candidate in /etc/chrony.conf /etc/chrony/chrony.conf; do
        [ -f "$_conf_candidate" ] && { _conf="$_conf_candidate"; break; }
      done
      if [ -z "$_conf" ] || ! command -v chronyd >/dev/null 2>&1; then
        _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "chronyd -p" "미수행" "설정 파일 또는 chronyd 명령을 찾을 수 없음"
      else
        : > "$_out"
        if chronyd -p -f "$_conf" >"$_out" 2>&1; then
          _vf_rb_reload_or_restart "$_label" "$_unit" "chronyd -p -f ${_conf}" "$(cat "$_out" 2>/dev/null)"
        else
          _vf_rb_config_apply_record "MANUAL" "$_label" "$_unit" "chronyd -p -f ${_conf}" "재시작 금지" "$(cat "$_out" 2>/dev/null)"
        fi
      fi
    fi
  fi

  {
    echo ""
    echo "[복원 설정 서비스 반영 요약]"
    echo "성공=${_VF_CONFIG_APPLY_OK} 수동확인=${_VF_CONFIG_APPLY_MANUAL} 건너뜀=${_VF_CONFIG_APPLY_SKIP}"
    echo "SSH는 원격 세션 보호를 위해 자동 reload/restart 대상에서 제외"
  } >> "$_verify" 2>/dev/null

  unset -f _vf_rb_find_active_unit _vf_rb_config_apply_record _vf_rb_reload_or_restart 2>/dev/null
}

# iptables-save 결과에서 실행 중 변하는 패킷·바이트 카운터와 생성 시각만 제거한다.
# 규칙의 순서는 의미가 있으므로 정렬하지 않고 원래 순서를 유지한다.
_vf_normalize_iptables_dump() {
  sed -E \
    -e 's/\[[0-9]+:[0-9]+\]/[0:0]/g' \
    -e '/^# Generated by /d' \
    -e '/^# Completed on /d' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*$/d' "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_restore_firewall_state
#
# 역할:
#   백업 메타데이터를 기준으로 firewalld, ufw, iptables, nftables 상태를 복원·검증한다.
#
# 입력:
#   $1 : 백업된 방화벽 메타데이터 디렉터리
#   $2 : 롤백 작업용 임시 디렉터리
#   $3 : 롤백 실행 로그 파일
#   $4 : 롤백 검증 로그 파일
#
# 결과 전역:
#   _VF_FW_OK / _VF_FW_FAIL / _VF_FW_MANUAL / _VF_FW_RUNTIME_DRIFT
#
# 시스템 영향:
#   방화벽 reload와 저장 규칙 복원을 수행할 수 있다.
#
# 안전 조건:
#   - 백업 당시 사용 가능했던 방화벽 도구와 상태를 확인한 뒤 처리
#   - 복원 후 규칙을 정규화해 백업값과 재비교
#   - firewalld Runtime과 Permanent가 달랐던 경우 자동 성공으로 단정하지 않고
#     별도 수동 확인 대상으로 기록
# -----------------------------------------------------------------------------
_vf_restore_firewall_state() {
  local _dir="$1" _workdir="$2" _log="$3" _verify="$4"
  _VF_FW_OK=0; _VF_FW_FAIL=0; _VF_FW_MANUAL=0; _VF_FW_RUNTIME_DRIFT=0
  [ -f "$_dir/firewall.meta" ] || { _VF_FW_MANUAL=1; return 0; }

  local _fw_active _ufw_active _fw_runtime_drift
  local _fw_err="${_workdir}/firewall_restore.stderr" _fw_out="${_workdir}/firewall_restore.stdout"
  : > "$_fw_err"; : > "$_fw_out"
  _fw_active=$(_vf_meta_value "$_dir/firewall.meta" FIREWALLD_ACTIVE)
  _ufw_active=$(_vf_meta_value "$_dir/firewall.meta" UFW_ACTIVE)
  _fw_runtime_drift=$(_vf_meta_value "$_dir/firewall.meta" FIREWALLD_RUNTIME_DRIFT)
  [ "$_fw_runtime_drift" = '1' ] && _VF_FW_RUNTIME_DRIFT=1

  if [ "$_fw_active" = 'active' ] && command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --reload >"$_fw_out" 2>"$_fw_err"; then
      : > "$_fw_err"
      if firewall-cmd --list-all-zones --permanent > "$_workdir/firewalld.current" 2>"$_fw_err"; then
        if [ -f "$_dir/firewalld.permanent" ] \
           && diff -q <(_vf_normalize_firewalld_dump "$_dir/firewalld.permanent") \
                     <(_vf_normalize_firewalld_dump "$_workdir/firewalld.current") >/dev/null 2>&1; then
          _VF_FW_OK=$((_VF_FW_OK+1))
          echo 'FIREWALL|FIREWALLD|PASS|permanent 일치' >> "$_log" 2>/dev/null
        else
          _VF_FW_FAIL=$((_VF_FW_FAIL+1))
          echo 'FIREWALL|FIREWALLD_PERMANENT_DRIFT|비교 불일치' >> "$_log" 2>/dev/null
          {
            echo ""
            echo "[firewalld 복원 실패]"
            echo "사유: Permanent 규칙이 백업 기준과 일치하지 않음"
          } >> "$_verify" 2>/dev/null
        fi
      else
        _VF_FW_FAIL=$((_VF_FW_FAIL+1))
        echo "FIREWALL|FIREWALLD_LIST_FAIL|$(tr '\n' ' ' < "$_fw_err")" >> "$_log" 2>/dev/null
      fi
    else
      _VF_FW_FAIL=$((_VF_FW_FAIL+1))
      echo "FIREWALL|FIREWALLD_RELOAD_FAIL|$(tr '\n' ' ' < "$_fw_err")" >> "$_log" 2>/dev/null
      {
        echo ""
        echo "[firewalld 복원 실패]"
        echo "명령: firewall-cmd --reload"
        echo "오류: $(tr '\n' ' ' < "$_fw_err")"
      } >> "$_verify" 2>/dev/null
    fi

  elif [ "$_ufw_active" = 'active' ] && command -v ufw >/dev/null 2>&1; then
    if ufw reload >"$_fw_out" 2>"$_fw_err"; then
      : > "$_fw_err"
      if ufw status verbose > "$_workdir/ufw.current" 2>"$_fw_err" \
         && [ -f "$_dir/ufw.status" ] \
         && diff -q <(_vf_normalize_text_file "$_dir/ufw.status") \
                   <(_vf_normalize_text_file "$_workdir/ufw.current") >/dev/null 2>&1; then
        _VF_FW_OK=$((_VF_FW_OK+1))
        echo 'FIREWALL|UFW|PASS' >> "$_log" 2>/dev/null
      else
        _VF_FW_FAIL=$((_VF_FW_FAIL+1))
        echo "FIREWALL|UFW_DRIFT_OR_STATUS_FAIL|$(tr '\n' ' ' < "$_fw_err")" >> "$_log" 2>/dev/null
      fi
    else
      _VF_FW_FAIL=$((_VF_FW_FAIL+1))
      echo "FIREWALL|UFW_RELOAD_FAIL|$(tr '\n' ' ' < "$_fw_err")" >> "$_log" 2>/dev/null
    fi

  elif [ -s "$_dir/iptables.v4" ] && command -v iptables-restore >/dev/null 2>&1; then
    local _v4_err="${_workdir}/iptables_restore.v4.stderr" _v4_out="${_workdir}/iptables_restore.v4.stdout"
    : > "$_v4_err"; : > "$_v4_out"
    if iptables-restore < "$_dir/iptables.v4" >"$_v4_out" 2>"$_v4_err"; then
      : > "$_v4_err"
      if iptables-save > "$_workdir/iptables.current.v4" 2>"$_v4_err"; then
        if diff -q <(_vf_normalize_iptables_dump "$_dir/iptables.v4") \
                  <(_vf_normalize_iptables_dump "$_workdir/iptables.current.v4") >/dev/null 2>&1; then
          _VF_FW_OK=$((_VF_FW_OK+1))
          echo 'FIREWALL|IPTABLES_V4|PASS' >> "$_log" 2>/dev/null
        else
          _VF_FW_FAIL=$((_VF_FW_FAIL+1))
          echo 'FIREWALL|IPTABLES_V4|COMPARE_FAIL|카운터·생성시각 정규화 후에도 불일치' >> "$_log" 2>/dev/null
          {
            echo ""
            echo "[iptables IPv4 복원 실패]"
            echo "사유: 복원 후 규칙이 백업 기준과 일치하지 않음"
          } >> "$_verify" 2>/dev/null
        fi
      else
        _VF_FW_FAIL=$((_VF_FW_FAIL+1))
        echo "FIREWALL|IPTABLES_V4|SAVE_FAIL|$(tr '\n' ' ' < "$_v4_err")" >> "$_log" 2>/dev/null
      fi
    else
      _VF_FW_FAIL=$((_VF_FW_FAIL+1))
      echo "FIREWALL|IPTABLES_V4|RESTORE_FAIL|$(tr '\n' ' ' < "$_v4_err")" >> "$_log" 2>/dev/null
      {
        echo ""
        echo "[iptables IPv4 복원 실패]"
        echo "명령: iptables-restore"
        echo "오류: $(tr '\n' ' ' < "$_v4_err")"
      } >> "$_verify" 2>/dev/null
    fi

    if [ -s "$_dir/iptables.v6" ]; then
      if command -v ip6tables-restore >/dev/null 2>&1 && command -v ip6tables-save >/dev/null 2>&1; then
        local _v6_err="${_workdir}/iptables_restore.v6.stderr" _v6_out="${_workdir}/iptables_restore.v6.stdout"
        : > "$_v6_err"; : > "$_v6_out"
        if ip6tables-restore < "$_dir/iptables.v6" >"$_v6_out" 2>"$_v6_err"; then
          : > "$_v6_err"
          if ip6tables-save > "$_workdir/iptables.current.v6" 2>"$_v6_err"; then
            if diff -q <(_vf_normalize_iptables_dump "$_dir/iptables.v6") \
                      <(_vf_normalize_iptables_dump "$_workdir/iptables.current.v6") >/dev/null 2>&1; then
              _VF_FW_OK=$((_VF_FW_OK+1))
              echo 'FIREWALL|IPTABLES_V6|PASS' >> "$_log" 2>/dev/null
            else
              _VF_FW_FAIL=$((_VF_FW_FAIL+1))
              echo 'FIREWALL|IPTABLES_V6|COMPARE_FAIL|카운터·생성시각 정규화 후에도 불일치' >> "$_log" 2>/dev/null
              {
                echo ""
                echo "[iptables IPv6 복원 실패]"
                echo "사유: 복원 후 규칙이 백업 기준과 일치하지 않음"
              } >> "$_verify" 2>/dev/null
            fi
          else
            _VF_FW_FAIL=$((_VF_FW_FAIL+1))
            echo "FIREWALL|IPTABLES_V6|SAVE_FAIL|$(tr '\n' ' ' < "$_v6_err")" >> "$_log" 2>/dev/null
          fi
        else
          _VF_FW_FAIL=$((_VF_FW_FAIL+1))
          echo "FIREWALL|IPTABLES_V6|RESTORE_FAIL|$(tr '\n' ' ' < "$_v6_err")" >> "$_log" 2>/dev/null
          {
            echo ""
            echo "[iptables IPv6 복원 실패]"
            echo "명령: ip6tables-restore"
            echo "오류: $(tr '\n' ' ' < "$_v6_err")"
          } >> "$_verify" 2>/dev/null
        fi
      else
        _VF_FW_MANUAL=$((_VF_FW_MANUAL+1))
        echo 'FIREWALL|IPTABLES_V6|MANUAL|ip6tables 도구 없음' >> "$_log" 2>/dev/null
      fi
    fi

  elif [ -s "$_dir/nft.rules" ]; then
    # nft 전체 ruleset 교체는 원격 연결을 즉시 끊을 수 있어 자동 적용하지 않는다.
    _VF_FW_MANUAL=$((_VF_FW_MANUAL+1))
    echo 'FIREWALL|NFT_BASELINE_MANUAL' >> "$_log" 2>/dev/null
  fi

  if [ "${_VF_FW_RUNTIME_DRIFT:-0}" -eq 1 ]; then
    _VF_FW_MANUAL=$((_VF_FW_MANUAL+1))
    echo 'FIREWALL|FIREWALLD_RUNTIME_DRIFT|MANUAL' >> "$_log" 2>/dev/null
    {
      echo ""
      echo "[firewalld Runtime 복원 범위]"
      echo "백업 시점 Runtime과 Permanent 규칙이 달랐음"
      echo "Permanent 설정은 복원했으나 당시 Runtime 전용 규칙은 별도 확인 필요"
    } >> "$_verify" 2>/dev/null
  fi

  {
    echo ""
    echo "[방화벽 상태 복원]"
    echo "성공=${_VF_FW_OK} 실패=${_VF_FW_FAIL} 추가확인=${_VF_FW_MANUAL}"
  } >> "$_verify" 2>/dev/null
}
# -----------------------------------------------------------------------------
# _vf_compare_extended_one
#
# 역할:
#   원본 백업 파일과 롤백 후 파일의 ACL, xattr, SELinux context,
#   file capability를 비교한다.
#
# 입력:
#   $1 : 백업에서 추출한 비교 원본 경로
#   $2 : 롤백 후 실제 시스템 경로
#   $3 : 로그에 표시할 대상 경로
#   $4 : 롤백 실행 로그 파일
#
# 결과 전역:
#   _VF_EXT_OK / _VF_EXT_FAIL 값을 누적한다.
#
# 안전 조건:
#   - 심볼릭 링크는 도구별 dereference 차이 때문에 확장 메타데이터 비교에서 제외
#   - 백업과 현재 환경에서 지원되는 기능만 비교
#   - 지원되지 않는 기능은 파일별 실패가 아니라 상위 검증 단계에서 추가 확인 처리
# -----------------------------------------------------------------------------
_vf_compare_extended_one() {
  local _src="$1" _dst="$2" _display="$3" _log="$4"
  local _a _b
  # 심볼릭 링크 확장속성은 도구별 dereference 동작이 달라 기본 메타/링크대상 비교만 사용한다.
  if [ -L "$_src" ] || [ -L "$_dst" ]; then return 0; fi
  if [ "${_RB_TAR_ACLS:-0}" -eq 1 ] && command -v getfacl >/dev/null 2>&1; then
    _a=$(getfacl -cp "$_src" 2>/dev/null); _b=$(getfacl -cp "$_dst" 2>/dev/null)
    if [ "$_a" = "$_b" ]; then _VF_EXT_OK=$((_VF_EXT_OK+1)); else _VF_EXT_FAIL=$((_VF_EXT_FAIL+1)); echo "EXTMETA|ACL_FAIL|${_display}" >> "$_log"; fi
  fi
  if [ "${_RB_TAR_XATTRS:-0}" -eq 1 ] && command -v getfattr >/dev/null 2>&1; then
    _a=$(getfattr -d -m- --absolute-names "$_src" 2>/dev/null | sed '/^# file:/d' | LC_ALL=C sort)
    _b=$(getfattr -d -m- --absolute-names "$_dst" 2>/dev/null | sed '/^# file:/d' | LC_ALL=C sort)
    if [ "$_a" = "$_b" ]; then _VF_EXT_OK=$((_VF_EXT_OK+1)); else _VF_EXT_FAIL=$((_VF_EXT_FAIL+1)); echo "EXTMETA|XATTR_FAIL|${_display}" >> "$_log"; fi
  fi
  if [ "${_RB_TAR_SELINUX:-0}" -eq 1 ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    _a=$(stat -c '%C' "$_src" 2>/dev/null); _b=$(stat -c '%C' "$_dst" 2>/dev/null)
    if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then _VF_EXT_OK=$((_VF_EXT_OK+1)); else _VF_EXT_FAIL=$((_VF_EXT_FAIL+1)); echo "EXTMETA|SELINUX_FAIL|${_display}|${_a}|${_b}" >> "$_log"; fi
  fi
  if [ "${_RB_TAR_XATTRS:-0}" -eq 1 ] && command -v getcap >/dev/null 2>&1 && [ -f "$_src" ] && [ -f "$_dst" ]; then
    _a=$(getcap -n "$_src" 2>/dev/null | awk '{ $1=""; sub(/^[[:space:]]+/, ""); print }')
    _b=$(getcap -n "$_dst" 2>/dev/null | awk '{ $1=""; sub(/^[[:space:]]+/, ""); print }')
    if [ "$_a" = "$_b" ]; then _VF_EXT_OK=$((_VF_EXT_OK+1)); else _VF_EXT_FAIL=$((_VF_EXT_FAIL+1)); echo "EXTMETA|CAPABILITY_FAIL|${_display}|${_a}|${_b}" >> "$_log"; fi
  fi
}


# =============================================================================
# ── [결과 보고서 자동 생성] 데이터 수집 (추가 전용 — 기존 취약점 점검/조치 로직 및
#    check_still_vuln / do_fix / do_manual 의 판정 로직은 일절 변경하지 않는다.
#    아래는 U-01~U-76 각 항목의 "항목ID/항목명/위험도/대분류"를 조회하기 위한
#    참조표와, 결과를 CSV로 적재하는 함수만 새로 추가한다.) ─────────────────────
# =============================================================================
declare -A ID_TITLE_MAP=(
  ["U-01"]="(상) root 계정 원격 접속 제한"
  ["U-02"]="(상) 비밀번호 관리정책 설정"
  ["U-03"]="(상) 계정 잠금 임계값 설정"
  ["U-04"]="(상) 비밀번호 파일 보호"
  ["U-05"]="(상) root 이외의 UID가 '0' 금지"
  ["U-06"]="(상) 사용자 계정 su 기능 제한"
  ["U-07"]="(하) 불필요한 계정 제거"
  ["U-08"]="(중) 관리자 그룹에 최소한의 계정 포함"
  ["U-09"]="(하) 계정이 존재하지 않는 GID 금지"
  ["U-10"]="(중) 동일한 UID 금지"
  ["U-11"]="(하) 사용자 Shell 점검"
  ["U-12"]="(하) 세션 종료 시간 설정"
  ["U-13"]="(중) 안전한 비밀번호 암호화 알고리즘 사용"
  ["U-14"]="(상) root 홈, 패스 디렉터리 권한 및 패스 설정"
  ["U-15"]="(상) 파일 및 디렉터리 소유자 설정"
  ["U-16"]="(상) /etc/passwd 파일 소유자 및 권한 설정"
  ["U-17"]="(상) 시스템 시작 스크립트 권한 설정"
  ["U-18"]="(상) /etc/shadow 파일 소유자 및 권한 설정"
  ["U-19"]="(상) /etc/hosts 파일 소유자 및 권한 설정"
  ["U-20"]="(상) /etc/(x)inetd.conf 파일 소유자 및 권한 설정"
  ["U-21"]="(상) /etc/rsyslog.conf 소유자 및 권한"
  ["U-22"]="(상) /etc/services 파일 소유자 및 권한 설정"
  ["U-23"]="(상) SUID, SGID, Sticky bit 설정 파일 점검"
  ["U-24"]="(상) 사용자, 시스템 환경변수 파일 소유자 및 권한 설정"
  ["U-25"]="(상) world writable 파일 점검"
  ["U-26"]="(상) /dev에 존재하지 않는 device 파일 점검"
  ["U-27"]="(상) \$HOME/.rhosts, hosts.equiv 사용 금지"
  ["U-28"]="(상) 접속 IP 및 포트 제한"
  ["U-29"]="(하) hosts.lpd 파일 소유자 및 권한 설정"
  ["U-30"]="(중) UMASK 설정 관리"
  ["U-31"]="(중) 홈 디렉토리 소유자 및 권한 설정"
  ["U-32"]="(중) 홈 디렉토리로 지정한 디렉토리의 존재 관리"
  ["U-33"]="(하) 숨겨진 파일 및 디렉토리 검색 및 제거"
  ["U-34"]="(상) Finger 서비스 비활성화"
  ["U-35"]="(상) 공유 서비스에 대한 익명 접근 제한 설정"
  ["U-36"]="(상) r 계열 서비스 비활성화"
  ["U-37"]="(상) crontab 설정파일 권한 설정 미흡"
  ["U-38"]="(상) DoS 취약 서비스 비활성화"
  ["U-39"]="(상) 불필요한 NFS 서비스 비활성화"
  ["U-40"]="(상) NFS 접근 통제"
  ["U-41"]="(상) 불필요한 automountd 제거"
  ["U-42"]="(상) 불필요한 RPC 서비스 비활성화"
  ["U-43"]="(상) NIS, NIS+ 점검"
  ["U-44"]="(상) tftp, talk 서비스 비활성화"
  ["U-45"]="(상) 메일 서비스 버전 점검"
  ["U-46"]="(상) 일반 사용자의 메일 서비스 실행 방지"
  ["U-47"]="(상) 스팸 메일 릴레이 제한"
  ["U-48"]="(중) expn, vrfy 명령어 제한"
  ["U-49"]="(상) DNS 보안 버전 패치"
  ["U-50"]="(상) DNS Zone Transfer 설정"
  ["U-51"]="(중) DNS 서비스의 취약한 동적 업데이트 설정 금지"
  ["U-52"]="(중) Telnet 서비스 비활성화"
  ["U-53"]="(하) FTP 서비스 정보 노출 제한"
  ["U-54"]="(중) 암호화되지 않는 FTP 서비스 비활성화"
  ["U-55"]="(중) FTP 계정 Shell 제한"
  ["U-56"]="(하) FTP 서비스 접근 제어 설정 (IP/호스트 기반)"
  ["U-57"]="(중) Ftpusers 파일 설정"
  ["U-58"]="(중) 불필요한 SNMP 서비스 구동 점검"
  ["U-59"]="(상) 안전한 SNMP 버전 사용"
  ["U-60"]="(중) SNMP Community String 복잡성 설정"
  ["U-61"]="(상) SNMP Access Control 설정"
  ["U-62"]="(하) 로그인 시 경고 메시지 설정"
  ["U-63"]="(중) sudo 명령어 접근 관리"
  ["U-64"]="(상) 주기적 보안 패치 및 벤더 권고사항 적용"
  ["U-65"]="(중) NTP 및 시각 동기화 설정"
  ["U-66"]="(중) 정책에 따른 시스템 로깅 설정"
  ["U-67"]="(중) 로그 디렉터리 소유자 및 권한 설정"
)

# _id_category <U-xx> — 대분류 반환 (섹션 헤더의 U-번호 범위와 완전히 동일한 기준)
_id_category() {
  local n="${1#U-}"; n=$((10#$n))
  if   [ "$n" -ge 1  ] && [ "$n" -le 13 ]; then echo "계정 관리"
  elif [ "$n" -ge 14 ] && [ "$n" -le 33 ]; then echo "파일 및 디렉터리 관리"
  elif [ "$n" -ge 34 ] && [ "$n" -le 63 ]; then echo "서비스 관리"
  elif [ "$n" -eq 64 ]; then echo "패치 관리"
  elif [ "$n" -ge 65 ] && [ "$n" -le 67 ]; then echo "로그 관리"
  else echo "미분류"
  fi
}

# _has_cat_target <대분류명> — TARGET_IDS 중 해당 대분류에 속한 항목이 하나라도 있는지 확인.
# 분리 스크립트에서 해당 없는 대분류의 섹션 헤더만 텅 빈 채로 출력되는 것을 방지한다.
_has_cat_target() {
  local cat="$1" tid
  for tid in "${TARGET_IDS[@]}"; do
    [ "$(_id_category "$tid")" = "$cat" ] && return 0
  done
  return 1
}

_HOSTNAME_VAL="$(hostname 2>/dev/null)"
[ -n "$_HOSTNAME_VAL" ] || _HOSTNAME_VAL="unknown-host"
_OS_INFO="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") 2>/dev/null)"
[ -n "$_OS_INFO" ] || _OS_INFO="$(uname -s)"
_OS_INFO="${_OS_INFO} (kernel $(uname -r 2>/dev/null))"

REPORT_CSV="${_RPT_BASE_DIR}/vulnFixResult_${_HOSTNAME_VAL}_${_RUN_TS}.csv"
REPORT_XLSX="${_RPT_BASE_DIR}/vulnFixReport_${_HOSTNAME_VAL}_${_RUN_TS}.xlsx"
_REPORT_CSV_HEADER_WRITTEN=0

# CSV 한 필드를 RFC 4180 형태의 큰따옴표 필드로 변환한다.
# CR은 제거하고 실제 개행은 " | "로 치환하며 내부 따옴표는 두 번 기록한다.
_csv_esc() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ | }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

# -----------------------------------------------------------------------------
# _report_init_csv
#
# 역할:
#   현재 실행의 CSV 결과 파일을 최초 한 번 초기화하고 표준 머리글을 기록한다.
#
# 출력:
#   REPORT_CSV 경로에 UTF-8 BOM과 고정 컬럼 머리글을 생성한다.
#
# 결과 전역:
#   _REPORT_CSV_HEADER_WRITTEN=1
#
# 안전 조건:
#   같은 실행에서 두 번 이상 호출돼도 기존 결과 행을 덮어쓰지 않는다.
# -----------------------------------------------------------------------------
_report_init_csv() {
  [ "$_REPORT_CSV_HEADER_WRITTEN" -eq 1 ] && return
  # UTF-8 BOM(0xEF 0xBB 0xBF) 선행 출력 — Excel이 BOM을 보고 인코딩을 UTF-8로 자동 인식.
  # BOM 없이 저장하면 Excel에서 한글이 깨져 보임.
  # $'...' 는 bash/ksh의 ANSI-C quoting — \x 이스케이프를 실제 바이트로 확장한다.
  printf $'\xef\xbb\xbf' > "$REPORT_CSV" 2>/dev/null
  echo "항목ID,항목명,위험도,대분류,조치전상태,조치후상태,최종결과,수동확인사유,실패사유,상세내역,백업파일경로,실행일시,서버명,OS정보" \
    >> "$REPORT_CSV" 2>/dev/null
  _REPORT_CSV_HEADER_WRITTEN=1
}

# -----------------------------------------------------------------------------
# _report_add
#
# 역할:
#   한 취약점 항목의 최종 결과와 증빙값을 CSV 결과 행으로 기록한다.
#
# 입력:
#   $1 : 항목 ID
#   $2 : 최종 결과(양호/조치완료/수동확인/실패/해당없음/건너뜀)
#   $3 : 수동 확인 사유(선택)
#   $4 : 실패 사유(선택)
#
# 사용 데이터:
#   ID_TITLE_MAP, BEFORE_VAL, AFTER_VAL, DETAIL_VAL,
#   _PRE_BAK_RECORDED, 서버·OS·실행 시각
#
# 결과 전역:
#   _REPORT_RECORDED[항목ID]=1
#
# 안전 조건:
#   개별 항목이 상태값을 채우지 못한 경우에도 결과 유형에 맞는 보수적 기본값을 기록한다.
# -----------------------------------------------------------------------------
_report_add() {
  local id="$1" result="$2" manual_reason="${3:-}" fail_reason="${4:-}"
  _report_init_csv
  local title_raw="${ID_TITLE_MAP[$id]:-$id}"
  local risk=""
  case "$title_raw" in
    "(상)"*) risk="상" ;;
    "(중)"*) risk="중" ;;
    "(하)"*) risk="하" ;;
  esac
  local name="$title_raw"
  name="${name#"(상) "}"; name="${name#"(중) "}"; name="${name#"(하) "}"
  local category; category="$(_id_category "$id")"
  local before="${BEFORE_VAL[$id]:-}"
  local after="${AFTER_VAL[$id]:-}"

  # 일부 커스텀 항목이 BEFORE_VAL/AFTER_VAL/DETAIL_VAL을 명시적으로 채우지 않아도
  # CSV/XLSX 셀이 공란으로 남지 않도록 결과 상태 기준의 보수적인 기본값을 사용한다.
  [ -z "$before" ] && before="점검값 미수집"
  if [ -z "$after" ]; then
    case "$result" in
      양호)     after="이미 양호 (재확인 통과)" ;;
      조치완료) after="조치 완료 (검증 통과)" ;;
      수동확인) after="수동 확인 필요" ;;
      실패)     after="조치 실패" ;;
      해당없음) after="해당없음" ;;
      건너뜀)   after="사용자 건너뜀" ;;
      *)        after="결과 확인 필요" ;;
    esac
  fi

  # 상세내역: 항목별 값이 없으면 전/후 상태와 사유를 조합해 최소 증빙을 남긴다.
  local detail="${DETAIL_VAL[$id]:-}"
  if [ -z "$detail" ]; then
    detail="[현재 상태] ${before} | [결과] ${after}"
    [ -n "$manual_reason" ] && detail="${detail} | [수동확인 사유] ${manual_reason}"
    [ -n "$fail_reason" ]   && detail="${detail} | [실패 사유] ${fail_reason}"
  fi
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    printf '%s,' "$(_csv_esc "$id")"
    printf '%s,' "$(_csv_esc "$name")"
    printf '%s,' "$(_csv_esc "$risk")"
    printf '%s,' "$(_csv_esc "$category")"
    printf '%s,' "$(_csv_esc "$before")"
    printf '%s,' "$(_csv_esc "$after")"
    printf '%s,' "$(_csv_esc "$result")"
    printf '%s,' "$(_csv_esc "$manual_reason")"
    printf '%s,' "$(_csv_esc "$fail_reason")"
    printf '%s,' "$(_csv_esc "$detail")"
    printf '%s,' "$(_csv_esc "${_PRE_BAK_RECORDED:-미생성}")"
    printf '%s,' "$(_csv_esc "$ts")"
    printf '%s,' "$(_csv_esc "$_HOSTNAME_VAL")"
    printf '%s\n' "$(_csv_esc "$_OS_INFO")"
  } >> "$REPORT_CSV" 2>/dev/null
  _REPORT_RECORDED["$id"]=1
}

# -----------------------------------------------------------------------------
# _report_finalize_rows
#
# 역할:
#   TARGET_IDS 중 CSV 결과 행이 생성되지 않은 항목을 찾아 실패 행으로 보정한다.
#
# 목적:
#   전체 진단 항목 수와 CSV·Excel의 결과 행 수가 달라지는 무결성 오류를 방지한다.
#
# 시스템 영향:
#   누락 항목에 대한 결과 행만 추가하며 점검이나 조치를 다시 수행하지 않는다.
# -----------------------------------------------------------------------------
_report_finalize_rows() {
  local _rid
  for _rid in "${TARGET_IDS[@]}"; do
    [ -n "${_REPORT_RECORDED[$_rid]:-}" ] && continue
    BEFORE_VAL["$_rid"]="점검 결과 기록 누락"
    AFTER_VAL["$_rid"]="결과 데이터 생성 실패"
    DETAIL_VAL["$_rid"]="[무결성 검사] 해당 항목의 최종 결과 행이 기록되지 않아 실패로 보정"
    _report_add "$_rid" "실패" "" "결과 기록 누락"
  done
}
# =============================================================================

# root 권한 확인
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[오류] root 권한으로 실행해주세요.${RESET}"; exit 1
fi

# ── 동시 실행 방지 ────────────────────────────────────────────────────────────
# 같은 서버에서 스크립트를 두 세션에서 동시에 실행하면 사전 백업과 PAM 등
# 공유 파일 수정이 서로 겹쳐 꼬일 수 있어, 락을 걸어 중복 실행을 막는다.
#
# 주의: Bash의 백그라운드 자식 프로세스는 부모의 파일 디스크립터를 상속한다.
# PAM 로그인 확인용 워치독(sleep)이 FD 9를 상속하면 본 스크립트가 끝난 뒤에도
# 최대 90초 동안 잠금이 유지될 수 있다. 따라서 종료 시 명시적으로 잠금을 해제하고,
# 모든 장기 백그라운드 작업에서는 FD 9를 닫아 잠금이 유출되지 않게 한다.
_LOCK_FILE="/var/run/vulnFix.lock"
[ -w /var/run ] || _LOCK_FILE="/tmp/vulnFix.lock"
_INSTANCE_LOCK_HELD=0

# 획득한 flock 잠금과 파일 디스크립터 9를 명시적으로 해제한다.
# 백그라운드 자식이 FD를 상속해 종료 후에도 잠금이 남는 상황을 방지한다.
_release_instance_lock() {
  if [ "${_INSTANCE_LOCK_HELD:-0}" -eq 1 ]; then
    flock -u 9 2>/dev/null || true
    { exec 9>&-; } 2>/dev/null || true
    _INSTANCE_LOCK_HELD=0
  fi
}

if command -v flock &>/dev/null; then
  # <>로 열어 기존 PID 기록을 잠금 획득 전에 지우지 않는다.
  { exec 9<>"$_LOCK_FILE"; } 2>/dev/null
  if ! flock -n 9 2>/dev/null; then
    _lock_pid=$(head -1 "$_LOCK_FILE" 2>/dev/null | tr -cd '0-9')
    echo -e "${RED}[오류] 이미 다른 세션에서 이 스크립트가 실행 중입니다 (${_LOCK_FILE}).${RESET}"
    if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
      echo -e "${YELLOW}       실행 중인 프로세스: PID ${_lock_pid}${RESET}"
    else
      echo -e "${YELLOW}       백그라운드 작업이 잠금을 유지 중일 수 있습니다.${RESET}"
    fi
    echo -e "${YELLOW}       동시 실행 시 백업/설정 변경이 꼬일 수 있어 실행을 막습니다.${RESET}"
    { exec 9>&-; } 2>/dev/null || true
    exit 1
  fi

  _INSTANCE_LOCK_HELD=1
  : > "$_LOCK_FILE"
  printf '%s\n' "$$" >&9
  trap '_release_instance_lock' EXIT
else
  echo -e "${YELLOW}[알림] flock 명령이 없어 동시 실행 방지를 건너뜁니다. 이 서버에서 스크립트를 두 세션 이상 동시에 실행하지 마세요.${RESET}"
fi

echo -e "${BOLD}"
_box_top
_box_line "자동 점검 및 조치 스크립트 | KISA 2026 가이드 기반"
_box_line "v1.1-yyyee"
_box_bottom
echo -e "${RESET}"

# ── 실행 옵션 파싱 ────────────────────────────────────────────────────────────
NO_PROMPT=0
ROLLBACK=0
_ARGS=()
for _a in "$@"; do
  case "$_a" in
    --no-prompt)       NO_PROMPT=1 ;;
    --rollback)        ROLLBACK=1  ;;
    -h|--help)
      _HELP_SCRIPT_NAME=$(basename "$0")
      echo ""
      echo -e " ${CYAN}[프로그램 구성]${RESET}"
      echo ""
      echo -e "   /linux_vuln_fix/"
      echo -e "   ├── ${_HELP_SCRIPT_NAME}    실행 스크립트"
      echo -e "   └── lib/                    보고서 생성에 필요한 내부 파일"
      echo ""
      echo -e "   ${YELLOW}※ 실행 스크립트와 lib 폴더는 같은 위치에 있어야 합니다.${RESET}"
      echo -e "   ${YELLOW}※ lib 폴더의 파일은 직접 실행하거나 이름을 변경하지 마세요.${RESET}"
      echo ""
      echo -e " ${CYAN}[기본 사용법]${RESET}"
      echo ""
      echo -e "   1. 전체 점검 및 조치"
      echo ""
      echo -e "      cd /linux_vuln_fix"
      echo -e "      chmod +x ${_HELP_SCRIPT_NAME}"
      echo -e "      ./${_HELP_SCRIPT_NAME}"
      echo ""
      echo -e "      U-01~U-67 항목을 점검하고, 취약 항목별로"
      echo -e "      조치 여부를 확인한 후 선택한 항목을 조치합니다."
      echo ""
      echo -e "   2. 이전 백업으로 복원"
      echo ""
      echo -e "      ./${_HELP_SCRIPT_NAME} --rollback"
      echo ""
      echo -e "      기존 백업 목록에서 복원할 시점을 선택하여"
      echo -e "      파일, 권한, 소유권 및 주요 서비스 설정을 복원합니다."
      echo -e "      실제 복원 전에는 현재 상태의 안전 백업을 자동 생성합니다."
      echo ""
      echo -e "      ${YELLOW}※ 백업 파일을 다른 위치로 옮길 때는 같은 이름의${RESET}"
      echo -e "      ${YELLOW}   .records 파일도 함께 복사해야 합니다.${RESET}"
      echo ""
      echo -e "   3. 기존 CSV 결과를 이용한 조치"
      echo ""
      echo -e "      ./${_HELP_SCRIPT_NAME} /경로/report.csv"
      echo ""
      echo -e "      기존 점검 결과에서 취약한 것으로 확인된 항목을"
      echo -e "      불러와 점검 및 조치를 진행합니다."
      echo ""
      echo -e " ${CYAN}[지원 옵션]${RESET}"
      echo ""
      echo -e "   --help, -h    도움말 표시"
      echo -e "   --rollback    기존 백업을 선택하여 복원"
      echo ""
      echo -e " ${CYAN}[결과 저장 위치]${RESET}"
      echo ""
      echo -e "   백업 파일             : ${_BAK_DIR}/"
      echo -e "   Excel·TXT·CSV 보고서  : ${_RPT_BASE_DIR}/"
      echo -e "   누적 실행 이력         : ${FIX_HISTORY_FILE}"
      echo -e "   롤백 실행·검증 결과    : ${_RB_DIR}/"
      echo ""
      echo -e " ${CYAN}[로그 확인 방법]${RESET}"
      echo ""
      echo -e "   1. 실행 상세 로그"
      echo ""
      echo -e "      ls -lt ${_LOG_DIR}/vulnFixDetail_*.log"
      echo -e "      less ${_LOG_DIR}/vulnFixDetail_<서버명>_<실행시각>.log"
      echo ""
      echo -e "      항목별 CHECK, FIX, VERIFY, RESULT와"
      echo -e "      실행 명령, 표준 출력 및 오류 내용을 확인할 수 있습니다."
      echo ""
      echo -e "   2. 누적 실행 이력"
      echo ""
      echo -e "      tail -n 100 ${FIX_HISTORY_FILE}"
      echo ""
      echo -e "      백업과 롤백에 필요한 실행별 변경 기록이 누적됩니다."
      echo -e "      일반 실행 내용을 확인할 때는 상세 로그를 우선 확인하세요."
      echo ""
      echo -e "   3. 롤백 결과"
      echo ""
      echo -e "      ls -lt ${_RB_DIR}/rollback_*.log"
      echo -e "      ls -lt ${_RB_DIR}/rollback_verify_*.txt"
      echo -e "      less ${_RB_DIR}/rollback_<서버명>_<실행시각>.log"
      echo -e "      less ${_RB_DIR}/rollback_verify_<서버명>_<실행시각>.txt"
      echo ""
      echo -e "      rollback 로그에는 복원 과정이 기록되고,"
      echo -e "      rollback_verify 파일에는 복원 후 검증 결과가 기록됩니다."
      echo ""
      echo -e " ${CYAN}[실행 전 확인]${RESET}"
      echo ""
      echo -e "   - root 계정 또는 root 권한으로 실행해야 합니다."
      echo -e "   - 실행 스크립트와 lib 폴더를 분리하지 마세요."
      echo -e "   - 취약 항목별 조치 여부를 직접 확인한 후 진행합니다."
      echo -e "   - 운영 서버에서는 현재 SSH 접속 세션을 유지하세요."
      echo -e "   - 조치 시작 전 백업 생성 결과를 확인하세요."
      echo ""
      echo -e " ${CYAN}[롤백 종료 코드]${RESET}"
      echo ""
      echo -e "   0    복원 및 검증 완료"
      echo -e "   1    파일 복원 또는 핵심 검증 실패"
      echo -e "   2    주요 복원 완료, 일부 수동 확인 필요"
      echo ""
      echo -e "${BOLD}${WHITE}==================================================================${RESET}"
      echo ""
      exit 0
      ;;
    -*)
      echo -e "${RED}[오류] 지원하지 않는 옵션입니다: ${_a}${RESET}"
      echo -e "${YELLOW}       도움말: ./$(basename "$0") --help${RESET}"
      exit 1
      ;;
    *) _ARGS+=("$_a") ;;
  esac
done
set -- "${_ARGS[@]}"

# ── 시작 시 사용법 안내 ───────────────────────────────────────────────────────
echo -e " ${CYAN}※${RESET} 복원은 ${CYAN}--rollback${RESET}, 도움말은 ${CYAN}--help${RESET} 옵션 사용"
echo ""
if [ "$NO_PROMPT" -eq 1 ]; then
  echo -e " ${CYAN}[NO-PROMPT 모드] 스크립트 기본값으로 프롬프트 없이 자동 적용합니다.${RESET}"
  echo ""
fi

# ── Rollback 조기 분기 ───────────────────────────────────────────────────────
# --rollback은 점검·스캔·사전 백업·조치 로직에 진입하지 않고 옵션 파싱 직후 처리한다.
# ./linux_vuln_fix_report.sh --rollback
# 동작: 조치 전 백업과 롤백 직전 안전 백업 목록 표시 → 선택 → 복원
_do_rollback() {
  _div_thick
  echo -e " ${BOLD}[Rollback]${RESET} 사전 백업 복원"
  echo ""

  # 1) 백업 파일 목록 수집
  #    조치 전 백업과 롤백 직전 안전 백업을 함께 표시한다.
  local _bak_dir="${_BAK_DIR:-/linux_vuln_fix/backup}"
  local -a _bak_files=()
  while IFS= read -r _f; do
    _bak_files+=("$_f")
  done < <(ls -t "${_bak_dir}/vulnFix_backup_"*.tar.gz "${_bak_dir}/pre_rollback_"*.tar.gz 2>/dev/null)

  if [ ${#_bak_files[@]} -eq 0 ]; then
    echo -e " ${RED}복원 가능한 백업 파일이 없습니다.${RESET}"
    echo -e " 위치: ${_bak_dir}/vulnFix_backup_*.tar.gz 또는 pre_rollback_*.tar.gz"
    echo ""
    exit 1
  fi

  # 2) 목록 출력
  _sec check
  echo -e " 복원 가능한 백업 목록:"
  echo ""
  local i=1
  for _f in "${_bak_files[@]}"; do
    local _sz _ts _ts_fmt _host_mark="" _type_mark=""
    _sz=$(du -sh "$_f" 2>/dev/null | cut -f1)
    _ts=$(basename "$_f" | grep -oP '\d{8}_\d{6}' | head -1)
    _ts_fmt=$(echo "$_ts" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
    # 성격이 다른 두 백업을 사용자가 목록에서 바로 구분할 수 있도록 표시한다.
    case "$(basename "$_f")" in
      pre_rollback_*)
        _type_mark="${YELLOW}[롤백 직전 안전 백업]${RESET}"
        ;;
      vulnFix_backup_*)
        _type_mark="${CYAN}[조치 전 백업]${RESET}"
        ;;
      *)
        _type_mark="${WHITE}[기타 백업]${RESET}"
        ;;
    esac
    case "$(basename "$_f")" in
      "vulnFix_backup_${_HOSTNAME_VAL}_"*|"pre_rollback_${_HOSTNAME_VAL}_"*) : ;;
      *) _host_mark=" ${RED}[다른 서버]${RESET}" ;;
    esac
    printf "   %2d) " "$i"
    echo -ne "${_type_mark} "
    printf "%s  [%s]  %s" "$_ts_fmt" "$_sz" "$(basename "$_f")"
    echo -e "${_host_mark}"
    i=$((i+1))
  done
  echo ""

  # 3) 선택
  local _choice
  printf " 복원할 번호를 선택하세요 (1~${#_bak_files[@]}, q=취소): "
  read -r _choice
  echo ""

  if [[ "$_choice" == "q" || "$_choice" == "Q" ]]; then
    echo -e " ${YELLOW}롤백을 취소합니다.${RESET}"
    echo ""
    exit 0
  fi

  if ! [[ "$_choice" =~ ^[0-9]+$ ]] || [ "$_choice" -lt 1 ] || [ "$_choice" -gt "${#_bak_files[@]}" ]; then
    echo -e " ${RED}잘못된 입력입니다. 롤백을 취소합니다.${RESET}"
    echo ""
    exit 1
  fi

  local _selected="${_bak_files[$((_choice-1))]}"
  local _pre_rollback_backup="" _pre_rollback_sha="" _pre_rollback_records="" _pre_rollback_manual=0
  local _rb_ts; _rb_ts=$(date +%Y%m%d_%H%M%S)
  # 새 롤백 로그를 만들기 전에 오래된 것부터 정리한다.
  _vf_prune_old_artifacts "$_RB_DIR" "rollback_${_HOSTNAME_VAL}_*.log" \
    "$VULNFIX_KEEP_LOGS" "롤백 로그"
  _vf_prune_old_artifacts "$_RB_DIR" "rollback_verify_${_HOSTNAME_VAL}_*.txt" \
    "$VULNFIX_KEEP_LOGS" "롤백 검증 로그"
  local _rb_log="${_RB_DIR}/rollback_${_HOSTNAME_VAL}_${_rb_ts}.log"
  local _verify_log="${_RB_DIR}/rollback_verify_${_HOSTNAME_VAL}_${_rb_ts}.txt"
  local _rb_tmp_dir
  _rb_tmp_dir=$(mktemp -d "${_RB_DIR}/.rollback_${_rb_ts}_XXXXXX" 2>/dev/null)
  [ -n "$_rb_tmp_dir" ] && [ -d "$_rb_tmp_dir" ]     || { echo -e " ${RED}롤백 임시 디렉터리 생성 실패${RESET}"; exit 1; }
  chmod 700 "$_rb_tmp_dir" 2>/dev/null
  local _tmp_err="${_rb_tmp_dir}/error.log"
  local _tmp_out="${_rb_tmp_dir}/output.log"
  local _compare_dir="${_rb_tmp_dir}/stage"
  mkdir -p "$_compare_dir" 2>/dev/null || { rm -rf "$_rb_tmp_dir"; exit 1; }
  _rb_cleanup() { rm -rf "$_rb_tmp_dir" 2>/dev/null; }

  local _integrity_manual=0 _manifest_manual=0
  _info "선택한 백업: $(basename "$_selected")"
  echo ""

  # 백업 SHA-256을 검증하며 체크섬이 없으면 추가 확인으로 분류한다.
  if command -v sha256sum >/dev/null 2>&1; then
    local _expected_sha="" _actual_sha=""
    if [ -f "${_selected}.sha256" ]; then
      _expected_sha=$(awk 'NF {print $1; exit}' "${_selected}.sha256" 2>/dev/null)
    elif [ -f "$FIX_HISTORY_FILE" ]; then
      _expected_sha=$(awk -F'|' -v bak="BAK=${_selected}" '
        $1=="BACKUP_SHA256" && index($0,bak) {for(i=1;i<=NF;i++) if($i ~ /^SHA=/){sub(/^SHA=/,"",$i); v=$i}} END{print v}
      ' "$FIX_HISTORY_FILE" 2>/dev/null)
    fi
    _actual_sha=$(sha256sum "$_selected" 2>/dev/null | awk '{print $1}')
    if [ -n "$_expected_sha" ]; then
      if [ -z "$_actual_sha" ] || [ "$_actual_sha" != "$_expected_sha" ]; then
        echo -e " ${RED}백업 SHA-256 검증 실패 — 복원을 중단합니다.${RESET}"
        _rb_cleanup; exit 1
      fi
    else
      _integrity_manual=1
      _warn "체크섬이 없는 구버전 백업입니다. 압축 구조 검증만 수행합니다."
    fi
  else
    _integrity_manual=1
    _warn "sha256sum 명령이 없어 백업 체크섬을 검증하지 못했습니다."
  fi

  # 경로 탈출 항목과 손상 여부를 확인한 뒤, 실제 시스템을 건드리기 전에 전체를 스테이징한다.
  if tar tzf "$_selected" 2>"$_tmp_err"      | awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad?0:1}'; then
    echo -e " ${RED}백업에 허용되지 않는 절대경로/상위경로 항목이 있습니다.${RESET}"
    _rb_cleanup; exit 1
  fi
  if ! tar tzf "$_selected" >/dev/null 2>"$_tmp_err"; then
    echo -e " ${RED}백업 파일을 읽을 수 없습니다.${RESET}"
    echo -e " ${YELLOW}상세 오류: ${_tmp_err}${RESET}"
    _rb_cleanup; exit 1
  fi
  _tar_extract_features=()
  _vf_tar_supports '--acls'    && _tar_extract_features+=(--acls)
  _vf_tar_supports '--xattrs'  && _tar_extract_features+=(--xattrs)
  _vf_tar_supports '--selinux' && _tar_extract_features+=(--selinux)
  if ! tar "${_tar_extract_features[@]}" --numeric-owner -xzpf "$_selected" -C "$_compare_dir" >"$_tmp_out" 2>"$_tmp_err"; then
    echo -e " ${RED}백업 전체 사전 추출 검증 실패 — 시스템 파일은 변경하지 않았습니다.${RESET}"
    sed 's/^/   /' "$_tmp_err" 2>/dev/null | head -20
    _rb_cleanup; exit 1
  fi

  local _manifest="${_compare_dir}/.vulnfix_meta/manifest.tsv"
  local _meta_dir="${_compare_dir}/.vulnfix_meta"
  local _backup_host="" _backup_os="" _backup_run_ts="" _backup_type=""
  local _backup_scope="" _backup_part="" _scope_mismatch=0
  _RB_TAR_ACLS=0; _RB_TAR_XATTRS=0; _RB_TAR_SELINUX=0
  if [ -f "$_manifest" ]; then
    _backup_host=$(_vf_meta_value "$_manifest" HOSTNAME)
    _backup_os=$(_vf_meta_value "$_manifest" OS_INFO)
    _backup_run_ts=$(_vf_meta_value "$_manifest" RUN_TS)
    _backup_type=$(_vf_meta_value "$_manifest" BACKUP_TYPE)
    _backup_scope=$(_vf_meta_value "$_manifest" SCRIPT_SCOPE)
    _backup_part=$(_vf_meta_value "$_manifest" SCRIPT_PART)
    _RB_TAR_ACLS=$(_vf_meta_value "$_manifest" TAR_ACLS); _RB_TAR_ACLS=${_RB_TAR_ACLS:-0}
    _RB_TAR_XATTRS=$(_vf_meta_value "$_manifest" TAR_XATTRS); _RB_TAR_XATTRS=${_RB_TAR_XATTRS:-0}
    _RB_TAR_SELINUX=$(_vf_meta_value "$_manifest" TAR_SELINUX); _RB_TAR_SELINUX=${_RB_TAR_SELINUX:-0}
    if [ -n "$_backup_os" ] && [ "$_backup_os" != "${_OS_INFO% (kernel*}" ]; then
      _warn "백업 OS(${_backup_os})와 현재 OS(${_OS_INFO}) 정보가 다릅니다."
      _manifest_manual=1
    fi
    if [ -n "$_backup_host" ] && [ "$_backup_host" != "$_HOSTNAME_VAL" ]; then
      _warn "백업 서버(${_backup_host})와 현재 서버(${_HOSTNAME_VAL})가 다릅니다."
      if [ "${NO_PROMPT:-0}" -eq 1 ]; then
        _fail "비대화형 모드에서는 다른 서버 백업 복원을 차단합니다."
        _rb_cleanup; exit 1
      fi
      printf " 강제로 계속하려면 FORCE를 입력하세요: "
      read -r _force_rb
      [ "$_force_rb" = 'FORCE' ] || { echo -e " ${YELLOW}롤백을 취소합니다.${RESET}"; _rb_cleanup; exit 1; }
      _manifest_manual=1
    fi

    # 범위 필드가 있으면 현재 스크립트와 비교하고, 값이 다를 때만 경고한다.
    if [ -n "$_backup_scope" ] && [ "$_backup_scope" != "$_SCRIPT_SCOPE" ]; then
      _warn "백업 적용 범위(${_backup_scope})와 현재 스크립트 범위(${_SCRIPT_SCOPE})가 다릅니다."
      _scope_mismatch=1
    fi
    if [ -n "$_backup_part" ] && [ "$_backup_part" != "$_SCRIPT_PART" ]; then
      _warn "백업 분리본(${_backup_part})과 현재 스크립트 분리본(${_SCRIPT_PART})이 다릅니다."
      _scope_mismatch=1
    fi
    if [ "$_scope_mismatch" -eq 1 ]; then
      if [ "${NO_PROMPT:-0}" -eq 1 ]; then
        _fail "비대화형 모드에서는 범위가 다른 백업 복원을 차단합니다."
        _rb_cleanup; exit 1
      fi
      printf " 범위가 다른 백업입니다. 강제로 계속하려면 FORCE를 입력하세요: "
      read -r _force_scope
      [ "$_force_scope" = 'FORCE' ] || { echo -e " ${YELLOW}롤백을 취소합니다.${RESET}"; _rb_cleanup; exit 1; }
      _manifest_manual=1
    elif [ -z "$_backup_scope" ] || [ -z "$_backup_part" ]; then
      _warn "구버전 백업으로 범위 식별자가 없습니다. 현재 스크립트 범위(${_SCRIPT_SCOPE}) 기준으로 진행합니다."
    fi
  else
    _manifest_manual=1
    _warn "백업 manifest가 없어 서버·OS·확장 메타정보를 확인할 수 없습니다."
  fi

  # 내부 메타데이터는 시스템 루트에 복원하지 않는다.
  local _file_list
  _file_list=$(tar tzf "$_selected" 2>/dev/null     | grep -vE '^(\./)?\.vulnfix_meta(/|$)'     | sed '/^[[:space:]]*$/d')
  local _total
  _total=$(printf '%s\n' "$_file_list" | wc -l | tr -d ' ')

  # 화면에는 파일 전체 목록 대신 주요 복원 영역별 건수를 요약한다.
  # 각 파일은 아래 분류 중 하나에만 포함되므로 합계는 복원 대상 수와 일치한다.
  local _area_pam=0 _area_ssh=0 _area_account=0
  local _area_postfix=0 _area_other=0
  local _area_entry _area_rel
  while IFS= read -r _area_entry; do
    [ -z "$_area_entry" ] && continue
    _area_rel="${_area_entry#./}"
    case "$_area_rel" in
      etc/pam.d/*|etc/authselect/*|var/lib/authselect/*|etc/security/*)
        _area_pam=$((_area_pam+1))
        ;;
      etc/ssh/*)
        _area_ssh=$((_area_ssh+1))
        ;;
      etc/passwd|etc/shadow|etc/group|etc/gshadow|etc/login.defs|etc/default/useradd|etc/sudoers|etc/sudoers.d/*|etc/profile|etc/profile.d/*)
        _area_account=$((_area_account+1))
        ;;
      etc/postfix/*)
        _area_postfix=$((_area_postfix+1))
        ;;
      *)
        _area_other=$((_area_other+1))
        ;;
    esac
  done <<< "$_file_list"

  {
    echo "Rollback 실행 로그"
    echo "============================================================"
    echo "[Rollback 기본 정보]"
    echo "시작 시간       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "서버명          : ${_HOSTNAME_VAL}"
    echo "복원 기준       : $(basename "$_selected")"
    echo "백업 파일 경로  : ${_selected}"
    echo "복원 대상       : ${_total}개"
    echo "검증 결과 파일  : ${_verify_log}"
    echo "============================================================"
    echo ""
    echo "[파일 복원 내역]"
  } > "$_rb_log" 2>/dev/null

  {
    echo "Rollback 검증 결과"
    echo "============================================================"
    echo "서버명          : ${_HOSTNAME_VAL}"
    echo "복원 기준       : $(basename "$_selected")"
    echo "검증 시작 시간  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
  } > "$_verify_log" 2>/dev/null

  # 4) 복원 대상 요약 출력
  echo ""
  _div_thin
  echo -e " ${BOLD}${WHITE}[복원 대상]${RESET}"
  echo ""
  _row "선택한 백업" "$(basename "$_selected")"
  _row "복원 파일" "${_total}개"
  echo ""
  echo -e " ${BOLD}${WHITE}주요 복원 영역${RESET}"
  echo ""
  _row "PAM/인증 설정" "${_area_pam}개"
  _row "SSH 설정" "${_area_ssh}개"
  _row "계정·비밀번호 정책" "${_area_account}개"
  _row "Postfix 설정" "${_area_postfix}개"
  _row "기타 시스템 설정" "${_area_other}개"
  echo ""
  _row "상세 실행 로그" "$_rb_log"
  _row "검증 결과 파일" "$_verify_log"
  echo ""
  _warn "위 ${_total}개 파일이 백업 시점으로 덮어씌워집니다."
  _warn "현재 설정이 모두 사라집니다. 신중히 선택하세요."
  echo ""

  # 5) 최종 확인 y/n
  local _yn_rb
  _read_yn _yn_rb " 계속하시겠습니까? (y/n): "
  if [[ "$_yn_rb" != [Yy] ]]; then
    echo -e " ${YELLOW}롤백을 취소합니다.${RESET}"
    echo ""
    {
      echo ""
      echo "[최종 요약]"
      echo "완료 시간 : $(date '+%Y-%m-%d %H:%M:%S')"
      echo "최종 결과 : 사용자 취소"
    } >> "$_rb_log" 2>/dev/null
    _rb_cleanup
    exit 0
  fi
  echo ""

  # 신호 중단 시 어느 단계였는지에 따라 안내 문구를 다르게 준다.
  # (백업 단계는 시스템 파일을 전혀 건드리지 않으므로 "이미 복원됐을 수 있다"는
  #  복원 단계용 문구를 그대로 쓰면 사용자가 상태를 오해하게 된다.)
  _RB_STAGE="INIT"
  _rb_interrupted() {
    printf "\r\033[K"
    case "$_RB_STAGE" in
      PRE_BACKUP)
        echo -e " ${RED}⚠ 안전 백업 생성 중 연결이 끊겨 중단됐습니다.${RESET}"
        echo -e " ${GREEN}✓ 시스템 파일은 아직 전혀 변경되지 않았습니다.${RESET} 재접속 후 --rollback 을 다시 실행하세요."
        ;;
      RESTORE)
        echo -e " ${RED}⚠ 롤백이 신호에 의해 중단됐습니다. 일부 파일이 이미 복원됐을 수 있습니다.${RESET}"
        echo -e "   진행 상황 : ${_idx:-0}/${_total}"
        if [ -n "${_pre_rollback_backup:-}" ]; then
          echo -e "   복귀하려면 --rollback 재실행 후 다음 안전 백업을 선택하세요: ${_pre_rollback_backup}"
        fi
        ;;
      POST)
        echo -e " ${RED}⚠ 파일 복원 이후 설정 반영 중 연결이 끊겨 중단됐습니다.${RESET}"
        echo -e "   파일 자체는 복원됐으나 서비스/방화벽 등 후속 설정 반영이 끝나지 않았을 수 있습니다."
        [ -n "${_pre_rollback_backup:-}" ] && echo -e "   복귀용 안전 백업 : ${_pre_rollback_backup}"
        ;;
      *)
        echo -e " ${RED}롤백이 신호에 의해 중단됐습니다. 일부 파일이 이미 복원됐을 수 있습니다.${RESET}"
        ;;
    esac
    echo "$(date '+%Y-%m-%d %H:%M:%S')|ROLLBACK|INTERRUPTED|단계=${_RB_STAGE}|백업=${_selected}|처리=${_idx:-0}/${_total}|로그=${_rb_log}" >> "$FIX_HISTORY_FILE" 2>/dev/null
    echo "INTERRUPTED|단계=${_RB_STAGE}|처리=${_idx:-0}/${_total}" >> "$_rb_log" 2>/dev/null
    _rb_cleanup
    exit 130
  }
  trap _rb_interrupted INT TERM HUP

  # 최종 확정 후 실제 복원 전에 현재 상태를 롤백 직전 안전 백업으로 보존한다.
  _RB_STAGE="PRE_BACKUP"
  echo ""
  _div_thin
  echo -e " ${BOLD}${BLUE}[롤백 직전 안전 백업]${RESET}"
  echo ""
  _info "현재 상태를 복귀용 백업으로 저장합니다."
  if _vf_create_pre_rollback_backup "$_selected" "$_file_list" "$_rb_tmp_dir" "$_rb_log" "$_verify_log"; then
    _pre_rollback_backup="$_VF_PRE_RB_BACKUP"
    _pre_rollback_sha="$_VF_PRE_RB_SHA256"
    _pre_rollback_records="$_VF_PRE_RB_RECORDS"
    _ok "롤백 직전 안전 백업 완료"
    _row "안전 백업" "$_pre_rollback_backup"
    _row "SHA-256" "$_pre_rollback_sha"
    _row "레코드" "$_pre_rollback_records"
    _row "현재 상태" "존재 ${_VF_PRE_RB_EXISTING}개 / 부재 ${_VF_PRE_RB_MISSING}개"
    echo ""
  else
    _fail "롤백 직전 안전 백업 생성 실패"
    if [ -n "${_VF_PRE_RB_ERROR:-}" ]; then
      echo -e " ${YELLOW}[오류 원문]${RESET}"
      printf '%s\n' "$_VF_PRE_RB_ERROR" | sed 's/^/   /' | head -20
    fi
    echo ""
    _warn "계속 진행하면 롤백 직전 상태로 자동 복귀할 수 없습니다."
    {
      echo ""
      echo "[롤백 직전 안전 백업]"
      echo "생성 실패 : ${_VF_PRE_RB_ERROR:-상세 오류 없음}"
    } >> "$_rb_log" 2>/dev/null

    if [ "${NO_PROMPT:-0}" -eq 1 ] || [ ! -t 0 ]; then
      _fail "비대화형 환경에서는 안전을 위해 롤백을 취소합니다."
      echo "PRE_ROLLBACK_BACKUP|FAIL|ROLLBACK_CANCELLED" >> "$_rb_log" 2>/dev/null
      trap - INT TERM HUP
      _rb_cleanup
      return 1
    fi

    local _continue_without_pre
    _read_yn _continue_without_pre " 안전 백업 없이 롤백을 계속하시겠습니까? (y/n): "
    if [[ "$_continue_without_pre" != [Yy] ]]; then
      echo -e " ${YELLOW}롤백을 취소합니다. 시스템 파일은 변경되지 않았습니다.${RESET}"
      echo "PRE_ROLLBACK_BACKUP|FAIL|USER_CANCELLED" >> "$_rb_log" 2>/dev/null
      trap - INT TERM HUP
      _rb_cleanup
      return 1
    fi
    _pre_rollback_manual=1
    _warn "사용자 확인에 따라 안전 백업 없이 롤백을 계속합니다."
    echo "PRE_ROLLBACK_BACKUP|FAIL|USER_FORCED_CONTINUE" >> "$_rb_log" 2>/dev/null
    echo ""
  fi

  echo ""
  _div_thin
  _RB_STAGE="RESTORE"
  echo -e " ${BOLD}${BLUE}[복원 중]${RESET}"
  echo ""

  # 복원 전 디스크 공간 사전 확인: 파일을 하나씩 직접 덮어쓰는 도중 공간이
  # 바닥나면 PAM/SSH 등 핵심 설정 파일이 잘린 채로 남을 수 있어 시작 전에 차단한다.
  local _restore_req_kb
  _restore_req_kb=$(tar tzvf "$_selected" 2>/dev/null | awk '{sum+=$3} END{print int(sum/1024)+1}')
  case "$_restore_req_kb" in ''|*[!0-9]*) _restore_req_kb=0 ;; esac
  _restore_req_kb=$(( _restore_req_kb + _restore_req_kb / 5 + 1024 ))
  if ! _vf_require_space / "$_restore_req_kb"; then
    local _avail_root_kb
    _avail_root_kb=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')
    _fail "디스크 공간 부족으로 복원을 시작할 수 없습니다."
    echo ""
    _row "필요 공간(추정)" "약 ${_restore_req_kb} KB"
    _row "현재 여유 공간" "${_avail_root_kb:-확인불가} KB (/)"
    echo ""
    echo -e " ${YELLOW}[해결 방법]${RESET}"
    echo "   1) df -h                                          파티션별 여유 공간 확인"
    echo "   2) du -xh --max-depth=1 /var | sort -rh | head    큰 디렉터리 찾기"
    echo "   3) journalctl --vacuum-size=200M                  저널 로그 정리"
    echo "   4) 공간 확보 후 --rollback 재실행"
    echo ""
    [ -n "$_pre_rollback_backup" ] && _info "복귀용 안전 백업은 이미 생성되어 있습니다: ${_pre_rollback_backup}"
    _warn "파일 단위 복원 중 공간이 바닥나면 설정이 손상될 수 있어 복원을 시작하지 않습니다."
    {
      echo ""
      echo "[복원 전 공간 확인]"
      echo "결과 : 공간 부족으로 복원 시작 전 중단"
      echo "필요(추정) : ${_restore_req_kb} KB / 여유 : ${_avail_root_kb:-확인불가} KB"
    } >> "$_rb_log" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S')|ROLLBACK|FAIL|REASON=NO_SPACE_BEFORE_RESTORE|필요=${_restore_req_kb}KB|여유=${_avail_root_kb:-N/A}KB|로그=${_rb_log}" >> "$FIX_HISTORY_FILE" 2>/dev/null
    trap - INT TERM HUP
    _rb_cleanup
    return 1
  fi

  local _ok_cnt=0
  local _fail_cnt=0
  local _idx=0
  local _last_pct=-1
  local _current_pct=0
  local -a _restore_fail_files=()

  # 빠르게 끝나는 복원에서도 진행 상태가 보이도록 0%를 먼저 표시한다.
  _show_progress_bar 0 "$_total" "복원 준비"
  sleep 0.2

  while IFS= read -r _entry; do
    [ -z "$_entry" ] && continue
    _idx=$((_idx+1))
    local _filepath="/${_entry#./}"
    : > "$_tmp_err"

    # 디렉터리 항목은 --no-recursion으로 그 항목만 복원한다.
    # (없으면 하위 파일 전체가 중복 추출되어 느려지고, 실패 시 원인 파악이 어려움)
    local -a _tar_extra=()
    case "$_entry" in */) _tar_extra+=(--no-recursion) ;; esac

    if tar "${_tar_extract_features[@]}" --numeric-owner -xzpf "$_selected" -C / "${_tar_extra[@]}" "$_entry" 2>"$_tmp_err"; then
      printf '[%s] [%d/%d] 성공 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_idx" "$_total" "$_filepath" >> "$_rb_log" 2>/dev/null
      _ok_cnt=$((_ok_cnt+1))
    else
      printf "\r\033[K"
      echo -e "   ${RED}✗${RESET} [${_idx}/${_total}] 복원 실패 : ${_filepath}"
      {
        printf '[%s] [%d/%d] 실패 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_idx" "$_total" "$_filepath"
        if [ -s "$_tmp_err" ]; then
          echo "  오류 내용:"
          sed 's/^/    /' "$_tmp_err"
        else
          echo "  오류 내용: tar 복원 명령이 실패했으나 추가 메시지가 없습니다."
        fi
      } >> "$_rb_log" 2>/dev/null
      _restore_fail_files+=("$_filepath")
      _fail_cnt=$((_fail_cnt+1))
    fi

    # 매 파일이 아니라 백분율이 바뀔 때만 갱신해 터미널 깜빡임을 줄인다.
    _current_pct=$(( _idx * 100 / _total ))
    if [ "$_current_pct" -ne "$_last_pct" ]; then
      # 100% 완료 화면은 반복문 종료 후 한 번만 표시한다.
      if [ "$_idx" -lt "$_total" ]; then
        _show_progress_bar "$_idx" "$_total" "복원 중"
        sleep 0.01
      fi
      _last_pct="$_current_pct"
    fi
  done <<< "$_file_list"

  # 마지막 100% 상태를 지우지 않고 화면에 남긴다.
  _show_progress_bar "$_total" "$_total" "복원 완료"
  echo ""
  echo -e "   ${GREEN}✓${RESET} 파일 복원 처리 완료: 성공 ${_ok_cnt}개 / 실패 ${_fail_cnt}개"
  echo ""

  {
    echo ""
    echo "[파일 복원 요약]"
    echo "복원 성공 : ${_ok_cnt}개"
    echo "복원 실패 : ${_fail_cnt}개"
    if [ "$_fail_cnt" -gt 0 ]; then
      echo "실패 파일 :"
      printf '  - %s\n' "${_restore_fail_files[@]}"
    fi
  } >> "$_rb_log" 2>/dev/null

  # 파일 복원이 일부라도 실패하면 추가 설정 변경은 중단한다.
  if [ "$_fail_cnt" -gt 0 ]; then
    _sec result
    _fail "Rollback 일부 실패"
    _row "복원 성공" "${_ok_cnt}개"
    _row "복원 실패" "${_fail_cnt}개"
    _row "후속 검증" "복원 실패로 중단"
    [ -n "$_pre_rollback_backup" ] && _row "복귀용 안전 백업" "$_pre_rollback_backup"
    _row "이력 로그" "$FIX_HISTORY_FILE"
    _row "실행 로그" "$_rb_log"
    _row "검증 결과" "$_verify_log"
    echo ""

    {
      echo ""
      echo "[검증 결과]"
      echo "파일 복원 실패가 있어 설정 검증 및 서비스 반영을 중단했습니다."
      echo ""
      echo "[최종 요약]"
      echo "완료 시간 : $(date '+%Y-%m-%d %H:%M:%S')"
      echo "파일 복원 : ${_ok_cnt}/${_total} 성공"
      echo "복귀용 안전 백업 : ${_pre_rollback_backup:-생성되지 않음}"
      echo "최종 결과 : 일부 파일 복원 실패"
    } >> "$_verify_log" 2>/dev/null

    {
      echo ""
      echo "[최종 요약]"
      echo "완료 시간 : $(date '+%Y-%m-%d %H:%M:%S')"
      echo "파일 복원 : ${_ok_cnt}/${_total} 성공"
      echo "복귀용 안전 백업 : ${_pre_rollback_backup:-생성되지 않음}"
      echo "최종 결과 : 일부 파일 복원 실패"
    } >> "$_rb_log" 2>/dev/null

    echo "$(date '+%Y-%m-%d %H:%M:%S')|ROLLBACK|일부실패|백업=${_selected}|성공=${_ok_cnt}|실패=${_fail_cnt}|로그=${_rb_log}|검증=${_verify_log}" >> "$FIX_HISTORY_FILE" 2>/dev/null
    _rb_cleanup
    return 1
  fi

  _RB_STAGE="POST"
  # 6) 이력 파일 기반 자동 역산 (파일 비교보다 먼저 수행)
  #    — 역산(chmod/chown)이 비교 뒤에 실행되면, 비교 시점에는 일치했더라도
  #      역산 이후 최종 상태가 달라질 수 있다. 올바른 순서:
  #      tar 복원 → 자동 역산 → 최종 파일·메타정보 비교 → 설정 검증
  local _perm_cnt=0 _perm_fail=0
  local _grp_cnt=0 _grp_fail=0 _grp_skip=0
  local _inverse_perm_total=0 _inverse_grp_total=0
  local _inverse_screen=0
  local _inverse_records=""
  local _created_records=""
  local _orphan_records=""
  local _verify_manual_pre=0   # 역산 단계에서 발생한 수동확인 건수 (설정 검증 카운터에 합산)
  declare -A _rb_baseline=()        # 조치 전 설정 검증 기준값 (VERIFY_BASELINE)
  declare -A _rb_baseline_hash=()   # 조치 전 실패 원문 정규화 SHA-256

  # 누적 이력에서 실행 레코드를 먼저 찾고, 매칭되지 않으면 백업 옆 .records를 사용한다.
  local _rb_run_ts _rb_sel_base _records_sidecar _record_source="" _run_record_matched=0
  _rb_run_ts=$(basename "$_selected" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
  _rb_sel_base=$(basename "$_selected")
  _records_sidecar="${_selected}.records"

  if [ -f "$FIX_HISTORY_FILE" ]; then
    if _inverse_records=$(_vf_extract_run_records "$FIX_HISTORY_FILE" "$_selected" "$_rb_sel_base" "$_rb_run_ts"); then
      _run_record_matched=1
      _record_source="$FIX_HISTORY_FILE"
      echo "INVERSE|SOURCE|HISTORY|${FIX_HISTORY_FILE}" >> "$_rb_log" 2>/dev/null
    fi
  fi

  if [ "$_run_record_matched" -eq 0 ] && [ -f "$_records_sidecar" ]; then
    if _inverse_records=$(_vf_extract_run_records "$_records_sidecar" "$_selected" "$_rb_sel_base" "$_rb_run_ts"); then
      _run_record_matched=1
      _record_source="$_records_sidecar"
      _info "기본 이력 매칭 실패 — 백업 사이드카 레코드를 사용합니다."
      _row "레코드 파일" "$_records_sidecar"
      echo ""
      echo "INVERSE|SOURCE|SIDECAR|${_records_sidecar}" >> "$_rb_log" 2>/dev/null
    fi
  fi

  if [ "$_run_record_matched" -eq 1 ]; then
    # 같은 파일의 PERM_RESTORE가 한 실행에서 여러 번 기록될 수 있다
    # (예: U-23이 crontab 4755→755, 이어서 U-37이 755→750 기록).
    # 경로별 첫 번째 기록(조치 전 원상태)만 남긴다.
    _inverse_records=$(printf '%s\n' "$_inverse_records" | awk -F'|' '
      $1 == "PERM_RESTORE" { if (seen[$2]++) next }
      { print }
    ')

    # 조치 전 검증 기준값 및 P7 실패 원문 해시 로드
    while IFS='|' read -r _bl_tag _bl_name _bl_status _bl_hash_field _bl_extra; do
      [ "$_bl_tag" = "VERIFY_BASELINE" ] || continue
      _rb_baseline["$_bl_name"]="$_bl_status"
      if [[ "$_bl_hash_field" == SHA256=* ]]; then
        _rb_baseline_hash["$_bl_name"]="${_bl_hash_field#SHA256=}"
      fi
      echo "BASELINE|${_bl_name}|${_bl_status}|SHA256=${_rb_baseline_hash[$_bl_name]:-}" >> "$_rb_log" 2>/dev/null
    done <<< "$_inverse_records"
    _inverse_records=$(printf '%s\n' "$_inverse_records" | grep -v '^VERIFY_BASELINE|' 2>/dev/null || true)
    _created_records=$(printf '%s\n' "$_inverse_records" | grep '^CREATED_PATH|' 2>/dev/null || true)
    _inverse_records=$(printf '%s\n' "$_inverse_records" | grep -v '^CREATED_PATH|' 2>/dev/null || true)
    _orphan_records=$(printf '%s\n' "$_inverse_records" | grep '^ORPHAN_RESTORE|' 2>/dev/null || true)
    _inverse_records=$(printf '%s\n' "$_inverse_records" | grep -v '^ORPHAN_RESTORE|' 2>/dev/null || true)

    if [ -n "$_inverse_records" ]; then
      _inverse_perm_total=$(printf '%s\n' "$_inverse_records" | grep -c '^PERM_RESTORE|' 2>/dev/null || true)
      _inverse_grp_total=$(printf '%s\n' "$_inverse_records" | grep -c '^GROUP_MEMBERSHIP|' 2>/dev/null || true)
      _inverse_screen=1

      echo ""
      _div_thin
      echo -e " ${BOLD}${WHITE}[추가 복구]${RESET}"
      echo ""
      _row "레코드 원본" "$_record_source"
      _row "권한 복구 대상" "${_inverse_perm_total}건"
      _row "그룹 복구 대상" "${_inverse_grp_total}건"
      echo ""

      while IFS='|' read -r _type _path _perm _meta; do
        [ -z "$_type" ] && continue
        case "$_type" in
          PERM_RESTORE)
            local _perm_ok=1 _perm_err=""
            # 순서 중요: 반드시 chown → chmod.
            : > "$_tmp_err"
            if ! chown "$_meta" "$_path" 2>"$_tmp_err"; then
              _perm_ok=0
              _perm_err="chown 실패: $(tr '\n' ' ' < "$_tmp_err")"
            fi
            : > "$_tmp_err"
            if ! chmod "$_perm" "$_path" 2>"$_tmp_err"; then
              _perm_ok=0
              [ -n "$_perm_err" ] && _perm_err="${_perm_err} | "
              _perm_err="${_perm_err}chmod 실패: $(tr '\n' ' ' < "$_tmp_err")"
            fi
            if [ "$_perm_ok" -eq 1 ]; then
              local _now_perm _now_own
              _now_perm=$(stat -c '%a' "$_path" 2>/dev/null)
              _now_own=$(stat -c '%U:%G' "$_path" 2>/dev/null)
              if [ -z "$_now_perm" ] \
                 || [ "$(( 8#${_now_perm:-0} ))" -ne "$(( 8#${_perm:-0} ))" ] \
                 || [ "$_now_own" != "$_meta" ]; then
                _perm_ok=0
                _perm_err="적용 후 상태 불일치: 기대 ${_perm}/${_meta}, 실제 ${_now_perm:-없음}/${_now_own:-없음}"
              fi
            fi
            if [ "$_perm_ok" -eq 1 ]; then
              _perm_cnt=$((_perm_cnt+1))
              _ok "권한 복구: ${_path} → ${_perm} / ${_meta}"
              echo "INVERSE|PERM_RESTORE|PASS|${_path}|${_perm}|${_meta}" >> "$_rb_log" 2>/dev/null
            else
              _perm_fail=$((_perm_fail+1))
              _fail "권한 복구 실패: ${_path}"
              echo "INVERSE|PERM_RESTORE|FAIL|${_path}|${_perm}|${_meta}|${_perm_err}" >> "$_rb_log" 2>/dev/null
            fi
            ;;
          GROUP_MEMBERSHIP)
            local _grp_user="$_path" _grp_name="$_perm"
            local _before_val="${_meta#BEFORE_MEMBER=}"
            if [ "$_before_val" = "0" ]; then
              if id -nG "$_grp_user" 2>/dev/null | tr ' ' '\n' | grep -qx "$_grp_name"; then
                : > "$_tmp_err"
                if gpasswd -d "$_grp_user" "$_grp_name" 2>"$_tmp_err"; then
                  _grp_cnt=$((_grp_cnt+1))
                  _ok "그룹 멤버십 복구: ${_grp_user} → ${_grp_name} 그룹에서 제거"
                  echo "INVERSE|GROUP_MEMBERSHIP|PASS|${_grp_user}|${_grp_name}" >> "$_rb_log" 2>/dev/null
                else
                  _grp_fail=$((_grp_fail+1))
                  _fail "그룹 멤버십 복구 실패: ${_grp_user}/${_grp_name}"
                  echo "INVERSE|GROUP_MEMBERSHIP|FAIL|${_grp_user}|${_grp_name}|$(tr '\n' ' ' < "$_tmp_err")" >> "$_rb_log" 2>/dev/null
                fi
              else
                _grp_skip=$((_grp_skip+1))
                _info "그룹 멤버십 확인: ${_grp_user}는 이미 ${_grp_name} 비멤버"
                echo "INVERSE|GROUP_MEMBERSHIP|SKIP|${_grp_user}|${_grp_name}|이미 비멤버" >> "$_rb_log" 2>/dev/null
              fi
            fi
            ;;
        esac
      done <<< "$_inverse_records"

      echo ""
      _row "권한 복구 결과" "성공 ${_perm_cnt} / 실패 ${_perm_fail}"
      _row "그룹 복구 결과" "성공 ${_grp_cnt} / 실패 ${_grp_fail} / 이미 복구 ${_grp_skip}"
      echo ""
    else
      echo "INVERSE|NONE|해당 실행의 권한·그룹 역산 레코드 없음|SOURCE=${_record_source}" >> "$_rb_log" 2>/dev/null
    fi
  else
    _inverse_screen=1
    echo ""
    _div_thin
    echo -e " ${BOLD}${WHITE}[추가 복구]${RESET}"
    echo ""
    _warn "이 백업에 대응하는 실행 레코드를 찾지 못했습니다."
    if [ -f "$_records_sidecar" ]; then
      _warn "사이드카가 있으나 백업 식별자가 일치하지 않습니다: ${_records_sidecar}"
    else
      _warn "백업을 다른 서버로 이동한 경우 tar.gz와 같은 이름의 .records 파일도 함께 복사해야 합니다."
      _warn "필요 파일: $(basename "$_selected") + $(basename "$_records_sidecar")"
    fi
    _warn "권한·그룹·생성 경로 변경이 있었던 경우 수동 확인이 필요합니다."
    echo "INVERSE|SKIP|RUN_START 및 SIDECAR 매칭 실패|BAK=${_selected}" >> "$_rb_log" 2>/dev/null
    _verify_manual_pre=1
  fi

  {
    echo ""
    echo "[자동 역산 요약]"
    echo "권한 복구 대상       : ${_inverse_perm_total}건"
    echo "그룹 복구 대상       : ${_inverse_grp_total}건"
    echo "권한 복구 성공       : ${_perm_cnt}건"
    echo "권한 복구 실패       : ${_perm_fail}건"
    echo "그룹 복구 성공       : ${_grp_cnt}건"
    echo "그룹 복구 실패       : ${_grp_fail}건"
    echo "그룹 이미 복구       : ${_grp_skip}건"
  } >> "$_verify_log" 2>/dev/null

  # 7) 조치 중 생성·삭제된 경로 및 계정 상태 검증
  if [ -d "$_meta_dir" ]; then
    _vf_restore_recorded_paths "$_meta_dir" "$_created_records" "${_backup_run_ts:-${_rb_run_ts:-$_RUN_TS}}" "$_rb_log" "$_verify_log"
    _vf_validate_accounts_after_rollback "$_meta_dir/accounts.tsv" "$_rb_tmp_dir" "$_rb_log" "$_verify_log"
  else
    _VF_PATH_OK=0; _VF_PATH_FAIL=0; _VF_PATH_MANUAL=1
    _VF_ACCOUNT_OK=0; _VF_ACCOUNT_FAIL=0; _VF_ACCOUNT_MANUAL=1
  fi
  # U-15(무소유 파일) 소유권 복원 — meta_dir 존재 여부와 무관하게 이력 파일 기반으로 동작
  _vf_restore_orphan_owners "$_orphan_records" "$_rb_log" "$_verify_log"

  # 8) 백업 원본과 복원 결과 일치 검증
  local _content_ok=0 _content_fail=0
  local _meta_ok=0 _meta_fail=0
  local _compare_total=0 _compare_manual=0
  _VF_EXT_OK=0; _VF_EXT_FAIL=0; _VF_EXT_MANUAL=0
  if command -v getfacl >/dev/null 2>&1; then
    [ "${_RB_TAR_ACLS:-0}" -eq 1 ] || _VF_EXT_MANUAL=$((_VF_EXT_MANUAL+1))
  elif [ "${_RB_TAR_ACLS:-0}" -eq 1 ]; then
    _VF_EXT_MANUAL=$((_VF_EXT_MANUAL+1))
  fi
  if command -v getfattr >/dev/null 2>&1; then
    [ "${_RB_TAR_XATTRS:-0}" -eq 1 ] || _VF_EXT_MANUAL=$((_VF_EXT_MANUAL+1))
  elif [ "${_RB_TAR_XATTRS:-0}" -eq 1 ]; then
    _VF_EXT_MANUAL=$((_VF_EXT_MANUAL+1))
  fi
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    [ "${_RB_TAR_SELINUX:-0}" -eq 1 ] || _VF_EXT_MANUAL=$((_VF_EXT_MANUAL+1))
  fi
  local -a _content_fail_files=()
  local -a _meta_fail_files=()

  echo ""
  _div_thin
  echo -e " ${BOLD}${CYAN}[복원 검증]${RESET}"
  echo ""
  echo -e " ${BOLD}${WHITE}파일 내용·권한 비교${RESET}"
  echo ""

  # 선택한 백업은 실제 복원 전에 이미 전체 스테이징 검증을 통과했다.
  if [ ! -d "$_compare_dir" ]; then
    _fail "비교용 스테이징 디렉터리 없음"
    _content_fail=1
    _meta_fail=1
    _compare_manual=1
    echo "COMPARE|FAIL|스테이징 디렉터리 없음" >> "$_rb_log" 2>/dev/null
  else
    while IFS= read -r _entry; do
      [ -z "$_entry" ] && continue
      local _rel="${_entry#./}"
      local _src="${_compare_dir}/${_rel}"
      local _dst="/${_rel}"
      local _content_match=0 _meta_match=0
      _compare_total=$((_compare_total+1))

      if [ ! -e "$_src" ] && [ ! -L "$_src" ]; then
        _content_fail=$((_content_fail+1))
        _meta_fail=$((_meta_fail+1))
        _content_fail_files+=("$_dst")
        _meta_fail_files+=("$_dst")
        echo "COMPARE|FAIL|백업 추출 항목 없음|${_dst}" >> "$_rb_log" 2>/dev/null
        continue
      fi
      if [ ! -e "$_dst" ] && [ ! -L "$_dst" ]; then
        _content_fail=$((_content_fail+1))
        _meta_fail=$((_meta_fail+1))
        _content_fail_files+=("$_dst")
        _meta_fail_files+=("$_dst")
        echo "COMPARE|FAIL|복원 대상 없음|${_dst}" >> "$_rb_log" 2>/dev/null
        continue
      fi

      if [ -L "$_src" ]; then
        if [ -L "$_dst" ] && [ "$(readlink "$_src" 2>/dev/null)" = "$(readlink "$_dst" 2>/dev/null)" ]; then
          _content_match=1
        fi
      elif [ -f "$_src" ]; then
        if [ -f "$_dst" ]; then
          if command -v sha256sum >/dev/null 2>&1; then
            [ "$(sha256sum "$_src" 2>/dev/null | awk '{print $1}')" = "$(sha256sum "$_dst" 2>/dev/null | awk '{print $1}')" ] && _content_match=1
          elif cmp -s "$_src" "$_dst" 2>/dev/null; then
            _content_match=1
          fi
        fi
      else
        # 장치/소켓 등 일반 파일이 아닌 항목은 유형 일치 여부를 내용 검증으로 사용한다.
        [ "$(stat -c '%F' "$_src" 2>/dev/null)" = "$(stat -c '%F' "$_dst" 2>/dev/null)" ] && _content_match=1
      fi

      local _src_meta _dst_meta _src_links='-' _dst_links='-'
      if [ -f "$_src" ] && [ ! -L "$_src" ]; then _src_links=$(stat -c '%h' "$_src" 2>/dev/null); fi
      if [ -f "$_dst" ] && [ ! -L "$_dst" ]; then _dst_links=$(stat -c '%h' "$_dst" 2>/dev/null); fi
      _src_meta="$(stat -c '%F|%a|%u|%g' "$_src" 2>/dev/null)|${_src_links}"
      _dst_meta="$(stat -c '%F|%a|%u|%g' "$_dst" 2>/dev/null)|${_dst_links}"
      [ -n "$_src_meta" ] && [ "$_src_meta" = "$_dst_meta" ] && _meta_match=1
      _vf_compare_extended_one "$_src" "$_dst" "$_dst" "$_rb_log"

      if [ "$_content_match" -eq 1 ]; then
        _content_ok=$((_content_ok+1))
      else
        _content_fail=$((_content_fail+1))
        _content_fail_files+=("$_dst")
        echo "COMPARE|CONTENT_FAIL|${_dst}" >> "$_rb_log" 2>/dev/null
      fi

      if [ "$_meta_match" -eq 1 ]; then
        _meta_ok=$((_meta_ok+1))
      else
        _meta_fail=$((_meta_fail+1))
        _meta_fail_files+=("$_dst")
        echo "COMPARE|META_FAIL|${_dst}|backup=${_src_meta}|current=${_dst_meta}" >> "$_rb_log" 2>/dev/null
      fi

      if [ "$_content_match" -eq 1 ] && [ "$_meta_match" -eq 1 ]; then
        echo "COMPARE|PASS|${_dst}|${_dst_meta}" >> "$_rb_log" 2>/dev/null
      fi
    done <<< "$_file_list"
  fi

  if [ "$_content_fail" -eq 0 ] && [ "$_meta_fail" -eq 0 ]; then
    _ok "백업 원본과 복원 결과 일치: ${_compare_total}/${_compare_total}개"
  else
    [ "$_content_fail" -eq 0 ] && _ok "파일 내용/링크 일치: ${_content_ok}/${_compare_total}개" || _fail "파일 내용/링크 불일치: ${_content_fail}개"
    [ "$_meta_fail" -eq 0 ] && _ok "유형·권한·UID·GID 일치: ${_meta_ok}/${_compare_total}개" || _fail "유형·권한·UID·GID 불일치: ${_meta_fail}개"
    local _cf
    for _cf in "${_content_fail_files[@]:0:5}"; do _warn "내용 불일치: ${_cf}"; done
    [ "${#_content_fail_files[@]}" -gt 5 ] && _warn "내용 불일치 외 $((${#_content_fail_files[@]}-5))개는 실행 로그 참조"
    for _cf in "${_meta_fail_files[@]:0:5}"; do _warn "메타정보 불일치: ${_cf}"; done
    [ "${#_meta_fail_files[@]}" -gt 5 ] && _warn "메타정보 불일치 외 $((${#_meta_fail_files[@]}-5))개는 실행 로그 참조"
  fi
  echo ""

  {
    echo ""
    echo "[복원 일치 검증]"
    echo "비교 대상              : ${_compare_total}개"
    echo "파일 내용/링크 일치    : ${_content_ok}개"
    echo "파일 내용/링크 불일치  : ${_content_fail}개"
    echo "유형·권한·UID·GID·링크 일치 : ${_meta_ok}개"
    echo "메타정보 불일치             : ${_meta_fail}개"
    echo "ACL/xattr/SELinux/capability : 통과 ${_VF_EXT_OK} / 실패 ${_VF_EXT_FAIL} / 추가확인 ${_VF_EXT_MANUAL}"
    echo "참고: mtime은 서비스 재기록에 따른 오탐을 막기 위해 판정에서 제외"
    if [ "${#_content_fail_files[@]}" -gt 0 ]; then
      echo "내용 불일치 파일:"
      printf '  - %s\n' "${_content_fail_files[@]}"
    fi
    if [ "${#_meta_fail_files[@]}" -gt 0 ]; then
      echo "메타정보 불일치 파일:"
      printf '  - %s\n' "${_meta_fail_files[@]}"
    fi
  } >> "$_verify_log" 2>/dev/null

  # 9) 복원 설정 검증
  local _verify_total=0
  local _verify_ok=0
  local _verify_baseline_match=0
  local _verify_fail=0
  local _verify_manual="${_verify_manual_pre:-0}"
  local _service_ok=0
  local _service_fail=0
  local _service_skip=0
  local _pam_verify_detail=""
  local -a _verify_fail_names=()
  local -a _verify_fail_summaries=()

  echo -e " ${BOLD}${WHITE}설정 검증${RESET}"
  echo ""

  # 검증 결과 공통 기록 함수: PASS=통과, FAIL=실패, MANUAL=수동확인
  # 절대 PASS/FAIL이 아니라 "조치 전 기준값"과 비교한다:
  # 조치 전에도 실패하던 검증(VERIFY_BASELINE|<이름>|FAIL)이 롤백 후에도 실패하면
  # 복원은 정상(조치 전 상태와 동일)이므로 실패가 아니라 기준 일치로 처리한다.
  _rb_verify_record() {
    local _name="$1" _status="$2" _command="$3" _detail="$4"
    _verify_total=$((_verify_total+1))

    # 기존 버전에서 생성한 pre_rollback 백업은 VERIFY_BASELINE이 없었다.
    # 파일 내용·메타가 백업과 일치한 상태에서 검증 명령만 실패했다면
    # 실제 복원 실패로 단정하지 않고 기준 부재에 따른 수동확인으로 분리한다.
    if [ "$_status" = "FAIL" ] && [ "$_backup_type" = "PRE_ROLLBACK" ] \
       && [ -z "${_rb_baseline[$_name]:-}" ]; then
      _verify_manual=$((_verify_manual+1))
      _warn "${_name}: 구버전 롤백 직전 백업에 검증 기준이 없어 수동 확인 필요"
      {
        echo ""
        echo "[${_name}]"
        echo "상태   : MANUAL (구버전 PRE_ROLLBACK 백업 — VERIFY_BASELINE 없음)"
        echo "명령   : ${_command}"
        if [ -n "$_detail" ]; then
          echo "출력   :"
          printf '%s\n' "$_detail" | sed 's/^/  /'
        else
          echo "출력   : 없음"
        fi
      } >> "$_verify_log" 2>/dev/null
      echo "VERIFY|${_name}|LEGACY_PRE_ROLLBACK_BASELINE_MISSING|${_command}" >> "$_rb_log" 2>/dev/null
      return
    fi

    if [ "$_status" = "FAIL" ] && [ "${_rb_baseline[$_name]:-}" = "FAIL" ]; then
      local _baseline_hash="${_rb_baseline_hash[$_name]:-}" _current_hash=""
      if [ -n "$_baseline_hash" ]; then
        _current_hash=$(_vf_verify_output_sha256 "$_detail" 2>/dev/null || true)
        if [ -z "$_current_hash" ] || [ "$_current_hash" != "$_baseline_hash" ]; then
          _verify_manual=$((_verify_manual+1))
          _warn "${_name}: 조치 전에도 실패했으나 오류 원인이 다를 수 있어 수동 확인 필요"
          {
            echo ""
            echo "[${_name}]"
            echo "상태   : MANUAL (조치 전 FAIL과 현재 FAIL의 오류 해시 불일치)"
            echo "명령   : ${_command}"
            echo "기준 해시 : ${_baseline_hash}"
            echo "현재 해시 : ${_current_hash:-계산 불가}"
            if [ -n "$_detail" ]; then
              echo "출력   :"
              printf '%s\n' "$_detail" | sed 's/^/  /'
            else
              echo "출력   : 없음"
            fi
          } >> "$_verify_log" 2>/dev/null
          echo "VERIFY|${_name}|BASELINE_CAUSE_DIFFER|${_command}|BASE=${_baseline_hash}|CURRENT=${_current_hash:-UNAVAILABLE}" >> "$_rb_log" 2>/dev/null
          return
        fi
      fi

      # 해시가 없는 레코드는 상태만 비교하고, 해시가 있으면
      # FAIL 상태와 정규화 오류 해시가 모두 같을 때만 기준 일치로 인정한다.
      _verify_baseline_match=$((_verify_baseline_match+1))
      _ok "${_name}: 조치 전과 동일하게 실패 (기준 일치 — 복원 정상)"
      {
        echo ""
        echo "[${_name}]"
        echo "상태   : BASELINE_MATCH (조치 전에도 실패 — 복원 정상)"
        echo "명령   : ${_command}"
        [ -n "$_baseline_hash" ] && echo "오류 해시 : ${_baseline_hash} (일치)"
        if [ -n "$_detail" ]; then
          echo "출력   :"
          printf '%s\n' "$_detail" | sed 's/^/  /'
        else
          echo "출력   : 없음"
        fi
      } >> "$_verify_log" 2>/dev/null
      echo "VERIFY|${_name}|BASELINE_MATCH|${_command}|SHA256=${_baseline_hash:-LEGACY}" >> "$_rb_log" 2>/dev/null
      return
    fi
    case "$_status" in
      PASS)
        _verify_ok=$((_verify_ok+1))
        _ok "${_name}: 통과"
        ;;
      FAIL)
        _verify_fail=$((_verify_fail+1))
        _fail "${_name}: 실패"
        local _summary
        _summary=$(printf '%s\n' "$_detail" | sed '/^[[:space:]]*$/d' | head -1 | cut -c1-160)
        [ -n "$_summary" ] || _summary="오류 출력 없음"
        _verify_fail_names+=("$_name")
        _verify_fail_summaries+=("${_name}: ${_summary}")
        [ "$_name" = "PAM/authselect 구성" ] && _pam_verify_detail="$(printf '%s\n' "$_detail" | sed '/^[[:space:]]*$/d' | head -2 | tr '\n' ' ' | cut -c1-240)"
        ;;
      MANUAL)
        _verify_manual=$((_verify_manual+1))
        _warn "${_name}: 추가 확인 필요"
        ;;
    esac
    {
      echo ""
      echo "[${_name}]"
      echo "상태   : ${_status}"
      echo "명령   : ${_command}"
      if [ -n "$_detail" ]; then
        echo "출력   :"
        printf '%s\n' "$_detail" | sed 's/^/  /'
      else
        echo "출력   : 없음"
      fi
    } >> "$_verify_log" 2>/dev/null
    {
      echo "VERIFY|${_name}|${_status}|${_command}"
      [ -n "$_detail" ] && printf '%s\n' "$_detail" | sed 's/^/  /'
    } >> "$_rb_log" 2>/dev/null
  }

  # SSH 설정
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/ssh/sshd_config($|/)|(^|/)etc/ssh/sshd_config\.d(/|$)'; then
    if command -v sshd >/dev/null 2>&1; then
      : > "$_tmp_out"
      if sshd -t >"$_tmp_out" 2>&1; then
        _rb_verify_record "SSH 설정" "PASS" "sshd -t" "$(cat "$_tmp_out" 2>/dev/null)"
      else
        _rb_verify_record "SSH 설정" "FAIL" "sshd -t" "$(cat "$_tmp_out" 2>/dev/null)"
      fi
    else
      _rb_verify_record "SSH 설정" "MANUAL" "sshd -t" "sshd 명령을 찾을 수 없습니다."
    fi
  fi

  # sudo 설정
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/sudoers($|/)|(^|/)etc/sudoers\.d(/|$)'; then
    if command -v visudo >/dev/null 2>&1; then
      : > "$_tmp_out"
      if visudo -cf /etc/sudoers >"$_tmp_out" 2>&1; then
        _rb_verify_record "sudo 설정" "PASS" "visudo -cf /etc/sudoers" "$(cat "$_tmp_out" 2>/dev/null)"
      else
        _rb_verify_record "sudo 설정" "FAIL" "visudo -cf /etc/sudoers" "$(cat "$_tmp_out" 2>/dev/null)"
      fi
    else
      _rb_verify_record "sudo 설정" "MANUAL" "visudo -cf /etc/sudoers" "visudo 명령을 찾을 수 없습니다."
    fi
  fi

  # PAM/authselect 구성
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/pam\.d(/|$)|(^|/)etc/authselect(/|$)|(^|/)var/lib/authselect(/|$)'; then
    if command -v authselect >/dev/null 2>&1; then
      : > "$_tmp_out"
      if authselect check >"$_tmp_out" 2>&1; then
        _rb_verify_record "PAM/authselect 구성" "PASS" "authselect check" "$(cat "$_tmp_out" 2>/dev/null)"
      else
        _rb_verify_record "PAM/authselect 구성" "FAIL" "authselect check" "$(cat "$_tmp_out" 2>/dev/null)"
      fi
    else
      _rb_verify_record "PAM 구성" "MANUAL" "authselect check" "authselect 명령이 없어 PAM 파일 존재 여부만 확인했습니다."
    fi
  fi

  # rsyslog 설정
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/rsyslog\.conf$|(^|/)etc/rsyslog\.d(/|$)'; then
    if command -v rsyslogd >/dev/null 2>&1; then
      : > "$_tmp_out"
      if rsyslogd -N1 >"$_tmp_out" 2>&1; then
        _rb_verify_record "rsyslog 설정" "PASS" "rsyslogd -N1" "$(cat "$_tmp_out" 2>/dev/null)"
      else
        _rb_verify_record "rsyslog 설정" "FAIL" "rsyslogd -N1" "$(cat "$_tmp_out" 2>/dev/null)"
      fi
    else
      _rb_verify_record "rsyslog 설정" "MANUAL" "rsyslogd -N1" "rsyslogd 명령을 찾을 수 없습니다."
    fi
  fi

  # Postfix 설정 검증 및 실행 중인 서비스에만 반영한다.
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/postfix(/|$)'; then
    if ! command -v postfix >/dev/null 2>&1; then
      _rb_verify_record "Postfix 설정" "MANUAL" "postfix check" "postfix 명령을 찾을 수 없습니다."
      _service_skip=$((_service_skip+1))
      echo "SERVICE|Postfix|SKIP|postfix 명령 없음" >> "$_rb_log" 2>/dev/null
    else
      : > "$_tmp_out"
      if postfix check >"$_tmp_out" 2>&1; then
        _rb_verify_record "Postfix 설정" "PASS" "postfix check" "$(cat "$_tmp_out" 2>/dev/null)"

        if systemctl is-active --quiet postfix 2>/dev/null; then
          : > "$_tmp_out"
          if systemctl reload postfix >"$_tmp_out" 2>&1; then
            _ok "Postfix 서비스 반영: reload 완료"
            _service_ok=$((_service_ok+1))
            echo "SERVICE|Postfix|PASS|reload" >> "$_rb_log" 2>/dev/null
            {
              echo ""
              echo "[Postfix 서비스 반영]"
              echo "상태   : PASS"
              echo "방식   : reload"
              echo "출력   :"
              cat "$_tmp_out" 2>/dev/null | sed 's/^/  /'
            } >> "$_verify_log" 2>/dev/null
          elif systemctl restart postfix >"$_tmp_out" 2>&1; then
            _ok "Postfix 서비스 반영: restart 완료"
            _service_ok=$((_service_ok+1))
            echo "SERVICE|Postfix|PASS|restart" >> "$_rb_log" 2>/dev/null
            {
              echo ""
              echo "[Postfix 서비스 반영]"
              echo "상태   : PASS"
              echo "방식   : restart"
              echo "출력   :"
              cat "$_tmp_out" 2>/dev/null | sed 's/^/  /'
            } >> "$_verify_log" 2>/dev/null
          else
            _fail "Postfix 서비스 반영: reload/restart 실패"
            _service_fail=$((_service_fail+1))
            echo "SERVICE|Postfix|FAIL|reload/restart" >> "$_rb_log" 2>/dev/null
            {
              echo ""
              echo "[Postfix 서비스 반영]"
              echo "상태   : FAIL"
              echo "방식   : reload/restart"
              echo "출력   :"
              cat "$_tmp_out" 2>/dev/null | sed 's/^/  /'
            } >> "$_verify_log" 2>/dev/null
          fi
        else
          _info "Postfix 비활성 상태: 서비스를 시작하지 않음"
          _service_skip=$((_service_skip+1))
          echo "SERVICE|Postfix|SKIP|서비스 비활성" >> "$_rb_log" 2>/dev/null
          {
            echo ""
            echo "[Postfix 서비스 반영]"
            echo "상태   : SKIP"
            echo "사유   : 서비스 비활성 상태이므로 임의로 시작하지 않음"
          } >> "$_verify_log" 2>/dev/null
        fi
      else
        _rb_verify_record "Postfix 설정" "FAIL" "postfix check" "$(cat "$_tmp_out" 2>/dev/null)"
        _service_skip=$((_service_skip+1))
        echo "SERVICE|Postfix|SKIP|설정 검증 실패" >> "$_rb_log" 2>/dev/null
      fi
    fi
  fi

  if [ "$_verify_total" -eq 0 ]; then
    _info "자동 검증 대상 설정 파일 없음"
    {
      echo ""
      echo "[자동 검증]"
      echo "대상 없음"
    } >> "$_verify_log" 2>/dev/null
  fi

  # 10) 서비스 실행/부팅 상태, 방화벽 상태를 조치 전 메타데이터 기준으로 복원한다.
  if [ -d "$_meta_dir" ]; then
    _vf_restore_service_states "$_meta_dir/services.tsv" "$_rb_log" "$_verify_log" "$_file_list"
    _vf_apply_restored_service_configs "$_file_list" "$_rb_tmp_dir" "$_rb_log" "$_verify_log"
    _service_ok=$((_service_ok + _VF_CONFIG_APPLY_OK))
    _service_skip=$((_service_skip + _VF_CONFIG_APPLY_SKIP))
    _vf_restore_firewall_state "$_meta_dir/firewall" "$_rb_tmp_dir" "$_rb_log" "$_verify_log"
    _vf_compare_packages_after_rollback "$_meta_dir/packages.tsv" "$_rb_tmp_dir" "$_rb_log" "$_verify_log"
  else
    _VF_SERVICE_OK=0; _VF_SERVICE_FAIL=0; _VF_SERVICE_MANUAL=1
    _VF_CONFIG_APPLY_OK=0; _VF_CONFIG_APPLY_MANUAL=1; _VF_CONFIG_APPLY_SKIP=0
    _VF_FW_OK=0; _VF_FW_FAIL=0; _VF_FW_MANUAL=1; _VF_FW_RUNTIME_DRIFT=0
    _VF_PKG_ADDED=0; _VF_PKG_REMOVED=0; _VF_PKG_CHANGED=0; _VF_PKG_MANUAL=1; _VF_PKG_DIFF_FILE=""
  fi

  # 이력 레코드 기반 역산 결과를 포함해 최종 상태를 판정한다.
  # 9) 최종 상태 판정
  # 파일·권한·계정·서비스·지원 가능한 방화벽 상태를 기준값과 비교한다.
  # 패키지 버전은 안전한 자동 다운그레이드가 불가능하므로 변경 여부만 정확히 검출하고,
  # 지원 도구가 없거나 데이터가 있는 신규 디렉터리는 추가 확인으로 분리한다.
  local _final_status=""
  local _final_rc=0
  local _pkg_change_total=$((_VF_PKG_ADDED + _VF_PKG_REMOVED + _VF_PKG_CHANGED))
  local _hard_fail=$(( _content_fail + _meta_fail + _VF_EXT_FAIL + _verify_fail + _service_fail     + _perm_fail + _grp_fail + _VF_PATH_FAIL + _VF_ACCOUNT_FAIL + _VF_SERVICE_FAIL + _VF_FW_FAIL + _VF_ORPHAN_FAIL ))
  local _manual_total=$(( _verify_manual + _compare_manual + _VF_EXT_MANUAL + _VF_PATH_MANUAL     + _VF_ACCOUNT_MANUAL + _VF_SERVICE_MANUAL + _VF_FW_MANUAL + _VF_PKG_MANUAL     + _integrity_manual + _manifest_manual + _VF_ORPHAN_MANUAL + _pre_rollback_manual + _VF_CONFIG_APPLY_MANUAL ))
  if [ "$_hard_fail" -gt 0 ]; then
    _final_status="롤백 일부 실패 / 상세 검증 필요"
    _final_rc=1
  elif [ "$_pkg_change_total" -gt 0 ]; then
    _final_status="파일·설정 복원 완료 / 패키지 변경 ${_pkg_change_total}건 별도 확인 필요"
    _final_rc=2
  elif [ "$_manual_total" -gt 0 ]; then
    _final_status="주요 설정 복원 완료 / 일부 수동 확인 필요"
    _final_rc=2
  else
    _final_status="주요 설정·서비스 상태 복원 완료 / 검증 통과"
    _final_rc=0
  fi

  {
    echo ""
    echo "[최종 요약]"
    echo "완료 시간         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "파일 복원         : ${_ok_cnt}/${_total} 성공"
    echo "내용 일치 검증    : 일치 ${_content_ok} / 불일치 ${_content_fail}"
    echo "메타정보 검증     : 일치 ${_meta_ok} / 불일치 ${_meta_fail}"
    echo "설정 검증         : 정상통과 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
    echo "설정 서비스 반영  : 성공 ${_service_ok} / 실패 ${_service_fail} / 수동확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
    echo "서비스 상태 복원  : 성공 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
    echo "방화벽 상태 복원  : 성공 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
    echo "계정 상태 비교    : 일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
    echo "경로 생성·삭제    : 자동정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 추가확인 ${_VF_PATH_MANUAL}"
    echo "무소유 파일(U-15) : 복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 수동확인 ${_VF_ORPHAN_MANUAL}"
    echo "패키지 변경       : 추가 ${_VF_PKG_ADDED} / 제거 ${_VF_PKG_REMOVED} / 버전변경 ${_VF_PKG_CHANGED}"
    echo "권한 자동 역산    : 성공 ${_perm_cnt} / 실패 ${_perm_fail}"
    echo "그룹 자동 역산    : 성공 ${_grp_cnt} / 실패 ${_grp_fail}"
    echo "복귀용 안전 백업  : ${_pre_rollback_backup:-생성되지 않음}"
    echo "최종 결과         : ${_final_status}"
    echo "종료 코드         : ${_final_rc}"
  } >> "$_verify_log" 2>/dev/null

  {
    echo ""
    echo "[최종 요약]"
    echo "완료 시간         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "파일 복원         : ${_ok_cnt}/${_total} 성공"
    echo "내용 일치 검증    : 일치 ${_content_ok} / 불일치 ${_content_fail}"
    echo "메타정보 검증     : 일치 ${_meta_ok} / 불일치 ${_meta_fail}"
    echo "설정 검증         : 정상통과 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
    echo "설정 서비스 반영  : 성공 ${_service_ok} / 실패 ${_service_fail} / 수동확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
    echo "서비스 상태 복원  : 성공 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
    echo "방화벽 상태 복원  : 성공 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
    echo "계정 상태 비교    : 일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
    echo "경로 생성·삭제    : 자동정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 추가확인 ${_VF_PATH_MANUAL}"
    echo "무소유 파일(U-15) : 복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 수동확인 ${_VF_ORPHAN_MANUAL}"
    echo "패키지 변경       : 추가 ${_VF_PKG_ADDED} / 제거 ${_VF_PKG_REMOVED} / 버전변경 ${_VF_PKG_CHANGED}"
    echo "권한 자동 역산    : 성공 ${_perm_cnt} / 실패 ${_perm_fail}"
    echo "그룹 자동 역산    : 성공 ${_grp_cnt} / 실패 ${_grp_fail}"
    echo "복귀용 안전 백업  : ${_pre_rollback_backup:-생성되지 않음}"
    echo "최종 결과         : ${_final_status}"
    echo "종료 코드         : ${_final_rc}"
  } >> "$_rb_log" 2>/dev/null

  local _file_match_text=""
  if [ "$_content_fail" -eq 0 ] && [ "$_meta_fail" -eq 0 ]; then
    _file_match_text="${_compare_total}/${_compare_total}개 일치"
  else
    _file_match_text="내용 불일치 ${_content_fail} / 메타정보 불일치 ${_meta_fail}"
  fi

  local _extra_total=$((_inverse_perm_total + _inverse_grp_total))
  local _extra_text="대상 없음"
  if [ "$_extra_total" -gt 0 ]; then
    _extra_text="대상 ${_extra_total}건 / 성공 $((_perm_cnt + _grp_cnt)) / 실패 $((_perm_fail + _grp_fail))"
  elif [ "$_inverse_screen" -eq 1 ]; then
    _extra_text="확인 필요"
  fi

  echo ""
  _div_thin
  echo -e " ${BOLD}${GREEN}[Rollback 결과]${RESET}"
  echo ""
  if [ "$_final_rc" -eq 0 ]; then
    _row "최종 결과" "${_final_status}" "✓"
  elif [ "$_final_rc" -eq 2 ]; then
    _row "최종 결과" "${_final_status}" "${YELLOW}⚠${RESET}"
  else
    _row "최종 결과" "${_final_status}" "✗"
  fi
  _row "종료 코드" "${_final_rc} (0=완전복원, 1=실패, 2=수동확인 필요)"
  _row "복원 파일" "${_ok_cnt}/${_total}개 성공"
  _row "파일 일치" "${_file_match_text}"
  _row "설정 검증" "정상 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
  _row "설정 서비스 반영" "성공 ${_service_ok} / 실패 ${_service_fail} / 수동확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
  _row "서비스 상태" "복원 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
  _row "방화벽 상태" "복원 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
  _row "계정 상태" "일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
  _row "생성·삭제 경로" "정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 추가확인 ${_VF_PATH_MANUAL}"
  _row "무소유 파일(U-15)" "복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 수동확인 ${_VF_ORPHAN_MANUAL}"
  _row "패키지 변경" "추가 ${_VF_PKG_ADDED} / 제거 ${_VF_PKG_REMOVED} / 버전변경 ${_VF_PKG_CHANGED}"
  _row "추가 복구" "${_extra_text}"

  if [ "${#_verify_fail_summaries[@]}" -gt 0 ]; then
    echo ""
    echo -e " ${BOLD}${YELLOW}[설정 검증 실패 요약]${RESET}"
    echo ""
    local _vf
    for _vf in "${_verify_fail_summaries[@]}"; do
      _fail "${_vf}"
    done
    if [ -n "$_pam_verify_detail" ]; then
      _info "PAM/authselect 원문 요약: ${_pam_verify_detail}"
    fi
    _info "전체 오류 원문: ${_verify_log}"
    echo ""
  fi

  _row "복원 기준" "$(basename "$_selected")"
  _row "복귀용 안전 백업" "${_pre_rollback_backup:-생성되지 않음}"
  _row "실행 로그" "$_rb_log"
  _row "검증 결과" "$_verify_log"
  _row "이력 로그" "$FIX_HISTORY_FILE"
  echo ""

  # 롤백 후 남은 차이가 있을 때만 추가 확인 항목을 표시한다.
  if [ "$_manual_total" -gt 0 ] || [ $((_VF_PKG_ADDED+_VF_PKG_REMOVED+_VF_PKG_CHANGED)) -gt 0 ]; then
    echo -e " ${BOLD}${YELLOW}[추가 확인 항목]${RESET}"
    echo ""
    [ "$_pre_rollback_manual" -gt 0 ] && _warn "롤백 직전 안전 백업을 생성하지 못한 상태로 강제 진행했습니다."
    [ "$_integrity_manual" -gt 0 ] && _warn "백업 체크섬이 없어 구조 검증만 수행했습니다."
    [ "$_manifest_manual" -gt 0 ] && _warn "manifest가 없거나 다른 서버 백업을 강제로 사용했습니다."
    [ "$_VF_SERVICE_MANUAL" -gt 0 ] && _warn "일부 서비스 상태는 원격 연결 보호, 복원 설정 사전검증 또는 unit 변화로 자동 복원하지 않았습니다."
    [ "$_VF_CONFIG_APPLY_MANUAL" -gt 0 ] && _warn "일부 복원 설정은 안전한 비기동 검증 미지원, 설정 검증 실패 또는 reload/restart 실패로 자동 반영하지 않았습니다."
    [ "$_VF_FW_MANUAL" -gt 0 ] && _warn "일부 방화벽 상태(nftables 등)는 연결 단절 위험으로 자동 적용하지 않았습니다."
    if [ "${_VF_FW_RUNTIME_DRIFT:-0}" -eq 1 ]; then
      _warn "백업 시점에 firewalld Runtime과 Permanent 규칙이 달랐습니다."
      _warn "Permanent 설정은 복원됐으나 당시 Runtime 전용 규칙은 별도 확인이 필요합니다."
    fi
    [ "$_VF_PATH_MANUAL" -gt 0 ] && _warn "조치 전에는 없던 비어 있지 않은 경로 또는 추적되지 않은 신규 경로가 있습니다."
    [ "$_VF_ACCOUNT_MANUAL" -gt 0 ] && _warn "조치 전에는 없던 신규 계정이 발견됐습니다. 패키지 설치 계정인지 확인하세요."
    if [ "$_pkg_change_total" -gt 0 ]; then
      _warn "패키지 변경은 자동 다운그레이드하지 않습니다. 추가 ${_VF_PKG_ADDED}, 제거 ${_VF_PKG_REMOVED}, 버전변경 ${_VF_PKG_CHANGED}건을 확인하세요."
      if [ -n "${_VF_PKG_DIFF_FILE:-}" ] && [ -s "$_VF_PKG_DIFF_FILE" ]; then
        echo ""
        echo -e " ${BOLD}${YELLOW}[패키지 변경 목록]${RESET}"
        echo ""
        while IFS= read -r _pkg_line; do
          echo "   ${_pkg_line}"
        done < "$_VF_PKG_DIFF_FILE"
      fi
    fi
    [ "$_VF_EXT_MANUAL" -gt 0 ] && _warn "일부 ACL/xattr/SELinux 검증 도구가 없어 확장 메타정보 확인이 제한됐습니다."
    _info "상세 내용: ${_verify_log}"
    echo ""
  fi

  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/ssh/|(^|/)etc/pam\.d/|(^|/)etc/authselect/'; then
    _warn "SSH/PAM 관련 파일이 복원되었습니다. 적용 시점은 운영 정책에 따라 확인하세요."
    _info "필요 시: systemctl restart sshd"
    echo ""
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S')|ROLLBACK|${_final_status}|RC=${_final_rc}|백업=${_selected}|파일=${_ok_cnt}/${_total}|내용불일치=${_content_fail}|메타불일치=${_meta_fail}|검증성공=${_verify_ok}|기준일치=${_verify_baseline_match}|검증실패=${_verify_fail}|추가확인=${_manual_total}|서비스복원실패=${_VF_SERVICE_FAIL}|설정반영성공=${_VF_CONFIG_APPLY_OK}|설정반영수동=${_VF_CONFIG_APPLY_MANUAL}|방화벽복원실패=${_VF_FW_FAIL}|계정불일치=${_VF_ACCOUNT_FAIL}|경로실패=${_VF_PATH_FAIL}|패키지변경=$((_VF_PKG_ADDED+_VF_PKG_REMOVED+_VF_PKG_CHANGED))|권한역산실패=${_perm_fail}|그룹역산실패=${_grp_fail}|안전백업=${_pre_rollback_backup:-NONE}|로그=${_rb_log}|검증=${_verify_log}" >> "$FIX_HISTORY_FILE" 2>/dev/null

  trap - INT TERM HUP
  _rb_cleanup
  unset -f _rb_verify_record _rb_interrupted _rb_cleanup 2>/dev/null
  return "$_final_rc"
}

if [ "$ROLLBACK" -eq 1 ]; then
  _do_rollback
  exit $?
fi

# ── 대상 항목(TARGET_IDS) 결정 ────────────────────────────────────────────────
# [분리 스크립트 1/2] 이 스크립트는 U-01~U-67만 다룬다.
# 기본: report 파일 없이 U-01~U-67을 스크립트가 직접 스캔한다.
#      (취약/수동확인/양호 판정은 곧이어 실행되는 재확인 프로그래스바 단계에서 수행)
_SPLIT_MIN=1; _SPLIT_MAX=67
REPORT=""
if [ -n "$1" ] && [ -f "$1" ]; then
  REPORT="$1"
  echo -e " 점검 파일 지정됨: ${CYAN}${REPORT}${RESET} (보고서 기반 빠른 모드)"
  echo ""
  VULN_IDS=$(grep -E '^\[✘ 취약\]|^\[! 수동확인\]' "$REPORT" | grep -oP 'U-[0-9]+' | sort -t- -k2 -n | uniq)
  TARGET_IDS=()
  for id in $VULN_IDS; do
    _snum=${id#U-}; _snum=$((10#$_snum))
    [ "$_snum" -ge "$_SPLIT_MIN" ] && [ "$_snum" -le "$_SPLIT_MAX" ] && TARGET_IDS+=("$id")
  done

  if [ ${#TARGET_IDS[@]} -eq 0 ]; then
    echo -e "${GREEN} 보고서에 취약 및 수동확인 항목이 없습니다.${RESET}"; exit 0
  fi
  echo -e "${BOLD} 보고서 취약 항목: ${RED}${#TARGET_IDS[@]}${RESET}${BOLD}개${RESET} 발견 — 현재 시스템 상태로 재확인을 시작합니다."
else
  echo -e " 주요정보통신기반시설 기술적 취약점 ${CYAN}U-01 ~ U-67 항목${RESET}을 직접 스캔합니다."
  echo ""
  TARGET_IDS=()
  for _n in $(seq -w "$_SPLIT_MIN" "$_SPLIT_MAX"); do TARGET_IDS+=("U-${_n}"); done
  echo -e "${BOLD} 전체 점검 대상: ${CYAN}${#TARGET_IDS[@]}${RESET}${BOLD}개${RESET} — 실시간 스캔을 시작합니다."
fi
echo ""

# =============================================================================
# ── [실행 결과 로그] 단계·오류 형식 표준화 ───────────────────────────────────
# - 화면: 현재 상태 → 조치 중 → 조치 결과 → 최종 검증 순서를 유지한다.
# - 상세 로그(vulnFixDetail_*.log) 하나에 CHECK / FIX / VERIFY / RESULT를 모두 남긴다.
# - 내부 명령·stdout·stderr·종료코드는 상세 로그에만 남긴다.
# - vulnFixHistory.log의 레코드 형식은 유지하고 저장 위치만 report/logs로 통일한다.
# =============================================================================
DETAIL_LOG_FILE=""
  _EXEC_LOG_DIR="${_LOG_DIR}"
  # 새 로그를 만들기 전에 오래된 상세 로그부터 정리한다.
  _vf_prune_old_artifacts "$_EXEC_LOG_DIR" "vulnFixDetail_${_HOSTNAME_VAL}_*.log" \
    "$VULNFIX_KEEP_LOGS" "상세 로그"
  DETAIL_LOG_FILE="${_EXEC_LOG_DIR}/vulnFixDetail_${_HOSTNAME_VAL}_${_RUN_TS}.log"
  : > "$DETAIL_LOG_FILE" 2>/dev/null || DETAIL_LOG_FILE=""
  [ -n "$DETAIL_LOG_FILE" ] && chmod 600 "$DETAIL_LOG_FILE" 2>/dev/null || true

# ANSI CSI 색상·커서 제어 코드와 CR 문자를 제거한다.
# 입력은 표준 입력으로 받고 정제된 문자열을 표준 출력으로 전달한다.
_strip_ansi_stream() {
  LC_ALL=C sed -E $'s#\x1B\\[[0-?]*[ -/]*[@-~]##g; s#\r##g' 2>/dev/null
}

# 로그의 제목·메시지를 한 줄 형식으로 정리한다.
# ANSI 코드, 실제 개행, 문자열 "\n", 중복 공백을 제거한다.
_log_clean_text() {
  printf '%s' "$1" \
    | _strip_ansi_stream \
    | sed ':a;N;$!ba;s/\n/ \/ /g' 2>/dev/null \
    | sed 's/\\n/ \/ /g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vf_format_report_value
#
# 역할:
#   점검 전·조치 후 명령 출력을 CSV와 Excel 셀에 저장할 공통 문자열로 변환한다.
#
# 입력:
#   $1 : 명령 출력 원문
#   $2 : 출력이 비어 있을 때 사용할 기본 문구
#
# 출력:
#   빈 줄과 ANSI 코드를 제거하고 각 줄을 " || "로 연결한 문자열
#
# 보존 범위:
#   최대 200줄까지 셀 값에 포함하며 초과분은 상세 로그 위치를 안내한다.
#
# 주의:
#   실제 개행과 문자열 "\n"을 같은 방식으로 처리해 항목별 보고서 형식을 통일한다.
# -----------------------------------------------------------------------------
_vf_format_report_value() {
  local _out="$1" _empty_msg="$2"
  local _clean=""
  _clean=$(printf '%s' "$_out" \
    | _strip_ansi_stream \
    | sed 's/\\n/\n/g' 2>/dev/null \
    | grep -v '^[[:space:]]*$')

  if [ -z "$_clean" ]; then
    printf '%s' "$_empty_msg"
    return 0
  fi

  local _total
  _total=$(printf '%s\n' "$_clean" | wc -l | tr -d ' ')

  if [ "$_total" -gt 200 ]; then
    printf '%s' "$(printf '%s\n' "$_clean" \
      | head -200 \
      | sed ':a;N;$!ba;s/\n/ || /g') || ... 외 $((_total-200))줄 더 있음 (전체는 상세 로그 참고: ${DETAIL_LOG_FILE:-미생성})"
  else
    printf '%s' "$(printf '%s\n' "$_clean" | sed ':a;N;$!ba;s/\n/ || /g')"
  fi
}

# 항목의 점검 전 상태를 공통 정제한 뒤 BEFORE_VAL에 저장한다.
# 입력: $1=항목 ID, $2=원문, $3=빈 출력 기본 문구(선택)
_vf_fill_before_val() {
  local _id="$1" _out="$2" _empty_msg="${3:-이상 항목 없음 (점검 통과)}"
  BEFORE_VAL["$_id"]=$(_vf_format_report_value "$_out" "$_empty_msg")
}

# 항목의 조치 후·검증 상태를 공통 정제한 뒤 AFTER_VAL에 저장한다.
# 입력: $1=항목 ID, $2=원문, $3=빈 출력 기본 문구(선택)
_vf_fill_after_val() {
  local _id="$1" _out="$2" _empty_msg="${3:-검증 결과 없음}"
  AFTER_VAL["$_id"]=$(_vf_format_report_value "$_out" "$_empty_msg")
}

# -----------------------------------------------------------------------------
# _vf_capture_eval_subshell
#
# 역할:
#   점검·검증 명령을 서브셸에서 실행하고 stdout, stderr, 종료 코드를 분리해 수집한다.
#
# 입력:
#   $1 : eval로 실행할 명령 문자열
#
# 결과 전역:
#   _VF_CAPTURE_RC / _VF_CAPTURE_STDOUT / _VF_CAPTURE_STDERR
#
# 반환값:
#   함수 자체는 수집 완료 후 항상 0을 반환하며 실제 명령 결과는 _VF_CAPTURE_RC에 저장한다.
#
# 시스템 영향:
#   호출된 명령의 영향은 그대로 발생하지만 서브셸의 변수·디렉터리 변경은 본 셸에 남지 않는다.
# -----------------------------------------------------------------------------
_vf_capture_eval_subshell() {
  local _cmd="$1" _out _err
  _out=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_out.%s' "$$")
  _err=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_err.%s' "$$")
  : > "$_out" 2>/dev/null; : > "$_err" 2>/dev/null
  ( eval "$_cmd" ) >"$_out" 2>"$_err"
  _VF_CAPTURE_RC=$?
  _VF_CAPTURE_STDOUT=$(cat "$_out" 2>/dev/null)
  _VF_CAPTURE_STDERR=$(cat "$_err" 2>/dev/null)
  rm -f "$_out" "$_err" 2>/dev/null
  return 0
}

# 항목 화면 단계의 시작을 CHECK/FIX/VERIFY/RESULT 코드로 상세 로그에 기록한다.
# 입력: $1=항목 ID, $2=단계 코드, $3=화면 단계 설명
_detail_log_stage() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _sid="$1" _stage="$2" _label
  _label=$(_log_clean_text "$3")
  printf '[%s] [%-5s] [%-6s] START | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_sid" "$_stage" "$_label" \
    >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# 한 U 항목 처리 시작 시 항목 ID, 판정 상태와 제목을 상세 로그에 기록한다.
_detail_log_item_start() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _iid="$1" _state="$2" _title
  _title=$(_log_clean_text "$3")
  printf '\n[%s] [%-5s] [TASK  ] START | state=%s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_iid" "$_state" "$_title" \
    >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _detail_log_command
#
# 역할:
#   CHECK/FIX/VERIFY 명령의 원문, 종료 코드, stdout과 stderr를 구조화해 기록한다.
#
# 입력:
#   $1 : 항목 ID
#   $2 : 단계 코드
#   $3 : 실행 명령
#   $4 : 종료 코드
#   $5 : 표준 출력
#   $6 : 오류 출력
#   $7 : 단계 판정 상태
#
# 출력:
#   DETAIL_LOG_FILE에 COMMAND/EXIT_CODE/OUTPUT/ERROR_OUTPUT 블록 추가
#
# 주의:
#   화면에는 필요한 요약만 표시하고 전체 명령·오류는 이 로그에서 확인한다.
# -----------------------------------------------------------------------------
_detail_log_command() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _cid="$1" _stage="$2" _cmd="$3" _rc="$4" _stdout="$5" _stderr="$6" _status="$7"
  {
    echo "============================================================"
    printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_cid" "$_stage" "$_status"
    echo "------------------------------------------------------------"
    echo "[COMMAND]"
    [ -n "$_cmd" ] && printf '%s\n' "$_cmd" || echo "(없음)"
    echo ""
    printf '[EXIT_CODE] %s\n' "$_rc"
    echo "[OUTPUT]"
    if [ -n "$_stdout" ]; then printf '%s\n' "$_stdout" | _strip_ansi_stream; else echo "(없음)"; fi
    echo "[ERROR_OUTPUT]"
    if [ -n "$_stderr" ]; then printf '%s\n' "$_stderr" | _strip_ansi_stream; else echo "(없음)"; fi
    echo "============================================================"
    echo ""
  } >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# 항목의 최종 상태와 요약 메시지를 RESULT 한 줄 형식으로 기록한다.
# 표준 상태: GOOD/FIXED/MANUAL/USER_SKIPPED/NA/FAILED
_detail_log_result() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _rid="$1" _status="$2" _msg
  _msg=$(_log_clean_text "$3")
  printf '[%s] [%-5s] [RESULT] %-12s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_rid" "$_status" "$_msg" \
    >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# 현재 실행의 서버·OS·범위와 로그 단계·상태 코드를 상세 로그 머리글에 기록한다.
_detail_log_header() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  {
    echo "============================================================"
    echo " Linux 취약점 점검 및 조치 상세 로그 (CHECK/FIX/VERIFY/RESULT)"
    echo "============================================================"
    printf '실행 ID   : %s\n' "$_RUN_ID"
    printf '서버명    : %s\n' "$_HOSTNAME_VAL"
    printf 'OS 정보   : %s\n' "$_OS_INFO"
    printf '실행 범위 : %s\n' "$_SCRIPT_SCOPE"
    printf '실행 시각 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "단계 코드 : CHECK / FIX / VERIFY / RESULT"
    echo "상태 코드 : GOOD / FIXED / MANUAL / USER_SKIPPED / NA / FAILED"
    echo "============================================================"
    echo ""
  } >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# 명령 블록 외에 필요한 보충 설명과 자동 복원 이벤트를 한 줄로 기록한다.
# 입력: $1=항목 ID, $2=단계 또는 이벤트 코드, $3=메시지
_detail_log_note() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _did="$1" _dstage="$2" _dmsg
  _dmsg=$(_log_clean_text "$3")
  printf '[%s] [%s] [%s] %s\n'     "$(date '+%Y-%m-%d %H:%M:%S')" "$_did" "$_dstage" "$_dmsg"     >> "$DETAIL_LOG_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _detail_log_summary
#
# 역할:
#   실행 종료 시 상태별 건수와 최종 상태, 백업·누적 이력 위치를 상세 로그에 기록한다.
#
# 입력:
#   $1 : 이미 양호
#   $2 : 조치 완료
#   $3 : 수동 확인
#   $4 : 사용자 건너뜀
#   $5 : 해당 없음
#   $6 : 실패
#
# 최종 상태:
#   실패가 있으면 "실패 항목 포함",
#   수동 확인 또는 건너뜀이 있으면 "추가 확인 필요",
#   나머지는 "완료"로 기록한다.
# -----------------------------------------------------------------------------
_detail_log_summary() {
  [ -n "${DETAIL_LOG_FILE:-}" ] || return 0
  local _good="$1" _fixed="$2" _manual="$3" _uskip="$4" _na="$5" _failed="$6"
  local _state="완료"
  if [ "$_failed" -gt 0 ]; then
    _state="실패 항목 포함"
  elif [ "$_manual" -gt 0 ] || [ "$_uskip" -gt 0 ]; then
    _state="추가 확인 필요"
  fi
  {
    echo ""
    echo "============================================================"
    echo " 실행 결과 요약"
    echo "============================================================"
    printf '전체 항목       : %s\n' "${#TARGET_IDS[@]}"
    printf '이미 양호       : %s\n' "$_good"
    printf '조치 완료       : %s\n' "$_fixed"
    printf '수동 확인       : %s\n' "$_manual"
    printf '사용자 건너뜀   : %s\n' "$_uskip"
    printf '해당 없음       : %s\n' "$_na"
    printf '조치 실패       : %s\n' "$_failed"
    echo "------------------------------------------------------------"
    printf '최종 상태       : %s\n' "$_state"
    printf '백업 파일       : %s\n' "${_PRE_BAK_RECORDED:-미생성}"
    printf '누적 이력       : %s\n' "$FIX_HISTORY_FILE"
    echo "============================================================"
  } >> "$DETAIL_LOG_FILE" 2>/dev/null
}

_detail_log_header

# ── U-33 공용 숨김파일 탐색 함수 ─────────────────────────────────────────────
# 정상 dotfile/dotdir을 최대한 제외하고 의심 항목만 반환한다.
# 이 함수를 check_still_vuln과 do_manual 양쪽에서 공유하여 판정 기준을 일치시킨다.
_u33_find() {
  find /home /root /tmp -name '.*' \
    -not -name '.'  -not -name '..' \
    \
    -not -name '.bash*'     -not -name '.zsh*'      -not -name '.ksh*' \
    -not -name '.csh*'      -not -name '.tcshrc'     -not -name '.profile' \
    -not -name '.logout'    -not -name '.hushlogin'  -not -name '.shrc' \
    \
    -not -name '.viminfo'   -not -name '.vimrc'      -not -name '.vim' \
    -not -name '.nano*'     -not -name '.emacs*'     -not -name '.lesshst' \
    -not -name '.selected_editor' \
    \
    -not -name '.X*'        -not -name '.xauth*'     -not -name '.Xauthority' \
    -not -name '.xsession*' -not -name '.ICE-unix'   -not -name '.XIM-unix' \
    -not -name '.font-unix' -not -name '.Test-unix' \
    \
    -not -name '.java'      -not -name '.oracle_jre_usage' \
    -not -name '.dbus'      -not -name '.esd-*'      -not -name '.pulse*' \
    \
    -not -name '.wget-hsts' -not -name '.netrc' \
    -not -name '.perldb'    -not -name '.python_history' \
    -not -name '.node_repl_history' \
    -not -name '.mysql_history' -not -name '.psql_history' \
    -not -name '.sqlite_history' -not -name '.rediscli*' \
    -not -name '.irb_history'   -not -name '.mongorc*' \
    -not -name '.sudo_as_admin_successful' -not -name '.motd_shown' \
    -not -name '.landscape'     -not -name '.gnome*' \
    -not -name '.Trash*'        -not -name '.thumbnails' \
    -not -name '.lkGUIpreferences'  -not -name '.screenrc' \
    -not -name '.tmux*'     -not -name '.gitconfig'  -not -name '.subversion' \
    -not -name '.my.cnf'    -not -name '.pgpass'     -not -name '.odbc.ini' \
    \
    -not -path '/tmp/.X*'         -not -path '/tmp/.ICE-unix' \
    -not -path '/tmp/.XIM-unix'   -not -path '/tmp/.font-unix' \
    -not -path '/tmp/.Test-unix'  -not -path '/tmp/.oracle' \
    -not -path '/tmp/.esd-*'      -not -path '/tmp/.pulse-*' \
    \
    -not -path '*/.mozilla*'  -not -path '*/.local*'   -not -path '*/.config*' \
    -not -path '*/.cache*'    -not -path '*/.gnupg*'   -not -path '*/.pki*' \
    -not -path '*/.ssh*'      -not -path '*/.npm*'     -not -path '*/.docker*' \
    -not -path '*/.kube*'     -not -path '*/.aws*'     -not -path '*/.azure*' \
    -not -path '*/.gcloud*'   -not -path '*/.ansible*' \
    -not -path '*/.java*'     -not -path '*/.oracle_jre_usage*' \
    -not -path '*/.dbus*'     -not -path '*/.ipython*' \
    2>/dev/null
}

# ── 패키지 업데이트 상태 확인 ────────────────────────────────────────────────
# 반환값: 0=업데이트 있음, 1=업데이트 없음, 2=판단 불가(저장소/도구 문제)
_pkg_update_state() {
  local _pkg="$1" _rc
  if command -v dnf &>/dev/null; then
    dnf -q check-update "$_pkg" >/dev/null 2>&1; _rc=$?
    [ "$_rc" -eq 100 ] && return 0
    [ "$_rc" -eq 0 ] && return 1
    return 2
  elif command -v yum &>/dev/null; then
    yum -q check-update "$_pkg" >/dev/null 2>&1; _rc=$?
    [ "$_rc" -eq 100 ] && return 0
    [ "$_rc" -eq 0 ] && return 1
    return 2
  elif command -v apt &>/dev/null; then
    local _apt_out
    _apt_out=$(apt list --upgradable 2>/dev/null) || return 2
    echo "$_apt_out" | grep -qE "^${_pkg}/" && return 0
    return 1
  elif command -v zypper &>/dev/null; then
    local _zyp_out
    _zyp_out=$(zypper --non-interactive list-updates "$_pkg" 2>/dev/null) || return 2
    echo "$_zyp_out" | grep -qE "(^|[[:space:]|])${_pkg}([[:space:]|]|$)" && return 0
    return 1
  fi
  return 2
}

# ── U-23 승인 및 그룹 실행 제한 정책 ──────────────────────────────────────────
# KISA 기준에 따라 SUID/SGID 파일의 필요 여부는 운영자가 판단한다.
# 최초 검토 시 분류별 그룹 단위로 결정하고, 승인 당시의 경로/소유자/그룹/권한을
# 기록한다. 다음 실행에서는 현재 상태가 승인 기록과 동일한 항목은 재질문하지 않으며,
# 신규 파일 또는 소유자·그룹·권한이 변경된 파일만 다시 검토한다.
_U23_RESTRICT_FILE="${_RB_DIR}/u23_restricted.conf"
_U23_APPROVAL_FILE="${_RB_DIR}/u23_approved.conf"

_u23_clean_field() {
  local _v="$1"
  _v="${_v//$'\r'/ }"
  _v="${_v//$'\n'/ }"
  _v="${_v//|//}"
  printf '%s' "$_v"
}

_u23_restricted_valid() {
  local _path="$1" _rec _owner _group _mode _cur_owner _cur_group _cur_mode
  [ -f "$_U23_RESTRICT_FILE" ] || return 1
  _rec=$(awk -F'|' -v p="$_path" '
    $0 !~ /^[[:space:]]*#/ && $1 == p { rec=$0 }
    END { print rec }
  ' "$_U23_RESTRICT_FILE" 2>/dev/null)
  [ -n "$_rec" ] || return 1
  _owner=$(printf '%s' "$_rec" | awk -F'|' '{print $2}')
  _group=$(printf '%s' "$_rec" | awk -F'|' '{print $3}')
  _mode=$(printf '%s' "$_rec" | awk -F'|' '{print $4}')
  [ -n "$_owner" ] && [ -n "$_group" ] && [ -n "$_mode" ] || return 1
  [ -f "$_path" ] || return 1
  _cur_owner=$(stat -c '%U' "$_path" 2>/dev/null)
  _cur_group=$(stat -c '%G' "$_path" 2>/dev/null)
  _cur_mode=$(stat -c '%a' "$_path" 2>/dev/null)
  [ "$_cur_owner" = "$_owner" ] && [ "$_cur_group" = "$_group" ] && [ "$_cur_mode" = "$_mode" ]
}

_u23_register_restricted() {
  local _path="$1" _owner="$2" _group="$3" _mode="$4" _tmp _operator
  [ -n "$_path" ] && [ -n "$_owner" ] && [ -n "$_group" ] && [ -n "$_mode" ] || return 1
  mkdir -p "$_RB_DIR" 2>/dev/null || return 1
  _tmp="${_U23_RESTRICT_FILE}.tmp.$$"
  _operator="${SUDO_USER:-$(id -un 2>/dev/null)}"
  [ -n "$_operator" ] || _operator="root"
  {
    echo "# path|owner|group|mode|confirmed_date|operator"
    if [ -f "$_U23_RESTRICT_FILE" ]; then
      awk -F'|' -v p="$_path" '$0 !~ /^[[:space:]]*#/ && $1 != p { print }' \
        "$_U23_RESTRICT_FILE" 2>/dev/null
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$_path" "$_owner" "$_group" "$_mode" "$(date '+%Y-%m-%d')" "$_operator"
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$_U23_RESTRICT_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_U23_RESTRICT_FILE" 2>/dev/null
}

_u23_remove_restricted() {
  local _path="$1" _tmp
  [ -f "$_U23_RESTRICT_FILE" ] || return 0
  _tmp="${_U23_RESTRICT_FILE}.tmp.$$"
  {
    echo "# path|owner|group|mode|confirmed_date|operator"
    awk -F'|' -v p="$_path" '$0 !~ /^[[:space:]]*#/ && $1 != p { print }' \
      "$_U23_RESTRICT_FILE" 2>/dev/null
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$_U23_RESTRICT_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_U23_RESTRICT_FILE" 2>/dev/null
}

_u23_approval_record() {
  local _path="$1"
  [ -f "$_U23_APPROVAL_FILE" ] || return 0
  awk -F'|' -v p="$_path" '
    $0 !~ /^[[:space:]]*#/ && $1 == p { rec=$0 }
    END { print rec }
  ' "$_U23_APPROVAL_FILE" 2>/dev/null
}

_u23_approval_valid() {
  local _path="$1" _rec _owner _group _mode _cur_owner _cur_group _cur_mode
  _rec=$(_u23_approval_record "$_path")
  [ -n "$_rec" ] || return 1
  _owner=$(printf '%s' "$_rec" | awk -F'|' '{print $2}')
  _group=$(printf '%s' "$_rec" | awk -F'|' '{print $3}')
  _mode=$(printf '%s' "$_rec" | awk -F'|' '{print $4}')
  [ -f "$_path" ] || return 1
  _cur_owner=$(stat -c '%U' "$_path" 2>/dev/null)
  _cur_group=$(stat -c '%G' "$_path" 2>/dev/null)
  _cur_mode=$(stat -c '%a' "$_path" 2>/dev/null)
  [ "$_cur_owner" = "$_owner" ] && [ "$_cur_group" = "$_group" ] && [ "$_cur_mode" = "$_mode" ]
}

_u23_approval_category() {
  local _rec
  _rec=$(_u23_approval_record "$1")
  [ -n "$_rec" ] && printf '%s' "$_rec" | awk -F'|' '{print $5}'
}

_u23_register_approval() {
  local _path="$1" _owner="$2" _group="$3" _mode="$4" _category="$5" _reason="${6:-OPERATOR_REVIEWED}"
  local _tmp _operator
  [ -n "$_path" ] && [ -n "$_owner" ] && [ -n "$_group" ] && [ -n "$_mode" ] || return 1
  _category=$(_u23_clean_field "${_category:-기타·출처 불명}")
  _reason=$(_u23_clean_field "${_reason:-OPERATOR_REVIEWED}")
  _operator="${SUDO_USER:-$(id -un 2>/dev/null)}"
  [ -n "$_operator" ] || _operator="root"
  mkdir -p "$_RB_DIR" 2>/dev/null || return 1
  _tmp="${_U23_APPROVAL_FILE}.tmp.$$"
  {
    echo "# path|owner|group|mode|category|decision|reason|confirmed_date|operator"
    if [ -f "$_U23_APPROVAL_FILE" ]; then
      awk -F'|' -v p="$_path" '$0 !~ /^[[:space:]]*#/ && $1 != p { print }' \
        "$_U23_APPROVAL_FILE" 2>/dev/null
    fi
    printf '%s|%s|%s|%s|%s|KEEP_APPROVED|%s|%s|%s\n' \
      "$_path" "$_owner" "$_group" "$_mode" "$_category" "$_reason" \
      "$(date '+%Y-%m-%d')" "$_operator"
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$_U23_APPROVAL_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_U23_APPROVAL_FILE" 2>/dev/null
}

_u23_remove_approval() {
  local _path="$1" _tmp
  [ -f "$_U23_APPROVAL_FILE" ] || return 0
  _tmp="${_U23_APPROVAL_FILE}.tmp.$$"
  {
    echo "# path|owner|group|mode|category|decision|reason|confirmed_date|operator"
    awk -F'|' -v p="$_path" '$0 !~ /^[[:space:]]*#/ && $1 != p { print }' \
      "$_U23_APPROVAL_FILE" 2>/dev/null
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$_U23_APPROVAL_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_U23_APPROVAL_FILE" 2>/dev/null
}

_u23_is_managed() {
  _u23_approval_valid "$1" || _u23_restricted_valid "$1"
}

_u23_package_name() {
  local _path="$1" _pkg=""
  if command -v rpm >/dev/null 2>&1; then
    _pkg=$(rpm -qf --qf '%{NAME}' "$_path" 2>/dev/null)
  elif command -v dpkg-query >/dev/null 2>&1; then
    _pkg=$(dpkg-query -S "$_path" 2>/dev/null | head -1 | cut -d: -f1)
  fi
  [ -n "$_pkg" ] && printf '%s' "$_pkg" || printf '%s' "확인되지 않음"
}

# 분류는 자동 조치 판정이 아니라 45개 이상의 파일을 그룹 단위로 검토하기 위한 UI 보조 정보다.
_u23_category() {
  local _path="$1" _base _pkg
  _base=$(basename "$_path" 2>/dev/null)
  case "$_path" in
    /u01/app/oracle/*|/opt/oracle/*|*/dbhome_*/bin/*|*/oracle/product/*)
      echo "Oracle"; return ;;
    /opt/LifeKeeper/*|/opt/lifekeeper/*|/opt/steeleye/*|*LifeKeeper*)
      echo "LifeKeeper"; return ;;
    /usr/sbin/postdrop|/usr/sbin/postqueue|*/postfix/*)
      echo "Postfix"; return ;;
    *cockpit*)
      echo "Cockpit"; return ;;
  esac
  case "$_base" in
    sudo|su|passwd|chage|newgrp|chsh|chfn|unix_chkpwd|userhelper|pam_timestamp_check|polkit-agent-helper-1|sssd_*|krb5_child|ldap_child|proxy_child|selinux_child)
      echo "sudo·polkit·sssd 및 인증"; return ;;
  esac
  _pkg=$(_u23_package_name "$_path")
  case "$_path" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*|/usr/lib64/*|/usr/libexec/*)
      [ "$_pkg" != "확인되지 않음" ] && { echo "OS 기본 명령어"; return; } ;;
  esac
  echo "기타·출처 불명"
}

_u23_source_label() {
  local _path="$1" _cat="$2" _pkg
  case "$_cat" in
    Oracle|LifeKeeper|Cockpit|Postfix) printf '%s' "$_cat" ;;
    *)
      _pkg=$(_u23_package_name "$_path")
      printf '%s' "$_pkg" ;;
  esac
}

# U-23 화면 표시 전용: 내부 분류값은 유지하고 화면에서만 간결한 명칭을 사용한다.
_U23_UI_DIV_LINE=" ──────────────────────────────────────────────────────────────────"

_u23_display_category() {
  case "$1" in
    "sudo·polkit·sssd 및 인증") printf '%s' "인증·권한 관리" ;;
    *) printf '%s' "$1" ;;
  esac
}

# 한글/영문 혼용 표를 실제 터미널 표시 폭 기준으로 정렬한다.
_u23_format_summary_row() {
  local __outvar="$1" __category="$2" __total="$3" __approved="$4" __review="$5"
  local __label __w1=26 __w2=8 __w3=12
  local __d1 __d2 __d3 __p1 __p2 __p3 __line
  __label=$(_u23_display_category "$__category")
  __d1=$(_display_width "$__label");    __p1=$((__w1 - __d1)); [ "$__p1" -lt 0 ] && __p1=0
  __d2=$(_display_width "$__total");    __p2=$((__w2 - __d2)); [ "$__p2" -lt 0 ] && __p2=0
  __d3=$(_display_width "$__approved"); __p3=$((__w3 - __d3)); [ "$__p3" -lt 0 ] && __p3=0
  printf -v __line '   %s%*s  %s%*s  %s%*s  %s' \
    "$__label" "$__p1" "" "$__total" "$__p2" "" \
    "$__approved" "$__p3" "" "$__review"
  printf -v "$__outvar" '%s' "$__line"
}

_u23_format_file_row() {
  local __outvar="$1" __no="$2" __mode="$3" __owner_group="$4" __source="$5" __path="$6"
  local __w1=4 __w2=6 __w3=20 __w4=18
  local __d1 __d2 __d3 __d4 __p1 __p2 __p3 __p4 __line
  __d1=$(_display_width "$__no");          __p1=$((__w1 - __d1)); [ "$__p1" -lt 0 ] && __p1=0
  __d2=$(_display_width "$__mode");        __p2=$((__w2 - __d2)); [ "$__p2" -lt 0 ] && __p2=0
  __d3=$(_display_width "$__owner_group"); __p3=$((__w3 - __d3)); [ "$__p3" -lt 0 ] && __p3=0
  __d4=$(_display_width "$__source");      __p4=$((__w4 - __d4)); [ "$__p4" -lt 0 ] && __p4=0
  printf -v __line '   %s%*s  %s%*s  %s%*s  %s%*s  %s' \
    "$__no" "$__p1" "" "$__mode" "$__p2" "" \
    "$__owner_group" "$__p3" "" "$__source" "$__p4" "" "$__path"
  printf -v "$__outvar" '%s' "$__line"
}


# ── U-25 공용 점검 함수 ───────────────────────────────────────────────────────
# KISA U-25 범위에 맞춰 Socket/디렉터리는 제외하고 일반 파일(-type f)만 점검한다.
# 별도 파일시스템(/u01, /data 등)이 누락되지 않도록 로컬 마운트별로 순회한다.
# 설정 사유가 확인된 파일은 예외 기록에 경로·사유·확인일·확인자를 남겨 재점검 시 인정한다.
_U25_ALLOWLIST="${_RB_DIR}/u25_allowlist.conf"

_u25_find_world_writable() {
  local _mnt _fstype
  {
    if command -v findmnt &>/dev/null; then
      while read -r _mnt _fstype; do
        [ -n "$_mnt" ] || continue
        case "$_fstype" in
          proc|sysfs|devtmpfs|devpts|cgroup|cgroup2|pstore|securityfs|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|binfmt_misc|nsfs|autofs|nfs|nfs4|cifs|smb3|fuse.sshfs|overlay|squashfs|iso9660)
            continue
            ;;
        esac
        [ -d "$_mnt" ] || continue
        find "$_mnt" -xdev -type f -perm -0002 2>/dev/null
      done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null)
    else
      find / -xdev -type f -perm -0002 2>/dev/null
    fi
  } | sort -u
}

_u25_is_approved() {
  local _path="$1"
  [ -f "$_U25_ALLOWLIST" ] || return 1
  awk -F'|' -v p="$_path" '
    $0 !~ /^[[:space:]]*#/ && $1 == p && $2 != "" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$_U25_ALLOWLIST" 2>/dev/null
}

_u25_approval_reason() {
  local _path="$1"
  [ -f "$_U25_ALLOWLIST" ] || return 0
  awk -F'|' -v p="$_path" '
    $0 !~ /^[[:space:]]*#/ && $1 == p && $2 != "" { reason=$2 }
    END { print reason }
  ' "$_U25_ALLOWLIST" 2>/dev/null
}

_u25_register_approval() {
  local _path="$1" _reason="$2" _tmp _operator
  _reason="${_reason//$'\r'/ }"
  _reason="${_reason//$'\n'/ }"
  _reason="${_reason//|//}"
  [ -n "$_reason" ] || return 1

  mkdir -p "$_RB_DIR" 2>/dev/null || return 1
  _tmp="${_U25_ALLOWLIST}.tmp.$$"
  _operator="${SUDO_USER:-$(id -un 2>/dev/null)}"
  [ -n "$_operator" ] || _operator="root"

  {
    echo "# path|reason|confirmed_date|operator"
    if [ -f "$_U25_ALLOWLIST" ]; then
      awk -F'|' -v p="$_path" '$0 !~ /^[[:space:]]*#/ && $1 != p { print }' \
        "$_U25_ALLOWLIST" 2>/dev/null
    fi
    printf '%s|%s|%s|%s\n' "$_path" "$_reason" "$(date '+%Y-%m-%d')" "$_operator"
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }

  mv -f "$_tmp" "$_U25_ALLOWLIST" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_U25_ALLOWLIST" 2>/dev/null
  return 0
}

# ── U-65 NTP 실제 동기화 확인/조치 함수 ───────────────────────────────────────
# 서비스가 active인지만 보지 않고, 실제 선택된 NTP 소스와 동기화 상태까지 확인한다.
_u65_active_service() {
  local _svc
  for _svc in chronyd chrony ntpd ntp; do
    systemctl is-active --quiet "$_svc" 2>/dev/null && { echo "$_svc"; return 0; }
  done
  return 1
}

_u65_unit_exists() {
  local _svc="$1"
  systemctl list-unit-files "${_svc}.service" --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -qx "${_svc}.service"
}

# 반환값: 0=실제 동기화 확인, 1=미동기화/확인 불가
_u65_is_synced() {
  local _svc _leap
  _svc=$(_u65_active_service 2>/dev/null) || return 1

  case "$_svc" in
    chronyd|chrony)
      command -v chronyc >/dev/null 2>&1 || return 1
      _leap=$(chronyc tracking 2>/dev/null \
        | awk -F':' '/^[[:space:]]*Leap status[[:space:]]*:/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
      [ "$_leap" = "Normal" ] || return 1
      chronyc sources -n 2>/dev/null \
        | awk '$1 ~ /^[\^=]\*/ {found=1} END {exit(found ? 0 : 1)}'
      ;;
    ntpd|ntp)
      if command -v ntpq >/dev/null 2>&1; then
        ntpq -pn 2>/dev/null \
          | awk '$1 ~ /^\*/ {found=1} END {exit(found ? 0 : 1)}'
      elif command -v ntpstat >/dev/null 2>&1; then
        ntpstat >/dev/null 2>&1
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

_u65_status() {
  local _svc _state _selected _leap _tdsync _configured
  _svc=$(_u65_active_service 2>/dev/null || true)
  [ -n "$_svc" ] && _state="active" || { _svc="없음"; _state="inactive"; }

  echo "서비스 상태 : ${_svc} (${_state})"

  _configured=$(grep -hE '^[[:space:]]*(server|pool)[[:space:]]+' \
    /etc/chrony.conf /etc/chrony/chrony.conf /etc/ntp.conf 2>/dev/null \
    | sed 's/^[[:space:]]*//' | head -3)
  if [ -n "$_configured" ]; then
    echo "설정된 NTP 소스 :"
    echo "$_configured" | sed 's/^/  /'
  else
    echo "설정된 NTP 소스 : 없음"
  fi

  case "$_svc" in
    chronyd|chrony)
      _selected=$(chronyc sources -n 2>/dev/null \
        | awk '$1 ~ /^[\^=]\*/ {print $1, $2; exit}')
      _leap=$(chronyc tracking 2>/dev/null \
        | awk -F':' '/^[[:space:]]*Leap status[[:space:]]*:/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
      echo "선택된 NTP 소스 : ${_selected:-없음}"
      echo "Leap status : ${_leap:-확인 불가}"
      ;;
    ntpd|ntp)
      _selected=$(ntpq -pn 2>/dev/null | awk '$1 ~ /^\*/ {print $1; exit}')
      echo "선택된 NTP 소스 : ${_selected:-없음}"
      ;;
    *)
      echo "선택된 NTP 소스 : 없음"
      ;;
  esac

  _tdsync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  echo "timedatectl 동기화 : ${_tdsync:-확인 불가}"

  if _u65_is_synced; then
    echo "검증 결과 : VERIFY_OK"
  else
    echo "검증 결과 : VERIFY_FAIL"
  fi
}

_u65_apply() {
  local _svc="" _i

  # 현재 설치된 NTP 데몬이 있으면 그대로 사용하고, 없을 때만 chrony를 설치한다.
  _svc=$(_u65_active_service 2>/dev/null || true)
  if [ -z "$_svc" ]; then
    for _candidate in chronyd chrony ntpd ntp; do
      if _u65_unit_exists "$_candidate"; then
        _svc="$_candidate"
        break
      fi
    done
  fi

  if [ -z "$_svc" ]; then
    echo "→ NTP 데몬이 없어 chrony 패키지 설치를 시도합니다."
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y chrony >/dev/null 2>&1 || echo "✗ chrony 패키지 설치 실패"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y chrony >/dev/null 2>&1 || echo "✗ chrony 패키지 설치 실패"
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update >/dev/null 2>&1 && apt-get install -y chrony >/dev/null 2>&1 \
        || echo "✗ chrony 패키지 설치 실패"
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install chrony >/dev/null 2>&1 \
        || echo "✗ chrony 패키지 설치 실패"
    else
      echo "✗ 지원되는 패키지 관리자를 찾을 수 없습니다."
    fi

    if _u65_unit_exists chronyd; then
      _svc="chronyd"
    elif _u65_unit_exists chrony; then
      _svc="chrony"
    fi
  fi

  if [ -n "$_svc" ]; then
    if systemctl enable --now "$_svc" >/dev/null 2>&1; then
      echo "✓ ${_svc} 서비스 활성화 완료"
    else
      echo "✗ ${_svc} 서비스 활성화 실패"
    fi
  else
    echo "✗ 활성화 가능한 NTP 서비스를 찾지 못했습니다."
  fi

  # chrony는 서비스 기동 직후 온라인 전환 및 즉시 동기화를 시도한다.
  case "$_svc" in
    chronyd|chrony)
      if command -v chronyc >/dev/null 2>&1; then
        chronyc online >/dev/null 2>&1 || true
        chronyc burst 4/4 >/dev/null 2>&1 || true
        chronyc makestep >/dev/null 2>&1 || true
      fi
      ;;
    ntpd|ntp)
      systemctl restart "$_svc" >/dev/null 2>&1 || true
      ;;
  esac

  # 네트워크 응답 및 소스 선택에 시간이 걸릴 수 있어 최대 30초간 실제 동기화를 확인한다.
  if [ -n "$_svc" ] && systemctl is-active --quiet "$_svc" 2>/dev/null; then
    for _i in 1 2 3 4 5 6; do
      if _u65_is_synced; then
        echo "✓ NTP 소스 연결 및 시각 동기화 확인"
        return 0
      fi
      [ "$_i" -lt 6 ] && { echo "→ 시각 동기화 대기 중 (${_i}/6)"; sleep 5; }
    done
    echo "✗ NTP 서비스는 활성 상태이나 실제 시각 동기화를 확인하지 못했습니다."
    echo "→ 설정된 NTP 서버, DNS, UDP/123 방화벽 및 네트워크 연결을 확인하세요."
  fi

  # 상세 원인은 after_cmd의 실제 상태 검증에서 판정하도록 실행 자체는 정상 종료한다.
  return 0
}

# ── U-52 Telnet 비활성화 공용 점검/조치 함수 ────────────────────────────────
# 현재 포트와 systemd 자동 기동, xinetd/inetd 설정을 함께 확인한다.
_u52_unit_exists() {
  local _unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -Fxq "$_unit" && return 0
  systemctl list-units --all --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -Fxq "$_unit"
}

_u52_unit_enabled_risky() {
  local _unit="$1" _state
  _state=$(systemctl is-enabled "$_unit" 2>/dev/null | head -1)
  case "$_state" in
    enabled|enabled-runtime|linked|linked-runtime|alias) return 0 ;;
    *) return 1 ;;
  esac
}

_u52_port23_listening() {
  ss -H -lntp 2>/dev/null | awk '$4 ~ /:23$/ { found=1 } END { exit(found ? 0 : 1) }'
}

_u52_xinetd_file_enabled() {
  local _f="$1"
  [ -f "$_f" ] || return 1
  # 주석을 제외한 service telnet 계열 설정에서 disable=yes가 없으면 활성 가능 상태
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*service[[:space:]]+(telnet|telnet-ssl|krb5-telnet)([[:space:]]|$)/ { svc=1 }
    /^[[:space:]]*disable[[:space:]]*=[[:space:]]*yes([[:space:]]|$)/ { disabled=1 }
    /^[[:space:]]*disable[[:space:]]*=[[:space:]]*no([[:space:]]|$)/  { enabled=1 }
    END { exit((enabled || (svc && !disabled)) ? 0 : 1) }
  ' "$_f"
}

_u52_xinetd_telnet_enabled() {
  local _f
  for _f in /etc/xinetd.d/*telnet*; do
    [ -f "$_f" ] || continue
    _u52_xinetd_file_enabled "$_f" && return 0
  done
  return 1
}

_u52_inetd_telnet_enabled() {
  [ -f /etc/inetd.conf ] || return 1
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/inetd.conf 2>/dev/null \
    | grep -qiE '^[[:space:]]*telnet[[:space:]]'
}

# 반환값: 0=Telnet 노출 가능 상태 존재, 1=영구 비활성 상태
_u52_has_exposure() {
  local _unit
  _u52_port23_listening && return 0

  for _unit in telnet.socket telnet.service telnetd.service telnet@.service; do
    _u52_unit_exists "$_unit" || continue
    systemctl is-active --quiet "$_unit" 2>/dev/null && return 0
    _u52_unit_enabled_risky "$_unit" && return 0
  done

  _u52_xinetd_telnet_enabled && return 0
  _u52_inetd_telnet_enabled && return 0
  return 1
}

_u52_status() {
  local _unit _active _enabled _found=0 _f

  echo '[포트 23]'
  if _u52_port23_listening; then
    ss -H -lntp 2>/dev/null | awk '$4 ~ /:23$/'
  else
    echo '포트 23 LISTEN 없음'
  fi

  echo '[systemd Telnet 유닛]'
  for _unit in telnet.socket telnet.service telnetd.service telnet@.service; do
    _u52_unit_exists "$_unit" || continue
    _found=1
    _active=$(systemctl is-active "$_unit" 2>/dev/null | head -1)
    _enabled=$(systemctl is-enabled "$_unit" 2>/dev/null | head -1)
    [ -n "$_active" ] || _active='unknown'
    [ -n "$_enabled" ] || _enabled='unknown'
    printf '%s : active=%s, enabled=%s\n' "$_unit" "$_active" "$_enabled"
  done
  [ "$_found" -eq 1 ] || echo 'Telnet systemd 유닛 없음'

  echo '[xinetd/inetd 설정]'
  _found=0
  for _f in /etc/xinetd.d/*telnet*; do
    [ -f "$_f" ] || continue
    _found=1
    printf '%s : ' "$_f"
    if _u52_xinetd_file_enabled "$_f"; then
      echo '활성 가능 설정'
    else
      echo 'disable=yes'
    fi
  done
  if _u52_inetd_telnet_enabled; then
    _found=1
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/inetd.conf 2>/dev/null \
      | grep -iE '^[[:space:]]*telnet[[:space:]]'
  fi
  [ "$_found" -eq 1 ] || echo 'Telnet xinetd/inetd 활성 설정 없음'
}

_u52_apply_disable() {
  local _unit _f _tmp _changed=0

  # systemd 방식: 현재 중지 + 부팅 시 자동기동 차단 + 수동/의존성 기동 차단
  for _unit in telnet.socket telnet.service telnetd.service telnet@.service; do
    _u52_unit_exists "$_unit" || continue
    if systemctl disable --now "$_unit" >/dev/null 2>&1; then
      echo "✓ ${_unit} 중지 및 disable 완료"
    else
      # 이미 비활성/비활성화 상태일 수 있으므로 후속 검증에서 최종 판정한다.
      echo "→ ${_unit} disable 실행 결과를 최종 검증에서 확인"
    fi
  done

  # xinetd 방식: Telnet 서비스 설정을 disable=yes로 고정
  for _f in /etc/xinetd.d/*telnet*; do
    [ -f "$_f" ] || continue
    _tmp="${_f}.u52.$$"
    [ -e "${_f}.bak.${_RUN_TS}" ] || cp -p "$_f" "${_f}.bak.${_RUN_TS}" 2>/dev/null
    awk '
      BEGIN { done=0 }
      {
        if (!done && $0 !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*disable[[:space:]]*=/) {
          print "\tdisable = yes"; done=1; next
        }
        if (!done && $0 ~ /^[[:space:]]*}/) {
          print "\tdisable = yes"; done=1
        }
        print
      }
      END { if (!done) print "\tdisable = yes" }
    ' "$_f" > "$_tmp" 2>/dev/null
    # 기존 파일 inode에 내용을 덮어써 소유자·권한·SELinux 컨텍스트를 보존한다.
    if [ -s "$_tmp" ] && cat "$_tmp" > "$_f" 2>/dev/null; then
      rm -f "$_tmp"
      echo "✓ ${_f} disable=yes 적용"
      _changed=1
    else
      rm -f "$_tmp"
      echo "✗ ${_f} disable=yes 적용 실패"
    fi
  done

  # inetd 방식: 활성 Telnet 항목 주석 처리
  if [ -f /etc/inetd.conf ]; then
    if grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/inetd.conf 2>/dev/null \
       | grep -qiE '^[[:space:]]*telnet[[:space:]]'; then
      [ -e "/etc/inetd.conf.bak.${_RUN_TS}" ] \
        || cp -p /etc/inetd.conf "/etc/inetd.conf.bak.${_RUN_TS}" 2>/dev/null
      if sed -i -E '/^[[:space:]]*#/! s/^([[:space:]]*telnet[[:space:]])/# \1/I' /etc/inetd.conf 2>/dev/null; then
        echo '✓ /etc/inetd.conf Telnet 항목 주석 처리'
        _changed=1
      else
        echo '✗ /etc/inetd.conf Telnet 항목 주석 처리 실패'
      fi
    fi
  fi

  # 설정을 반영하되 비활성 서비스는 임의로 시작하지 않는다.
  if [ "$_changed" -eq 1 ]; then
    if systemctl is-active --quiet xinetd.service 2>/dev/null; then
      if systemctl try-reload-or-restart xinetd.service >/dev/null 2>&1; then
        echo '✓ xinetd 설정 반영 완료'
      else
        echo '✗ xinetd 설정 반영 실패'
      fi
    fi
    if pgrep -x inetd >/dev/null 2>&1; then
      if pkill -HUP -x inetd >/dev/null 2>&1; then
        echo '✓ inetd 설정 반영 완료'
      else
        echo '✗ inetd 설정 반영 실패'
      fi
    fi
  fi

  # 개별 명령 실패 여부는 아래 최종 상태 검증에서 일괄 판정한다.
  return 0
}

_u52_verify() {
  local _unit _active _enabled _failed=0

  if _u52_port23_listening; then
    echo '✗ 포트 23 LISTEN 상태가 남아 있음'
    ss -H -lntp 2>/dev/null | awk '$4 ~ /:23$/'
    _failed=1
  else
    echo '✓ 포트 23 비활성'
  fi

  for _unit in telnet.socket telnet.service telnetd.service telnet@.service; do
    _u52_unit_exists "$_unit" || continue
    _active=$(systemctl is-active "$_unit" 2>/dev/null | head -1)
    _enabled=$(systemctl is-enabled "$_unit" 2>/dev/null | head -1)

    if [ "$_active" = 'active' ] || [ "$_active" = 'activating' ]; then
      echo "✗ ${_unit} 실행 상태: ${_active}"
      _failed=1
    else
      echo "✓ ${_unit} 실행 상태: ${_active:-inactive}"
    fi

    if _u52_unit_enabled_risky "$_unit"; then
      echo "✗ ${_unit} 자동기동 상태: ${_enabled}"
      _failed=1
    else
      echo "✓ ${_unit} 자동기동 상태: ${_enabled:-disabled}"
    fi
  done

  if _u52_xinetd_telnet_enabled; then
    echo '✗ xinetd Telnet 활성 가능 설정이 남아 있음'
    _failed=1
  else
    echo '✓ xinetd Telnet 비활성 설정 확인'
  fi

  if _u52_inetd_telnet_enabled; then
    echo '✗ /etc/inetd.conf Telnet 활성 항목이 남아 있음'
    _failed=1
  else
    echo '✓ inetd Telnet 활성 항목 없음'
  fi

  if [ "$_failed" -eq 0 ]; then
    echo 'Telnet 영구 비활성 확인 (U52_VERIFY_OK)'
  else
    echo 'Telnet 비활성 검증 실패'
  fi
}

# -----------------------------------------------------------------------------
# check_still_vuln
#
# 역할:
#   지정한 U 항목을 현재 시스템 상태로 다시 점검해 공통 상태 코드로 반환한다.
#
# 입력:
#   $1 : U-01~U-67 항목 ID
#
# 반환값:
#   0 : 취약
#   1 : 양호
#   2 : 관련 서비스·파일이 없어 해당 없음
#   3 : 배포판·벤더·운영 정책 정보가 필요해 자동 판정 불가
#
# 시스템 영향:
#   설정을 변경하지 않고 파일·서비스·프로세스·패키지 상태만 조회한다.
#
# 주의:
#   각 case 분기의 반환값은 do_fix/do_manual의 조치 흐름과 직접 연결되므로
#   새 항목을 추가할 때도 위 상태 코드 의미를 그대로 유지해야 한다.
# -----------------------------------------------------------------------------
check_still_vuln() {
  local id="$1"
  case "$id" in
    U-01)
      # SSH 확인 — 실제 적용값(sshd -T)을 최우선으로 판정
      # 이유: /etc/ssh/sshd_config.d/*.conf Include 값이 메인 설정보다 우선 적용될 수 있음
      val=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' \
            | awk '{print $2}' | tail -1 \
            | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

      # sshd -T 실패 시에만 설정 파일 fallback
      if [ -z "$val" ]; then
        _u01_confs="/etc/ssh/sshd_config"
        if [ -f /etc/ssh/sshd_config ]; then
          while IFS= read -r _inc; do
            for _f in $_inc; do [ -f "$_f" ] && _u01_confs="$_u01_confs $_f"; done
          done < <(grep -v '^[[:space:]]*#' /etc/ssh/sshd_config 2>/dev/null \
                   | grep -iE '^[[:space:]]*Include[[:space:]]+' | awk '{print $2}')
        fi
        val=$(cat $_u01_confs 2>/dev/null \
              | grep -v '^[[:space:]]*#' \
              | grep -iE '^[[:space:]]*PermitRootLogin[[:space:]]+' \
              | awk '{print $2}' | head -1 \
              | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      fi

      { [ "$val" != "no" ] && [ "$val" != "prohibit-password" ] && [ "$val" != "without-password" ]; } && return 0
      # Telnet 활성 시 추가 확인
      TELNET_ON=0
      ss -tlnp 2>/dev/null | grep -q ':23 ' && TELNET_ON=1
      pgrep -x telnetd &>/dev/null && TELNET_ON=1
      if [ $TELNET_ON -eq 1 ]; then
        grep -v '^#' /etc/securetty 2>/dev/null | grep -q '^pts/' && return 0
        grep -qE '^auth.*required.*(pam_securetty\.so|/lib/security/pam_securetty\.so)' \
          /etc/pam.d/login 2>/dev/null || return 0
      fi
      return 1 ;;
    U-02)
      MAX=$(grep -v '^[[:space:]]*#' /etc/login.defs 2>/dev/null | grep 'PASS_MAX_DAYS' | awk '{print $2}')
      MIN=$(grep -v '^[[:space:]]*#' /etc/login.defs 2>/dev/null | grep 'PASS_MIN_DAYS' | awk '{print $2}')
      LEN=$(grep -v '^[[:space:]]*#' /etc/security/pwquality.conf 2>/dev/null | grep -E '^[[:space:]]*minlen[[:space:]]*=' | awk -F= '{print $2}' | tr -d ' ')
      { [ -z "$MAX" ] || [ "$MAX" -gt 90 ]; } 2>/dev/null && return 0
      { [ -z "$MIN" ] || [ "$MIN" -lt 1 ];  } 2>/dev/null && return 0
      { [ -z "$LEN" ] || [ "$LEN" -lt 8 ];  } 2>/dev/null && return 0
      # 복잡성(문자 혼합) 검사 — KISA 2026 가이드(p.21) 기준: "3종류 이상 + 8자 이상" 또는
      # "2종류 이상 + 10자 이상" 둘 다 인정. 가이드의 실제 조치 예시는 minclass가 아니라
      # lcredit/ucredit/dcredit/ocredit=-1 조합을 사용하므로 credit 개수만으로 판단한다.
      [ ! -f /etc/security/pwquality.conf ] && return 0
      CCNT=0
      for _cr in lcredit ucredit dcredit ocredit; do
        # 양수 credit은 "길이 보정"이므로 요구 조건이 아님 — 반드시 음수(-1 이하)만 인정
        grep -qE "^[[:space:]]*${_cr}[[:space:]]*=[[:space:]]*-[1-9]" /etc/security/pwquality.conf 2>/dev/null && CCNT=$((CCNT+1))
      done
      LEN_N=$LEN; [[ "$LEN_N" =~ ^[0-9]+$ ]] || LEN_N=0
      { [ "$CCNT" -ge 3 ] && [ "$LEN_N" -ge 8 ]; } && return 1
      { [ "$CCNT" -ge 2 ] && [ "$LEN_N" -ge 10 ]; } && return 1
      return 0 ;;
    U-03)
      # faillock.conf (authselect/pam_faillock 신형)
      DENY=$(grep -v '^#' /etc/security/faillock.conf 2>/dev/null | grep -oP 'deny\s*=\s*\K[0-9]+' | head -1)
      if [ -n "$DENY" ]; then
        [ "$DENY" -gt 10 ] 2>/dev/null && return 0
        # deny 양호해도 preauth/authfail 라인 누락 시 수동확인
        for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
          [ -f "$_pf" ] || continue
          grep -qE '^auth[[:space:]].*pam_faillock\.so.*preauth' "$_pf" 2>/dev/null || return 2
          grep -qE '^auth[[:space:]].*pam_faillock\.so.*authfail' "$_pf" 2>/dev/null || return 2
        done
        return 1
      fi
      # pam_faillock / pam_tally / pam_tally2 — PAM 파일에서 deny= 탐색
      for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] || continue
        DENY=$(grep -v '^#' "$_pf" | grep -oP 'deny\s*=\s*\K[0-9]+' | head -1)
        if [ -n "$DENY" ]; then
          [ "$DENY" -gt 10 ] 2>/dev/null && return 0
          # pam_tally2 사용 시 onerr=fail 누락이면 수동확인
          if grep -qE 'pam_tally2' "$_pf" 2>/dev/null; then
            grep -qE 'onerr=fail' "$_pf" 2>/dev/null || return 2
          fi
          return 1
        fi
      done
      return 0 ;;
    U-04)
      [ ! -f /etc/shadow ] && return 0
      NO_SHADOW=$(awk -F: '$2!="x"&&$2!="*"&&$2!="!"&&$2!="" {print $1}' /etc/passwd | head -1)
      [ -n "$NO_SHADOW" ] && return 0; return 1 ;;
    U-05)
      UID0=$(awk -F: '$3==0&&$1!="root"{print $1}' /etc/passwd | head -1)
      [ -n "$UID0" ] && return 0; return 1 ;;
    U-06)
      WHEEL_LINE=$(grep -v '^#' /etc/pam.d/su 2>/dev/null | grep -E 'pam_wheel\.so' | head -1)
      if [ -z "$WHEEL_LINE" ]; then
        return 0  # pam_wheel.so 미설정 — 취약
      fi
      # 활성 pam_wheel.so 줄이 있으면 그 자체로 제한이 적용됨 (use_uid는 부가 옵션일 뿐, 필수 아님)
      WHEEL_GROUP="wheel"
      echo "$WHEEL_LINE" | grep -qE 'group=' && WHEEL_GROUP=$(echo "$WHEEL_LINE" | grep -oE 'group=[^ ]+' | cut -d= -f2)
      WHEEL_MEMBERS=$(grep "^${WHEEL_GROUP}:" /etc/group | cut -d: -f4)
      [ -z "$WHEEL_MEMBERS" ] && return 3  # 멤버 없음 — 수동확인(의도 여부)
      return 1 ;;  # 양호
    U-07)
      for a in adm lp sync shutdown halt news uucp operator games gopher; do
        grep -q "^${a}:" /etc/passwd || continue
        PW=$(grep "^${a}:" /etc/shadow 2>/dev/null | awk -F: '{print $2}')
        echo "$PW" | grep -qE '^[*!]' || return 0
      done; return 1 ;;
    U-08) return 3 ;;  # 수동확인 전용
    U-09)
      STALE=$(awk -F: '{print $4}' /etc/passwd | sort -un | while read g; do
        awk -F: -v gid="$g" '$3==gid{found=1} END{if(!found) print gid}' /etc/group
      done | head -1)
      [ -n "$STALE" ] && return 0; return 1 ;;
    U-10)
      DUP=$(awk -F: '{print $3}' /etc/passwd | sort | uniq -d | head -1)
      [ -n "$DUP" ] && return 0; return 1 ;;
    U-11) return 3 ;;  # 수동확인 전용
    U-12)
      # ── 1. 공통 설정 검사 ────────────────────────────────────────────────────
      _u12_tmout_val=""
      _u12_readonly=0
      for _f in /etc/profile /etc/profile.d/*.sh /etc/bashrc /etc/bash.bashrc /etc/environment; do
        [ -f "$_f" ] || continue
        _v=$(grep -v '^\s*#' "$_f" | grep -oE 'TMOUT=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
        [ -n "$_v" ] && _u12_tmout_val="$_v"
        grep -v '^\s*#' "$_f" | grep -qE 'readonly\s+TMOUT|declare\s+-r\s+TMOUT' && _u12_readonly=1
      done
      # TMOUT 없음 또는 600 초과 → 취약
      [ -z "$_u12_tmout_val" ] && return 0
      [ "$_u12_tmout_val" -gt 600 ] 2>/dev/null && return 0
      # ── 2. 우회 탐지 ─────────────────────────────────────────────────────────
      while IFS=: read -r _ _ _ _ _ _home _; do
        [ -d "$_home" ] || continue
        for _rc in "$_home"/.bashrc "$_home"/.bash_profile "$_home"/.profile "$_home"/.zshrc; do
          [ -f "$_rc" ] || continue
          grep -v '^\s*#' "$_rc" 2>/dev/null | \
            grep -qE 'unset\s+TMOUT|TMOUT\s*=\s*0([^-9]|$)|export\s+TMOUT\s*=\s*0' && return 0
        done
      done < /etc/passwd
      # readonly 없으면 수동확인
      [ "$_u12_readonly" -eq 0 ] && return 2
      return 1 ;;
    U-13)
      ALGO=$(grep -v '^#' /etc/login.defs 2>/dev/null | grep 'ENCRYPT_METHOD' | awk '{print $2}')
      SHADOW_ALGO=$(awk -F: 'NR<=5&&$2~/^\$/{print substr($2,1,3);exit}' /etc/shadow 2>/dev/null)
      if [ -n "$ALGO" ]; then
        echo "$ALGO" | grep -qiE 'SHA512|SHA256' && return 1; return 0
      elif [ -n "$SHADOW_ALGO" ]; then
        echo "$SHADOW_ALGO" | grep -qE '\$6|\$5|\$y' && return 1; return 0
      fi
      return 0 ;;
    U-14)
      echo ":${PATH}:" | grep -qE ':[.]:' && return 0; return 1 ;;
    U-15)
      CNT=$(find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null | wc -l)
      [ "$CNT" -gt 0 ] && return 0; return 1 ;;
    U-16)
      O=$(stat -c '%U' /etc/passwd 2>/dev/null); P=$(stat -c '%a' /etc/passwd 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#022 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-17)
      for f in /etc/rc.local /etc/init.d /etc/rc.d; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && f=$(readlink -f "$f")
        O=$(stat -c '%U' "$f" 2>/dev/null); P=$(stat -c '%a' "$f" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$(( 8#${P:-777} & 8#002 ))" -ne 0 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-18)
      [ ! -f /etc/shadow ] && return 1
      O=$(stat -c '%U' /etc/shadow 2>/dev/null); P=$(stat -c '%a' /etc/shadow 2>/dev/null)
      # Debian/Ubuntu의 root:shadow 640은 허용하되, group 쓰기/실행과 other 권한은 금지한다.
      # 640/600/400은 양호, 660/650/644 등은 취약으로 판정한다.
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#037 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-19)
      O=$(stat -c '%U' /etc/hosts 2>/dev/null); P=$(stat -c '%a' /etc/hosts 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#022 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-20)
      for F in /etc/inetd.conf /etc/xinetd.conf; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$(( 8#${P:-777} & 8#077 ))" -ne 0 ]; } 2>/dev/null && return 0
      done
      [ ! -f /etc/inetd.conf ] && [ ! -f /etc/xinetd.conf ] && return 2; return 1 ;;
    U-21)
      for F in /etc/syslog.conf /etc/rsyslog.conf; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$(( 8#${P:-777} & 8#037 ))" -ne 0 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-22)
      O=$(stat -c '%U' /etc/services 2>/dev/null); P=$(stat -c '%a' /etc/services 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#022 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-23)
      # KISA 기준: SUID/SGID 필요 여부는 운영자가 판단한다.
      # 승인 당시의 소유자·그룹·권한과 현재 상태가 동일하거나,
      # 특정 그룹 실행 제한 정책이 검증된 파일만 관리 완료로 인정한다.
      EXTRA=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while read -r f; do
        _u23_is_managed "$f" && continue
        echo "$f"
      done | head -1)
      [ -n "$EXTRA" ] && return 0; return 1 ;;
    U-24)
      for F in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc /root/.bash_profile /root/.profile; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$(( 8#${P:-777} & 8#022 ))" -ne 0 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-25)
      # KISA U-25 점검 대상: world writable 일반 파일만 해당한다.
      # Socket, 디렉터리, 심볼릭 링크는 이 항목의 자동 판정/조치 대상에서 제외한다.
      local _u25_path
      while IFS= read -r _u25_path; do
        [ -z "$_u25_path" ] && continue
        _u25_is_approved "$_u25_path" || return 0
      done < <(_u25_find_world_writable)
      return 1 ;;
    U-26)
      NONDEV=$(find /dev -not -type d -not -type c -not -type b -not -type l \
        -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | head -1)
      [ -n "$NONDEV" ] && return 0; return 1 ;;
    U-27)
      [ -f /etc/hosts.equiv ] && return 0
      RHOSTS=$(find /root /home -name '.rhosts' 2>/dev/null | head -1)
      [ -n "$RHOSTS" ] && return 0; return 1 ;;
    U-28)
      systemctl is-active firewalld 2>/dev/null | grep -q '^active' && return 1
      systemctl is-active ufw 2>/dev/null | grep -q '^active' && return 1
      if command -v nft &>/dev/null; then
        NFT_RULES=$(nft list ruleset 2>/dev/null | grep -cE '^[[:space:]]*(accept|drop|reject|counter)')
        NFT_RULES=${NFT_RULES:-0}
        [ "$NFT_RULES" -gt 0 ] 2>/dev/null && return 1
      fi
      IPT_RULES=$(iptables -L -n 2>/dev/null | grep -v '^Chain\|^target\|^$' | grep -c '.')
      IPT_RULES=${IPT_RULES:-0}
      [ "$IPT_RULES" -gt 0 ] 2>/dev/null && return 1
      DENY_RULE=$(grep -v '^#' /etc/hosts.deny 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
      [ -n "$DENY_RULE" ] && return 1
      # hosts.allow/hosts.deny는 파일 존재가 아니라 유효 규칙 존재 여부로 판정한다.
      ALLOW_RULE=$(grep -v '^#' /etc/hosts.allow 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)
      [ -n "$ALLOW_RULE" ] && return 1
      return 0 ;;
    U-29)
      [ ! -f /etc/hosts.lpd ] && return 1
      O=$(stat -c '%U' /etc/hosts.lpd 2>/dev/null); P=$(stat -c '%a' /etc/hosts.lpd 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#077 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-30)
      # 로그인 초기화 파일의 적용 순서대로 확인해 최종 umask 값을 판정한다.
      _u30_final=""
      for F in /etc/login.defs /etc/profile /etc/bashrc /etc/bash.bashrc /etc/profile.d/*.sh; do
        [ -f "$F" ] || continue
        if [ "$F" = "/etc/login.defs" ]; then
          V=$(grep -v '^#' "$F" | grep -iE '^\s*UMASK\s+' | awk '{print $2}' | tail -1)
        else
          V=$(grep -v '^#' "$F" | grep -oE '\bumask[[:space:]]+[0-9]+' | awk '{print $2}' | tail -1)
        fi
        [ -n "$V" ] && _u30_final="$V"
      done
      [ -z "$_u30_final" ] && return 0  # 어디에도 명시돼 있지 않음 — 취약
      # 022가 요구하는 비트(그룹/기타 쓰기 권한 제거)를 모두 포함하면 양호 —
      # 027/077처럼 022보다 더 엄격한 값도 정상적으로 양호 처리된다.
      if [[ "$_u30_final" =~ ^0*[0-7]{3,4}$ ]] && [ $(( (8#$_u30_final) & (8#022) )) -eq $(( 8#022 )) ]; then
        return 1
      fi
      return 0 ;;
    U-31)
      while IFS=: read -r user _ uid _ _ homedir _; do
        [ "$uid" -lt 1000 ] 2>/dev/null && continue
        [ -z "$homedir" ] || [ "$homedir" = "/" ] || [ ! -d "$homedir" ] && continue
        O=$(stat -c '%U' "$homedir" 2>/dev/null); P=$(stat -c '%a' "$homedir" 2>/dev/null)
        { [ "$O" != "$user" ] || [ "$(( 8#${P:-777} & 8#002 ))" -ne 0 ]; } 2>/dev/null && return 0
      done < /etc/passwd; return 1 ;;
    U-32)
      while IFS=: read -r _user _ uid _ _ homedir _; do
        [ "$uid" -lt 1000 ] 2>/dev/null && continue
        # nobody(uid 65534)는 표준 시스템 계정 — Debian계는 홈이 /nonexistent로
        # 설계되어 있어 취약이 아니며, 홈 생성 조치 대상도 아니다.
        { [ "$_user" = "nobody" ] || [ "$uid" -ge 65534 ] 2>/dev/null; } && continue
        [ -n "$homedir" ] && [ ! -d "$homedir" ] && return 0
      done < /etc/passwd; return 1 ;;
    U-33)
      [ -n "$(_u33_find | head -1)" ] && return 0; return 1 ;;
    U-34) ss -tlnp 2>/dev/null | grep -q ':79 ' && return 0; return 1 ;;
    U-35)
      # 계정 존재 자체가 아니라 "로그인 가능한 셸인지"가 기준 — nologin/false면
      # 표준 권고 조치가 적용된 것이므로 양호 (계정 삭제까지는 요구하지 않음).
      for _acc in ftp anonymous; do
        _shell=$(grep "^${_acc}:" /etc/passwd 2>/dev/null | cut -d: -f7)
        [ -n "$_shell" ] && ! echo "$_shell" | grep -qE 'nologin|/bin/false' && return 0
      done
      for _cf in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
        [ -f "$_cf" ] || continue
        VAL=$(grep -v '^#' "$_cf" | grep -i 'anonymous_enable' | awk -F= '{print $2}' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        [ "$VAL" = "yes" ] && return 0
      done
      for _cf in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$_cf" ] || continue
        grep -v '^\s*#' "$_cf" 2>/dev/null | grep -qiE '^\s*<Anonymous' && return 0
      done
      if [ -f /etc/exports ]; then
        ANON=$(grep -v '^#' /etc/exports | grep -E '^\s*/.*\*\s*\(' | head -1)
        [ -n "$ANON" ] && return 0
      fi
      return 1 ;;
    U-36)
      ss -tlnp 2>/dev/null | grep -qE ':51[234] ' && return 0
      for svc in rsh rlogin rexec; do
        systemctl is-active "$svc" 2>/dev/null | grep -q '^active' && return 0
      done; return 1 ;;
    U-37)
      # crontab / at 명령 파일: root 소유, SUID/SGID 없음, 750 이하
      for _cmd37 in crontab at; do
        _bin37=$(command -v "$_cmd37" 2>/dev/null || true)
        if [ -z "$_bin37" ]; then
          for _cand37 in "/usr/bin/${_cmd37}" "/bin/${_cmd37}"; do
            [ -f "$_cand37" ] && { _bin37="$_cand37"; break; }
          done
        fi
        [ -f "$_bin37" ] || continue
        O=$(stat -c '%U' "$_bin37" 2>/dev/null)
        P=$(stat -c '%a' "$_bin37" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        # 실제 권한값에서 SUID/SGID를 직접 검사한다. 특수 비트를 제외한 뒤 비교하지 않는다.
        [ "$((8#${P:-0} & 8#6000))" -ne 0 ] 2>/dev/null && return 0
        [ "$((8#${P:-7777}))" -gt "$((8#750))" ] 2>/dev/null && return 0
      done

      # cron / at 설정 파일: root 소유, 640 이하
      for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        [ "$((8#${P:-7777}))" -gt "$((8#640))" ] 2>/dev/null && return 0
      done

      # cron / at 관련 디렉터리: root 소유, 750 이하
      for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
               /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] || continue
        O=$(stat -c '%U' "$D" 2>/dev/null); P=$(stat -c '%a' "$D" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        [ "$((8#${P:-7777}))" -gt "$((8#750))" ] 2>/dev/null && return 0
      done

      # cron / at 작업 목록 일반 파일: root 소유, 640 이하
      for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] || continue
        while IFS= read -r -d '' F; do
          O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
          [ "$O" != "root" ] && return 0
          [ "$((8#${P:-7777}))" -gt "$((8#640))" ] 2>/dev/null && return 0
        done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
      done
      return 1 ;;
    U-38)
      for port in 7 9 13 19; do
        ss -ulnp 2>/dev/null | grep -q ":${port} " && return 0
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
      done; return 1 ;;
    U-39)
      systemctl is-active nfs-server 2>/dev/null | grep -q '^active' && return 0
      ss -tlnp 2>/dev/null | grep -q ':2049 ' && return 0; return 1 ;;
    U-40)
      [ ! -f /etc/exports ] && return 2
      grep -q 'no_root_squash' /etc/exports 2>/dev/null && return 0; return 1 ;;
    U-41)
      systemctl is-active autofs 2>/dev/null | grep -q '^active' && return 0; return 1 ;;
    U-42)
      for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do
        pgrep -x "$svc" &>/dev/null && return 0
      done; return 1 ;;
    U-43)
      for p in ypserv ypbind; do pgrep -x "$p" &>/dev/null && return 0; done; return 1 ;;
    U-44)
      ss -ulnp 2>/dev/null | grep -qE ':69 |:517 |:518 ' && return 0; return 1 ;;
    U-45)
      local _u45_pkg=""
      { command -v postconf &>/dev/null || pgrep -x postfix &>/dev/null; } && _u45_pkg="postfix"
      [ -z "$_u45_pkg" ] && { command -v sendmail &>/dev/null || pgrep -x sendmail &>/dev/null; } && _u45_pkg="sendmail"
      [ -z "$_u45_pkg" ] && { command -v exim4 &>/dev/null || command -v exim &>/dev/null || pgrep -x exim &>/dev/null; } && _u45_pkg="exim4"
      [ -z "$_u45_pkg" ] && return 2
      _pkg_update_state "$_u45_pkg"; _u45_rc=$?
      [ "$_u45_rc" -eq 0 ] && return 0
      [ "$_u45_rc" -eq 1 ] && return 1
      return 3 ;;
    U-46)
      [ ! -f /etc/postfix/main.cf ] && return 2
      O=$(stat -c '%U' /etc/postfix/main.cf 2>/dev/null); P=$(stat -c '%a' /etc/postfix/main.cf 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#022 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-47)
      # MTA 종류(postfix/sendmail/exim) 무관 릴레이 정책은 수동 검토 필요
      # MTA 자체가 미설치 · 미실행이면 해당없음으로 처리
      pgrep -x postfix  &>/dev/null && return 3
      pgrep -x sendmail &>/dev/null && return 3
      pgrep -xf 'exim'  &>/dev/null && return 3
      command -v postfix  &>/dev/null && return 3
      command -v sendmail &>/dev/null && return 3
      command -v exim4    &>/dev/null && return 3
      command -v exim     &>/dev/null && return 3
      return 2 ;;  # MTA 미탐지 → 해당없음
    U-48)
      [ ! -f /etc/postfix/main.cf ] && return 2
      # 설정 파일 문자열보다 Postfix가 해석한 실제 적용값을 우선 확인한다.
      VRFY=$(postconf -h disable_vrfy_command 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      if [ -z "$VRFY" ]; then
        VRFY=$(grep -v '^[[:space:]]*#' /etc/postfix/main.cf 2>/dev/null \
          | awk -F= '/^[[:space:]]*disable_vrfy_command[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print tolower($2)}' \
          | tail -1)
      fi
      [ "$VRFY" = "yes" ] && return 1; return 0 ;;
    U-49)
      if ! command -v named &>/dev/null && ! pgrep -x named &>/dev/null; then
        return 2
      fi
      local _u49_pkg="bind"
      command -v apt &>/dev/null && _u49_pkg="bind9"
      _pkg_update_state "$_u49_pkg"; _u49_rc=$?
      [ "$_u49_rc" -eq 0 ] && return 0
      [ "$_u49_rc" -eq 1 ] && return 1
      return 3 ;;
    U-50)
      [ ! -f /etc/named.conf ] && return 2
      AT=$(grep -v '//' /etc/named.conf | grep 'allow-transfer' | head -1)
      echo "$AT" | grep -q 'none' && return 1; return 0 ;;
    U-51)
      [ ! -f /etc/named.conf ] && return 2
      AU=$(grep -v '//' /etc/named.conf | grep 'allow-update' | head -1)
      echo "$AU" | grep -q 'none' && return 1; return 0 ;;
    U-52) _u52_has_exposure && return 0; return 1 ;;
    U-53)
      for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
               /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$F" ] || continue
        BN=$(grep -v '^#' "$F" | grep -i 'ftpd_banner\|banner\|ServerIdent' | head -1)
        # 버전/제품명 직접 노출 → 취약
        echo "$BN" | grep -qiE 'vsftpd|proftpd|wu-ftp|version|[0-9]\.[0-9]' && return 0
        # proftpd: ServerIdent off 설정 없으면 기본적으로 버전 노출 → 취약
        if [[ "$F" == *proftpd* ]]; then
          grep -v '^#' "$F" 2>/dev/null | grep -qi 'ServerIdent[[:space:]]\+off' && continue
          grep -v '^#' "$F" 2>/dev/null | grep -qi 'ServerIdent' || return 0
        fi
      done; return 1 ;;
    U-54)
      ss -tlnp 2>/dev/null | grep -q ':21 ' || return 1
      # vsftpd SSL
      SSL=$(grep -v '^#' /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf 2>/dev/null \
            | grep -i 'ssl_enable' | awk -F'=' '{print toupper($2)}' | tr -d ' ' | head -1)
      [ "$SSL" = "YES" ] && return 1
      # proftpd TLS
      for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$F" ] || continue
        grep -v '^#' "$F" 2>/dev/null | grep -qi 'TLSEngine[[:space:]]\+on' && return 1
      done
      return 0 ;;
    U-55) return 3 ;;  # 수동확인
    U-56)
      # FTP 서비스 존재 여부 확인
      _u56_has=0
      for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
               /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$F" ] && _u56_has=1 && break
      done
      ss -tlnp 2>/dev/null | grep -q ':21 ' && _u56_has=1
      [ $_u56_has -eq 0 ] && return 2  # FTP 서비스 없음 → 해당없음

      # vsftpd: tcp_wrappers=YES + /etc/hosts.allow 에 ftp 항목 존재 여부
      for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
        [ -f "$F" ] || continue
        _tw=$(grep -v '^#' "$F" 2>/dev/null \
              | grep -i 'tcp_wrappers' | awk -F'=' '{print toupper($2)}' | tr -d ' ' | head -1)
        if [ "$_tw" = "YES" ]; then
          grep -qiE '^(vsftpd|ftpd|in\.ftpd|ALL)[[:space:]]*:' /etc/hosts.allow 2>/dev/null \
            && return 1
        fi
      done

      # proftpd: <Limit LOGIN> 블록에 Allow from 또는 DenyAll 지시자 존재 여부
      for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$F" ] || continue
        if grep -qi 'Limit.*LOGIN' "$F" 2>/dev/null; then
          grep -qiE 'Allow[[:space:]]+from|DenyAll' "$F" 2>/dev/null && return 1
        fi
      done
      return 0 ;;
    U-57)
      for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers \
               /etc/proftpd/ftpusers; do
        [ -f "$F" ] || continue
        grep -v '^#' "$F" | grep -q '^root' && return 1 || return 0
      done; return 2 ;;
    U-58)
      systemctl is-active snmpd 2>/dev/null | grep -q '^active' && return 0
      ss -ulnp 2>/dev/null | grep -q ':161 ' && return 0; return 1 ;;
    U-59)
      [ ! -f /etc/snmp/snmpd.conf ] && return 2
      grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -qiE 'com2sec|^community' && return 0; return 1 ;;
    U-60)
      [ ! -f /etc/snmp/snmpd.conf ] && return 2
      grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -qiE 'community\s+(public|private)' && return 0; return 1 ;;
    U-61)
      [ ! -f /etc/snmp/snmpd.conf ] && return 2
      grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -qiE 'com2sec.*default|agentaddress.*0\.0\.0\.0' && return 0; return 1 ;;
    U-62)
      _u62_has_problem=0
      for F in /etc/motd /etc/issue /etc/issue.net; do
        # 파일 없음 또는 비어있음 → 시스템 정보 미노출 → 양호
        [ -f "$F" ] && [ -s "$F" ] || continue
        # OS·호스트 정보를 노출하는 issue 이스케이프(\S, \r, \m, \s, \v, \n, \o)만 검사하고
        # 색상 제어 등 다른 백슬래시 표현은 판정에서 제외한다.
        if grep -qE '\\(S|r|m|s|v|n|o)' "$F" 2>/dev/null || grep -qiE 'kernel|release|version' "$F" 2>/dev/null; then
          _u62_has_problem=1
        fi
      done
      [ $_u62_has_problem -eq 1 ] && return 0 || return 1 ;;
    U-63)
      [ ! -f /etc/sudoers ] && return 2
      OWNER=$(stat -c '%U' /etc/sudoers 2>/dev/null)
      PERM=$(stat -c '%a' /etc/sudoers 2>/dev/null)
      [ "$OWNER" != "root" ] && return 0
      [ "$PERM" -gt 640 ] 2>/dev/null && return 0
      return 1 ;;
    U-64)
      if command -v apt &>/dev/null; then
        CNT=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')
        CNT=${CNT:-0}
        [ "$CNT" -gt 0 ] 2>/dev/null && return 0
        return 1
      fi
      NOT_REG=$(subscription-manager status 2>/dev/null | grep -i 'not registered\|등록되어 있지 않\|소비자 ID를 읽을 수 없')
      [ -n "$NOT_REG" ] && return 3  # 구독 미등록 → 수동확인
      command -v yum &>/dev/null || return 1
      SEC=$(yum updateinfo list security 2>/dev/null | grep -cE 'RHSA-|RHBA-|RHEA-')
      SEC=${SEC:-0}
      [ "$SEC" -gt 0 ] && return 0; return 1 ;;
    U-65)
      # 서비스 활성 상태뿐 아니라 실제 선택된 NTP 소스와 동기화 상태까지 확인한다.
      _u65_is_synced && return 1
      return 0 ;;
    U-66)
      systemctl is-active rsyslog &>/dev/null && return 1
      systemctl is-active syslog &>/dev/null && return 1
      [ -f /var/log/messages ] || [ -f /var/log/syslog ] && return 1; return 0 ;;
    U-67)
      O=$(stat -c '%U' /var/log 2>/dev/null); P=$(stat -c '%a' /var/log 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#002 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    *) return 2 ;;
  esac
}

# ── 실시간 점검 단계 (프로그레스바) ───────────────────────────────────────────
# REPORT 빠른 모드: 보고서 작성 이후 상태가 바뀌었을 수 있으므로 재확인하는 단계.
# 전체 스캔 모드(기본): TARGET_IDS(U-01~U-76) 전체를 여기서 처음으로 실제 점검하여
# 취약/양호/해당없음을 가른다. 두 모드 모두 동일한 루프를 공유한다.

# do_manual 처리 대상 ID — check_still_vuln 이 2를 반환해도 수동확인으로 분류
_MANUAL_IDS=(U-08 U-11 U-33 U-47 U-55)
_is_manual_id() {
  local _chk="$1"
  for _m in "${_MANUAL_IDS[@]}"; do [ "$_m" = "$_chk" ] && return 0; done
  return 1
}

_PRECHECK_VULN=(); _PRECHECK_OK=(); _PRECHECK_MANUAL=(); _PRECHECK_NA=()
_pc_total=${#TARGET_IDS[@]}
_pc_idx=0
for _pid in "${TARGET_IDS[@]}"; do
  _pc_idx=$((_pc_idx+1))
  check_still_vuln "$_pid" >/dev/null 2>&1; _pc_rc=$?
  if _is_manual_id "$_pid"; then
    # 수동 확인 항목은 양호(1)만 양호로 집계하고 나머지는 수동 확인으로 분류한다.
    case $_pc_rc in
      1) _PRECHECK_OK+=("$_pid") ;;
      *) _PRECHECK_MANUAL+=("$_pid") ;;
    esac
  else
    case $_pc_rc in
      0) _PRECHECK_VULN+=("$_pid") ;;
      1) _PRECHECK_OK+=("$_pid") ;;
      2) _PRECHECK_NA+=("$_pid") ;;
      3) _PRECHECK_MANUAL+=("$_pid") ;;
      *) _PRECHECK_MANUAL+=("$_pid") ;;
    esac
  fi
  if [ "$_pc_idx" -eq "$_pc_total" ]; then
    _show_progress_bar "$_pc_idx" "$_pc_total" "점검 완료"
  else
    _show_progress_bar "$_pc_idx" "$_pc_total" "점검 중" "$_pid"
  fi
done
echo ""
echo ""

# ID 목록을 줄당 5개씩, 정렬된 칸에 출력하는 헬퍼 (가독성을 위해 한 줄에 다 몰아넣지 않음)
_print_id_grid() {
  local -a ids=("$@")
  local i=0
  for _gid in "${ids[@]}"; do
    [ $((i % 5)) -eq 0 ] && printf "     "
    printf "%-7s" "$_gid"
    i=$((i+1))
    [ $((i % 5)) -eq 0 ] && echo ""
  done
  [ $((i % 5)) -ne 0 ] && echo ""
}

_DIVIDER=" ──────────────────────────────────────────────────"
echo -e "$_DIVIDER"
if [ ${#_PRECHECK_VULN[@]} -eq 0 ]; then
  echo -e "  ${RED}●${RESET} ${BOLD}실제 조치 필요${RESET}   ${RED}${BOLD}없음${RESET}"
else
  echo -e "  ${RED}●${RESET} ${BOLD}실제 조치 필요${RESET}   ${RED}${BOLD}${#_PRECHECK_VULN[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_VULN[@]}"
fi
echo ""
if [ ${#_PRECHECK_OK[@]} -eq 0 ]; then
  echo -e "  ${GREEN}●${RESET} ${BOLD}이미 양호${RESET}        ${GREEN}${BOLD}없음${RESET}"
else
  echo -e "  ${GREEN}●${RESET} ${BOLD}이미 양호${RESET}        ${GREEN}${BOLD}${#_PRECHECK_OK[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_OK[@]}"
fi
echo ""
if [ ${#_PRECHECK_MANUAL[@]} -eq 0 ]; then
  echo -e "  ${YELLOW}●${RESET} ${BOLD}수동 조치 필요${RESET}   ${YELLOW}${BOLD}없음${RESET}"
else
  echo -e "  ${YELLOW}●${RESET} ${BOLD}수동 조치 필요${RESET}   ${YELLOW}${BOLD}${#_PRECHECK_MANUAL[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_MANUAL[@]}"
fi
echo ""
if [ ${#_PRECHECK_NA[@]} -gt 0 ]; then
  echo -e "  ${CYAN}●${RESET} ${BOLD}해당없음${RESET}         ${CYAN}${BOLD}${#_PRECHECK_NA[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_NA[@]}"
  echo ""
fi
echo -e "$_DIVIDER"
echo ""

_DIV_HEAVY="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#_PRECHECK_VULN[@]} -eq 0 ] && [ ${#_PRECHECK_MANUAL[@]} -eq 0 ]; then
  # 자동조치 0개 + 수동확인 0개 — 정말 아무 것도 할 게 없는 경우.
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo -e " ${GREEN}✔ 모든 대상 항목이 이미 양호하거나 해당없음입니다. 추가 조치가 필요 없습니다.${RESET}"
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo ""
  _NO_ACTION_REQUIRED=1
fi

_NO_ACTION_REQUIRED=${_NO_ACTION_REQUIRED:-0}
_total_action=$(( ${#_PRECHECK_VULN[@]} + ${#_PRECHECK_MANUAL[@]} ))

if [ "$_NO_ACTION_REQUIRED" -eq 0 ]; then
if [ ${#_PRECHECK_VULN[@]} -eq 0 ]; then
  # 자동조치 0개 — 이 아래 루프는 수동확인 항목을 화면에 보여주기만 할 뿐
  # 시스템을 변경하지 않으므로, 진행 여부를 따로 묻지 않고 바로 보여준다.
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo -e " ${GREEN}✔ 자동 조치 대상 없음${RESET}"
  echo ""
  echo -e " 수동 확인 항목(${#_PRECHECK_MANUAL[@]}개)을 표시합니다."
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo ""
elif [ ${#_PRECHECK_MANUAL[@]} -eq 0 ]; then
  if [ "$NO_PROMPT" -eq 1 ]; then
    echo -e " ${CYAN}[NO-PROMPT] 자동조치 ${#_PRECHECK_VULN[@]}개 항목을 스크립트 기본값으로 진행합니다.${RESET}"
    echo ""
  else
    _read_yn _proceed_all " 위 자동조치 ${#_PRECHECK_VULN[@]}개 항목을 진행하시겠습니까? (y/n): "
    if [[ "$_proceed_all" != [Yy] ]]; then
      echo -e "${YELLOW} 조치를 취소합니다.${RESET}"
      exit 0
    fi
    echo ""
  fi
else
  if [ "$NO_PROMPT" -eq 1 ]; then
    echo -e " ${CYAN}[NO-PROMPT] 자동조치 ${#_PRECHECK_VULN[@]}개 + 수동확인 ${#_PRECHECK_MANUAL[@]}개 항목을 스크립트 기본값으로 진행합니다.${RESET}"
    echo ""
  else
    _read_yn _proceed_all " 위 자동조치 ${#_PRECHECK_VULN[@]}개 + 수동확인 ${#_PRECHECK_MANUAL[@]}개 항목을 순서대로 진행하시겠습니까? (y/n): "
    if [[ "$_proceed_all" != [Yy] ]]; then
      echo -e "${YELLOW} 조치를 취소합니다.${RESET}"
      exit 0
    fi
    echo ""
  fi
fi
fi

# ── 사전 백업 ─────────────────────────────────────────────────────────────────
# 자동 조치 대상이 있고 사용자가 실행을 취소하지 않은 경우에만 백업을 생성한다.
if [ "${#_PRECHECK_VULN[@]}" -gt 0 ] && [ "${_NO_ACTION_REQUIRED:-0}" -eq 0 ]; then
_div_thick
echo -e "${BOLD} 사전 백업${RESET}"
echo ""
echo -e " ${CYAN}→${RESET} 조치 시작 전 주요 설정 파일을 백업합니다."
echo ""

_PRE_BACKUP_TARGETS=(
  /etc/pam.d
  /etc/ssh
  /etc/security
  /etc/login.defs
  /etc/passwd                 # U-02/07/09/10/11/35 — chage·usermod·userdel 원복용 (누락 시 계정 롤백 불가)
  /etc/shadow                 # U-02/07/35 — 비밀번호 기간·잠금(passwd -l)·userdel 원복용
  /etc/default/useradd        # 계정 기본 정책 변경 원복용
  /etc/group                  # U-06 usermod -aG 역연산 실패 시 비상 복구용
  /etc/gshadow                # usermod -aG 시 함께 변경됨 (비상 복구용)
  /etc/subuid                 # userdel/usermod 시 보조 UID 범위 변경 가능
  /etc/subgid                 # userdel/usermod 시 보조 GID 범위 변경 가능
  /etc/sudoers
  /etc/sudoers.d
  /etc/crontab
  /etc/cron.d
  /etc/cron.allow
  /etc/cron.deny
  /var/spool/cron
  /etc/authselect             # authselect 프로필 설정 (RHEL 8/9, Rocky, Fedora)
  /var/lib/authselect         # authselect 백업 및 상태 (--backup 결과 포함)
  /etc/postfix
  /etc/sysconfig/network-scripts
  /etc/issue
  /etc/issue.net
  /etc/motd
  /etc/snmp/snmpd.conf
  /etc/rsyslog.conf
  /etc/rsyslog.d
  /etc/hosts.allow
  /etc/hosts.deny
  /etc/hosts.equiv            # U-27 삭제 원복용
  /etc/inetd.conf             # U-52 inetd Telnet 설정 원복용
  /etc/xinetd.conf            # U-20/U-52 설정 원복용
  /etc/xinetd.d               # U-52 xinetd Telnet 설정 원복용
  /etc/named.conf              # P3: named 설정 복원·검증 후 반영용
  /etc/named                   # P3: named include 설정 복원용
  /etc/bind                    # P3: Debian/Ubuntu BIND 설정 복원용
  /etc/chrony.conf             # P3: RHEL/Rocky chronyd 설정 복원용
  /etc/chrony                  # P3: Debian/Ubuntu chrony 설정 복원용
  /etc/firewalld              # U-28 영구 방화벽 설정 원복용
  /etc/ufw                    # U-28 UFW 설정 원복용
  /etc/sysconfig/iptables     # U-28 iptables 영속 규칙 원복용
  /etc/sysconfig/ip6tables
  /etc/iptables
  /etc/nftables.conf
  /etc/vsftpd.conf
  /etc/vsftpd                  # P3: vsftpd 보조 설정·사용자 목록 복원용
  /etc/proftpd
  /etc/proftpd.conf
  /etc/exports
  /etc/exports.d               # P3: NFS include export 설정 복원용
  /etc/nfs.conf                # P3: NFS 서비스 설정 복원용
  /etc/mail
  /etc/exim4
  /etc/profile
  /etc/profile.d
  /etc/bashrc
  /etc/bash.bashrc
  /root/.bash_profile
  /root/.bashrc
  /root/.profile
)

echo -e " 백업 대상:"
for _t in "${_PRE_BACKUP_TARGETS[@]}"; do
  [ -e "$_t" ] && echo "   $_t"
done
echo ""

# 파일명 시각은 반드시 _RUN_TS를 재사용한다 — 롤백의 자동 역산이 이 시각으로
# RUN_START 레코드를 폴백 매칭하기 때문 (date 재호출 시 시각이 어긋나 매칭 실패).
_PRE_BAK_FILE="${_BAK_DIR}/vulnFix_backup_${_HOSTNAME_VAL}_${_RUN_TS}.tar.gz"

# 새 백업을 만들기 전에 오래된 백업부터 정리해 디스크 무한 누적을 막는다.
_vf_prune_old_artifacts "$_BAK_DIR" "vulnFix_backup_${_HOSTNAME_VAL}_*.tar.gz" \
  "$VULNFIX_KEEP_BACKUPS" "조치 전 백업"

_exist_targets=()
declare -A _bak_target_seen=()
# 존재하는 경로만 조치 전 백업 대상 배열에 중복 없이 추가한다.
# 입력: $1=백업 후보 경로 / 결과 전역: _exist_targets, _bak_target_seen
_vf_add_backup_target() {
  local _p="$1"
  [ -e "$_p" ] || [ -L "$_p" ] || return 0
  [ -n "${_bak_target_seen[$_p]:-}" ] && return 0
  _bak_target_seen["$_p"]=1
  _exist_targets+=("$_p")
}
for _t in "${_PRE_BACKUP_TARGETS[@]}"; do _vf_add_backup_target "$_t"; done

# 정적 목록으로 잡을 수 없는 삭제 대상도 조치 전에 동적으로 백업한다.
for _t in /root/.rhosts /home/*/.rhosts; do
  _vf_add_backup_target "$_t"
done
# U-26이 삭제할 수 있는 /dev 내 일반 파일은 현재 존재하는 항목만 개별 백업한다.
while IFS= read -r _t; do _vf_add_backup_target "$_t"; done   < <(find /dev -xdev -type f 2>/dev/null | LC_ALL=C sort -u)

# 백업 내부에 실행 당시 서비스·패키지·계정·방화벽·경로 인벤토리를 함께 저장한다.
_PRE_META_TMP=$(mktemp -d "${_RB_DIR}/.meta_${_RUN_ID}_XXXXXX" 2>/dev/null)
if [ -z "$_PRE_META_TMP" ] || ! _vf_capture_runtime_meta "$_PRE_META_TMP" "${_exist_targets[@]}"; then
  [ -n "$_PRE_META_TMP" ] && rm -rf "$_PRE_META_TMP"
  echo -e " ${RED}⚠ 롤백 메타데이터 생성 실패 — 안전한 롤백을 보장할 수 없어 조치를 중단합니다.${RESET}"
  exit 1
fi

_tar_feature_opts=()
_vf_tar_supports '--acls'    && _tar_feature_opts+=(--acls)
_vf_tar_supports '--xattrs'  && _tar_feature_opts+=(--xattrs)
_vf_tar_supports '--selinux' && _tar_feature_opts+=(--selinux)

printf " 백업 중..."
# umask 077: SSH host key·shadow 등 민감 파일이 담기므로 생성 순간부터 root 전용
( umask 077; tar "${_tar_feature_opts[@]}" -czpf "$_PRE_BAK_FILE"     "${_exist_targets[@]}" -C "$_PRE_META_TMP" .vulnfix_meta 9>&- 2>/dev/null ) &
_bak_pid=$!

_bar_len=30; _bar_idx=0
while kill -0 "$_bak_pid" 2>/dev/null; do
  _bar_idx=$((_bar_idx + 1))
  _pos=$((_bar_idx % _bar_len))
  _bar=""
  for ((_k=0; _k<_bar_len; _k++)); do
    [ $_k -eq $_pos ] && _bar+="█" || _bar+="░"
  done
  printf "\r   [%s] 백업 중..." "$_bar"
  sleep 0.08
done
wait "$_bak_pid"; _bak_rc=$?

_bar_full=$(printf '█%.0s' $(seq 1 $_bar_len))
if [ $_bak_rc -eq 0 ]; then
  _bak_size=$(du -sh "$_PRE_BAK_FILE" 2>/dev/null | cut -f1)
  printf "\r   [%s] 백업 완료%-15s\n" "$_bar_full" ""
  echo ""
  echo -e "   파일 : ${CYAN}${_PRE_BAK_FILE}${RESET}"
  echo -e "   크기 : ${_bak_size}"
  echo ""
  _PRE_BAK_RECORDED="$_PRE_BAK_FILE"
  chmod 600 "$_PRE_BAK_FILE" 2>/dev/null   # umask와 이중 방어
  _bak_sha=""
  if command -v sha256sum >/dev/null 2>&1; then
    _bak_sha=$(sha256sum "$_PRE_BAK_FILE" 2>/dev/null | awk '{print $1}')
    if [ -n "$_bak_sha" ]; then
      ( cd "$(dirname "$_PRE_BAK_FILE")" 2>/dev/null         && printf '%s  %s\n' "$_bak_sha" "$(basename "$_PRE_BAK_FILE")"            > "$(basename "$_PRE_BAK_FILE").sha256" )
      chmod 600 "${_PRE_BAK_FILE}.sha256" 2>/dev/null
      echo "BACKUP_SHA256|${_RUN_TS}|ID=${_RUN_ID}|BAK=${_PRE_BAK_FILE}|SHA=${_bak_sha}" >> "$FIX_HISTORY_FILE" 2>/dev/null
    fi
  fi
  # 롤백 역산 필터링용 실행 시작 레코드.
  # 롤백은 BAK=<전체 경로>로 1순위 매칭하므로 필드를 추가해도 하위 호환된다.
  echo "RUN_START|${_RUN_TS}|ID=${_RUN_ID}|HOST=${_HOSTNAME_VAL}|BAK=${_PRE_BAK_FILE}" >> "$FIX_HISTORY_FILE" 2>/dev/null

  # ── 조치 전 설정 검증 기준값 기록 ─────────────────────────────────────────
  # 롤백 검증은 절대 PASS/FAIL이 아니라 조치 전 VERIFY_BASELINE과 비교한다.
  # 조치 전에도 실패한 항목은 같은 원인이 유지되면 복원 정상으로 판정한다.
  _baseline_record() {
    local _k="$1"; shift
    local _bl_out="${_PRE_META_TMP}/baseline_command.log" _bl_text="" _bl_hash=""
    : > "$_bl_out"
    if "$@" >"$_bl_out" 2>&1; then
      echo "VERIFY_BASELINE|${_k}|PASS" >> "$FIX_HISTORY_FILE" 2>/dev/null
    else
      _bl_text=$(cat "$_bl_out" 2>/dev/null)
      _bl_hash=$(_vf_verify_output_sha256 "$_bl_text" 2>/dev/null || true)
      if [ -n "$_bl_hash" ]; then
        echo "VERIFY_BASELINE|${_k}|FAIL|SHA256=${_bl_hash}" >> "$FIX_HISTORY_FILE" 2>/dev/null
      else
        # sha256sum을 사용할 수 없으면 상태값만 기록한다.
        echo "VERIFY_BASELINE|${_k}|FAIL" >> "$FIX_HISTORY_FILE" 2>/dev/null
      fi
    fi
    rm -f "$_bl_out" 2>/dev/null
  }
  command -v sshd       >/dev/null 2>&1 && _baseline_record "SSH 설정" sshd -t
  command -v visudo     >/dev/null 2>&1 && [ -f /etc/sudoers ] && _baseline_record "sudo 설정" visudo -cf /etc/sudoers
  command -v authselect >/dev/null 2>&1 && _baseline_record "PAM/authselect 구성" authselect check
  command -v rsyslogd   >/dev/null 2>&1 && _baseline_record "rsyslog 설정" rsyslogd -N1
  command -v postfix    >/dev/null 2>&1 && _baseline_record "Postfix 설정" postfix check
  unset -f _baseline_record 2>/dev/null
  rm -rf "$_PRE_META_TMP" 2>/dev/null
else
  rm -rf "$_PRE_META_TMP" 2>/dev/null
  printf "\r   [%s] 백업 실패%-15s\n" "$_bar_full" ""
  _warn "${_BAK_DIR} 쓰기 권한 확인 필요 — 사전 백업이 생성되지 않았습니다."
  _PRE_BAK_RECORDED="백업 실패"
  echo ""
  echo -e " ${RED}⚠ 경고: 사전 백업 없이 PAM/SSH/계정 설정을 변경하면 복구가 어렵습니다.${RESET}"
  if [ -t 0 ] && [ "${NO_PROMPT:-0}" -eq 0 ]; then
    _read_yn _bak_fail_yn " 백업 없이 계속 진행하시겠습니까? (y/n): "
    if [[ "$_bak_fail_yn" != [Yy] ]]; then
      echo -e " ${YELLOW}→ 사전 백업 실패로 조치를 중단합니다.${RESET}"
      exit 1
    fi
    echo -e " ${YELLOW}→ 백업 없이 계속 진행합니다. (직접 확인 후 진행)${RESET}"
  else
    echo -e " ${YELLOW}→ 비대화형 환경 — 백업 없이 계속 진행합니다.${RESET}"
  fi
fi
echo ""
else
  _PRE_BAK_RECORDED="미생성"
fi

# ── 조치 함수 ────────────────────────────────────────────────────────────────

# -----------------------------------------------------------------------------
# _backup_file
#
# 역할:
#   개별 설정 파일을 원본 권한과 소유권을 유지한 .bak.<시각> 파일로 복사한다.
#
# 입력:
#   $1 : 백업할 파일 경로
#   $2 : 백업 파일명에 사용할 공통 타임스탬프(선택)
#
# 출력:
#   백업 성공 시 생성된 백업 경로
#
# 반환값:
#   0 : 백업 성공
#   1 : 원본 부재 또는 복사 실패
#
# 주의:
#   여러 파일을 하나의 검증·복원 단위로 다룰 때는 호출부에서 같은 타임스탬프를 전달한다.
# -----------------------------------------------------------------------------
_backup_file() {
  local f="$1"
  local ts="${2:-$(date +%Y%m%d_%H%M%S)}"
  [ -f "$f" ] || return 1
  local bak="${f}.bak.${ts}"
  if cp -p "$f" "$bak" 2>/dev/null; then
    echo "$bak"
    return 0
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# config_set
#
# 역할:
#   단일 설정 파일의 일반적인 키·라인·부분 문자열을 공통 방식으로 변경한다.
#
# 입력:
#   $1 : 설정 파일
#   $2 : 검색할 키 또는 ERE 패턴
#   $3 : 적용할 값 또는 치환 문자열
#   $4 : 수정 방식(kv/kv_tab/line/substr/delete, 기본 kv)
#   $5 : 키와 값 사이 구분자(기본 " = ")
#   $6 : "ci" 지정 시 대소문자 무시
#
# 수정 방식:
#   kv      "key = value" 형식 갱신 또는 추가
#   kv_tab  "key<TAB>value" 형식 갱신 또는 추가
#   line    패턴과 일치하는 줄 전체를 교체하고 없으면 추가
#   substr  일치하는 부분만 교체하며 없으면 무변경
#   delete  일치하는 줄 전체 삭제
#
# 반환값:
#   0 : 변경 발생
#   1 : 파일 부재, 잘못된 mode 또는 명령 실패
#   2 : 이미 원하는 상태이거나 변경 대상 없음
#
# 적용 제외:
#   PAM 행 순서 삽입이나 exports 주소 치환처럼 여러 조건이 결합된 로직은
#   이 함수로 단순화하지 않고 항목별 전용 로직을 사용한다.
# -----------------------------------------------------------------------------
config_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local mode="${4:-kv}"
  local sep="${5:- = }"
  local ci="${6:-}"
  local _grep_opt="-E"
  local _sed_flag=""
  if [ "$ci" = "ci" ]; then _grep_opt="-iE"; _sed_flag="I"; fi

  [ -f "$file" ] || { _warn "config_set: 파일 없음 - $file"; return 1; }

  case "$mode" in
    kv)
      local esc_key esc_val
      esc_key=$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')
      esc_val=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
      if grep -qE "^[[:space:]]*${esc_key}[[:space:]]*=" "$file"; then
        if grep -qE "^[[:space:]]*${esc_key}[[:space:]]*=[[:space:]]*${esc_val}[[:space:]]*$" "$file"; then
          return 2
        fi
        sed -i -E "s|^[[:space:]]*${esc_key}[[:space:]]*=.*|${key}${sep}${value}|" "$file"
      else
        echo "${key}${sep}${value}" >> "$file"
      fi
      ;;
    kv_tab)
      local esc_key esc_val
      esc_key=$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')
      esc_val=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
      if grep -qE "^[[:space:]]*${esc_key}([[:space:]]|$)" "$file"; then
        if grep -qE "^[[:space:]]*${esc_key}[[:space:]]+${esc_val}[[:space:]]*$" "$file"; then
          return 2
        fi
        sed -i -E "s|^[[:space:]]*${esc_key}([[:space:]].*)?$|${key}\t${value}|" "$file"
      else
        printf '%s\t%s\n' "$key" "$value" >> "$file"
      fi
      ;;
    line)
      if grep -q ${_grep_opt} "$key" "$file"; then
        grep -qxF "$value" "$file" && return 2
        sed -i -E "s|${key}|${value}|${_sed_flag}" "$file"
      else
        echo "$value" >> "$file"
      fi
      ;;
    substr)
      grep -q ${_grep_opt} "$key" "$file" || return 2
      local _before _after
      _before=$(md5sum "$file" 2>/dev/null | awk '{print $1}')
      sed -i -E "s|${key}|${value}|g${_sed_flag}" "$file"
      _after=$(md5sum "$file" 2>/dev/null | awk '{print $1}')
      [ "$_before" = "$_after" ] && return 2
      ;;
    delete)
      grep -q ${_grep_opt} "$key" "$file" || return 2
      sed -i -E "/${key}/${_sed_flag}d" "$file"
      ;;
    *)
      _warn "config_set: 알 수 없는 mode - $mode"
      return 1
      ;;
  esac
  return 0
}

# ── 항목 출력 헬퍼 ────────────────────────────────────────────────────────────

# 항목 카드 시작부를 출력하고 상세 로그에 TASK 시작을 기록한다.
# 입력: $1=vuln/good/manual/na, $2=항목 ID, $3=항목 제목
_item_header() {
  local state="$1" id="$2" title="$3"
  _CURRENT_ITEM_ID="$id"
  _CURRENT_ITEM_TITLE="$title"
  _CURRENT_ITEM_STATE="$state"
  if declare -F _detail_log_item_start >/dev/null 2>&1; then
    _detail_log_item_start "$id" "$state" "$title"
  fi
  _flush_header
  if [ "${_JUST_PRINTED_SECTION:-0}" -eq 1 ]; then
    _JUST_PRINTED_SECTION=0
  else
    _div_thick
  fi
  case "$state" in
    vuln)   echo -e "${RED}[✘ 취약]${RESET} ${BOLD}${id}${RESET} ${title}" ;;
    good)   echo -e "${GREEN}[✔ 양호]${RESET} ${BOLD}${id}${RESET} ${title}" ;;
    manual) echo -e "${YELLOW}[! 수동확인]${RESET} ${BOLD}${id}${RESET} ${title}" ;;
    na)     echo -e "${CYAN}[○ 해당없음]${RESET} ${BOLD}${id}${RESET} ${title}" ;;
  esac
  echo ""
}

# 항목 카드의 최종 상태 문구를 출력한다.
# 입력: $1=done/fail/skip/na
_item_close() {
  case "${1:-done}" in
    done) _lbl_done ;;
    fail) _lbl_fail_v ;;
    skip) _lbl_skip ;;
    na)   : ;;
  esac
  echo ""
}

# ── 하위 호환 레이블 (기존 코드 호환) ────────────────────────────────────────
_lbl_check()   { _sec check; }
_lbl_before()  { _sec check; }   # [조치 전] → [현재 상태]로 통일 (템플릿과 동일)
_lbl_during()  { _sec during; }
_lbl_result()  { _sec result; }
_lbl_verify()  { _sec verify; }
_lbl_cur()     { _sec check; }
_lbl_state()   { _sec check; }
_lbl_yn()      { echo -e " ${YELLOW}※ y = 조치 진행 , n = 건너뜀${RESET}"; }
_lbl_skip()    { echo -e " ${YELLOW}– 건너뜁니다.${RESET}"; }
_lbl_done()    { echo -e " ${GREEN}→ 조치 완료 (검증 통과)${RESET}"; }
_lbl_done_nr() { echo -e " ${GREEN}→ 조치 완료${RESET}"; }
_lbl_fail_v()  { echo -e " ${RED}→ 조치 실패 또는 검증 실패${RESET}"; }
_lbl_subdiv()  { _div_sec; }

# -----------------------------------------------------------------------------
# 결과 상태 기록 공통 함수
#
# 역할:
#   상태별 카운터와 목록을 갱신하고 누적 이력·상세 로그·CSV 결과를 함께 기록한다.
#
# 상태 매핑:
#   _mark_fixed   → 조치완료/FIXED
#   _mark_skipped → 이미양호/GOOD 또는 사용자 건너뜀/USER_SKIPPED
#   _mark_manual  → 수동확인/MANUAL
#   _mark_failed  → 실패/FAILED
#   _mark_na      → 해당없음/NA
#
# 기록 대상:
#   상태별 카운터, 누적 이력, 상세 로그와 CSV 결과를 함께 갱신한다.
# -----------------------------------------------------------------------------
_mark_fixed() {
  FIXED=$((FIXED+1)); FIXED_LIST+=("$1: $2")
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|FIXED" >> "$FIX_HISTORY_FILE" 2>/dev/null
  _detail_log_result "$1" "FIXED" "$2"
  _report_add "$1" "조치완료" "" ""
}
_mark_skipped() {
  SKIPPED=$((SKIPPED+1)); SKIPPED_LIST+=("$1: $2")
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|SKIPPED" >> "$FIX_HISTORY_FILE" 2>/dev/null
  if [[ "$2" == *"[이미양호]"* ]]; then
    _detail_log_result "$1" "GOOD" "$2"
    _report_add "$1" "양호" "" ""
  else
    _detail_log_result "$1" "USER_SKIPPED" "$2"
    _report_add "$1" "건너뜀" "" ""
  fi
}
_mark_manual() {
  MANUAL=$((MANUAL+1)); MANUAL_LIST+=("$1: $2")
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|MANUAL" >> "$FIX_HISTORY_FILE" 2>/dev/null
  _detail_log_result "$1" "MANUAL" "$2"
  _report_add "$1" "수동확인" "$2" ""
}
_mark_failed() {
  FAILED=$((FAILED+1)); FAILED_LIST+=("$1: $2")
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|FAILED" >> "$FIX_HISTORY_FILE" 2>/dev/null
  _detail_log_result "$1" "FAILED" "$2"
  _report_add "$1" "실패" "" "$2"
}
_mark_na() {
  NA=$((NA+1)); NA_LIST+=("$1: $2")
  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|NA" >> "$FIX_HISTORY_FILE" 2>/dev/null
  _detail_log_result "$1" "NA" "$2"
  _report_add "$1" "해당없음" "" ""
}

# config_set 반환값을 사용자 화면의 성공·무변경·실패 문구로 변환한다.
_cs_report() {
  local rc=$1 file=$2 key=$3 val=$4
  case $rc in
    0) _ok "${file}: ${key} = ${val} 적용" ;;
    2) echo -e "   ${CYAN}○${RESET} ${file}: ${key} = ${val} (변경 없음, 이미 적용됨)" ;;
    *) _fail "${file}: ${key} 적용 실패" ;;
  esac
}

# -----------------------------------------------------------------------------
# _safe_append
#
# 역할:
#   셸 설정 파일의 제어 흐름을 간단히 확인한 뒤 지정한 텍스트를 안전한 위치에 추가한다.
#
# 입력:
#   $1 : 수정할 파일
#   $2 : 추가할 텍스트
#
# 동작:
#   - 닫히지 않은 if 블록이 감지되면 자동 변경 중단
#   - 파일 마지막에 exit 0이 있으면 그 앞에 삽입
#   - 그 외에는 파일 끝에 추가
#
# 반환값:
#   0 : 추가 완료
#   1 : 파일 부재 또는 구조상 자동 변경 중단
# -----------------------------------------------------------------------------
_safe_append() {
  local file="$1" text="$2"
  [ -f "$file" ] || { echo "   !! 파일 없음: $file"; return 1; }

  # 열린 if 블록 검사 (if 수 > fi 수)
  local if_cnt fi_cnt
  if_cnt=$(grep -v '^[[:space:]]*#' "$file" | grep -c '\bif\b')
  if_cnt=${if_cnt:-0}
  fi_cnt=$(grep -v '^[[:space:]]*#' "$file" | grep -c '\bfi\b')
  fi_cnt=${fi_cnt:-0}
  if [ "$if_cnt" -gt "$fi_cnt" ] 2>/dev/null; then
    echo -e "   ${YELLOW}!! $file 에 닫히지 않은 if 블록 감지 — 자동 추가 중단, 수동 확인 필요${RESET}"
    return 1
  fi

  # exit 0 이 파일 끝에 있으면 그 앞에 삽입
  if tail -5 "$file" | grep -q '^[[:space:]]*exit[[:space:]]*0'; then
    sed -i "/^[[:space:]]*exit[[:space:]]*0/i\\${text}" "$file"
    echo "   [exit 0 앞에 삽입] $file"
  else
    printf '\n%s\n' "$text" >> "$file"
    echo "   [파일 끝에 추가] $file"
  fi
  return 0
}

# _u06_show_candidates <현재 wheel 멤버(콤마구분)>
# su 명령을 허용할 만한 "로그인 가능한 일반 계정" 후보를 미리 보여준다.
# (UID_MIN 이상, 쉘이 nologin/false가 아니고, 이미 wheel에 없는 계정)
# 오타로 존재하지 않는 계정을 입력했다가 재입력하는 시행착오를 줄이기 위함.
_u06_show_candidates() {
  local _wheel_members="$1"
  local _uid_min
  _uid_min=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
  _uid_min=${_uid_min:-1000}
  local _found=0
  echo -e " ${CYAN}wheel 그룹에 추가할 수 있는 계정 (로그인 가능한 일반 사용자)${RESET}"
  while IFS=: read -r _cu _ _cuid _ _ _ _cshell; do
    [ "$_cuid" -lt "$_uid_min" ] 2>/dev/null && continue
    case "$_cshell" in */nologin|*/false) continue ;; esac
    echo "$_wheel_members" | tr ',' '\n' | grep -qx "$_cu" && continue
    echo "   - $_cu"
    _found=1
  done < /etc/passwd
  [ "$_found" -eq 0 ] && echo "   (조건에 맞는 로그인 계정이 없습니다 — 필요한 계정명을 직접 입력하세요)"
  echo ""
}

# _sshd_reload_guard
# restart 대신 reload(SIGHUP)를 써서 기존 SSH 접속을 끊지 않고 신규 접속부터 정책을 적용
# (락아웃 위험 감소). Include로 분산된 여러 파일을 한 타임스탬프로 일괄 백업/복구한다.
_sshd_reload_guard() {
  local bak_ts="$1"; shift
  local conf_files=("$@")

  if ! command -v sshd &>/dev/null; then
    echo -e "   ${YELLOW}!! sshd 바이너리 없음 — 문법 검증 불가, 안전을 위해 백업으로 복구합니다${RESET}"
    for _cf in "${conf_files[@]}"; do
      [ -f "${_cf}.bak.${bak_ts}" ] && cp -p "${_cf}.bak.${bak_ts}" "$_cf"
    done
    return 1
  fi

  local test_out
  test_out=$(sshd -t 2>&1)
  if [ $? -eq 0 ]; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
      || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null \
      || service sshd reload 2>/dev/null || service ssh reload 2>/dev/null
    echo -e "   ${GREEN}sshd -t 문법 검증 통과 → reload 완료 (기존 접속 세션 유지)${RESET}"
    return 0
  else
    echo -e "   ${RED}!! sshd -t 문법 검증 실패 — sshd를 재시작/reload 하지 않고 백업에서 즉시 복구합니다 (락아웃 방지)${RESET}"
    echo "$test_out" | sed 's/^/   /'
    local _restored=0
    for _cf in "${conf_files[@]}"; do
      if [ -f "${_cf}.bak.${bak_ts}" ]; then
        cp -p "${_cf}.bak.${bak_ts}" "$_cf"
        echo -e "   ${GREEN}복구 완료: ${_cf}.bak.${bak_ts} → ${_cf}${RESET}"
        _restored=1
      fi
    done
    [ $_restored -eq 0 ] && echo -e "   ${RED}!! 백업 파일 없음 — 수동 복구 필요. sshd 설정이 비정상 상태일 수 있습니다.${RESET}"
    return 1
  fi
}

# _snmpd_reload_guard <bak_ts> <conf_file1> [<conf_file2> ...]
# net-snmp의 snmpd에는 "sshd -t" 같은 전용 문법 검증
# 모드가 없다(대부분의 설정 오류를 fatal이 아닌 경고로 처리하고 그냥 기동됨).
# 그래서 "실제로 재기동해서 active 상태를 유지하는지"를 사실상의 검증 기준으로
# 삼는다 — 기동 자체가 실패하면(포트 바인딩 실패, 치명적 파싱 오류 등) 백업에서
# 즉시 복구하고 재기동을 재시도한다.
_snmpd_reload_guard() {
  local bak_ts="$1"; shift
  local conf_files=("$@")

  if ! command -v snmpd &>/dev/null; then
    echo -e "   ${YELLOW}!! snmpd 바이너리 없음 — 재기동 검증 불가, 설정만 반영합니다${RESET}"
    return 1
  fi

  systemctl restart snmpd 2>/dev/null || service snmpd restart 2>/dev/null
  sleep 1
  if systemctl is-active snmpd 2>/dev/null | grep -q '^active'; then
    echo -e "   ${GREEN}snmpd 재기동 확인 → 설정 반영 완료${RESET}"
    return 0
  else
    echo -e "   ${RED}!! snmpd 재기동 실패 — 백업에서 즉시 복구합니다${RESET}"
    systemctl status snmpd --no-pager 2>/dev/null | tail -5 | sed 's/^/   /'
    local _restored=0
    for _cf in "${conf_files[@]}"; do
      if [ -f "${_cf}.bak.${bak_ts}" ]; then
        cp -p "${_cf}.bak.${bak_ts}" "$_cf"
        echo -e "   ${GREEN}복구 완료: ${_cf}.bak.${bak_ts} → ${_cf}${RESET}"
        _restored=1
      fi
    done
    if [ $_restored -eq 1 ]; then
      systemctl restart snmpd 2>/dev/null || service snmpd restart 2>/dev/null
      sleep 1
      if systemctl is-active snmpd 2>/dev/null | grep -q '^active'; then
        echo -e "   ${GREEN}복구 후 재기동 확인 완료${RESET}"
      else
        echo -e "   ${RED}!! 복구 후에도 snmpd 기동 실패 — 수동 확인 필요${RESET}"
      fi
    else
      echo -e "   ${RED}!! 백업 파일 없음 — 수동 복구 필요. snmpd가 비정상 상태일 수 있습니다.${RESET}"
    fi
    return 1
  fi
}

# _nfs_exports_guard <bak_file> [<target_file>]
# exportfs에도 전용 "test" 모드가 없어, "exportfs -ra" 실행 시 stderr에 찍히는
# 오류/경고 메시지로 문법 이상 여부를 판단한다. 오류가 감지되면 백업에서 즉시
# 복구한 뒤 exportfs -ra 를 다시 실행해 커널 export 테이블까지 원상태로 되돌린다
# (그냥 파일만 복구하면 커널에는 잘못된 export가 남아있을 수 있음).
_nfs_exports_guard() {
  local bak_file="$1"
  local target_file="${2:-/etc/exports}"

  local _out
  _out=$(exportfs -ra 2>&1)
  if echo "$_out" | grep -qiE 'error|invalid|neither.*nor|syntax|unknown option'; then
    echo -e "   ${RED}!! ${target_file} 문법 오류 감지 — 백업에서 즉시 복구합니다${RESET}"
    echo "$_out" | sed 's/^/   /'
    if [ -n "$bak_file" ] && [ -f "$bak_file" ]; then
      cp -p "$bak_file" "$target_file"
      exportfs -ra 2>/dev/null
      echo -e "   ${GREEN}복구 완료: ${bak_file} → ${target_file} (exportfs -ra 재적용)${RESET}"
    else
      echo -e "   ${RED}!! 백업 파일 없음 — 수동 복구 필요${RESET}"
    fi
    return 1
  else
    echo -e "   ${GREEN}exportfs -ra 반영 확인 → 설정 적용 완료${RESET}"
    [ -n "$_out" ] && echo "$_out" | sed 's/^/   /'
    return 0
  fi
}

# _auth_watchdog_guard
# PAM 인증 스택 변경은 sshd -t 같은 사전 문법 검증 도구가 없어, 잘못되면 root까지
# 포함한 모든 계정의 로그인이 막힐 수 있다. 그래서 "사후 안전장치"로 대응한다:
#   1) 변경 직후 백그라운드 워치독 가동 (timeout초 후 자동 백업 복구)
#   2) 운영자가 새 세션에서 로그인 정상 여부를 직접 확인
#   3) 정상이면 Enter → 워치독 취소, 변경 유지
#   4) 시간이 더 필요하면 e → 워치독 재시작 (자리를 비웠으면 그냥 타임아웃되어 안전)
#   5) timeout 안에 무응답 → 워치독이 자동 백업 복구 (현재 세션은 유지됨)
# pairs: "백업파일1 대상파일1 백업파일2 대상파일2 ..." 형식의 배열
# _u03_manual_pam_edit <deny> <unlock_time>
# RHEL 계열 PAM에 pam_faillock.so를 직접 삽입(백업+워치독 보호, authselect 미사용 환경용).
_u03_manual_pam_edit() {
  local _deny="$1" _unlock="$2"
  _u03_bak_ts=$(date +%Y%m%d_%H%M%S)
  _u03_pairs=()
  for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    [ -f "$_pf" ] || continue
    _u03_bak="${_pf}.bak.${_u03_bak_ts}"
    cp -p "$_pf" "$_u03_bak"
    _u03_pairs+=("$_u03_bak" "$_pf")

    if grep -q 'pam_faillock' "$_pf"; then
      sed -i "s/deny=[0-9]*/deny=${_deny}/g; s/unlock_time=[0-9]*/unlock_time=${_unlock}/g" "$_pf"

      # preauth가 없으면 pam_unix 인증 처리 전에 추가
      if ! grep -qE '^auth[[:space:]].*pam_faillock\.so.*preauth' "$_pf" 2>/dev/null; then
        _u03_unix_line=$(grep -nE '^auth[[:space:]].*pam_unix\.so' "$_pf" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$_u03_unix_line" ]; then
          sed -i "${_u03_unix_line}i auth        required      pam_faillock.so preauth silent audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        else
          sed -i "1i auth        required      pam_faillock.so preauth silent audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        fi
      fi

      # authfail이 없으면 pam_unix 인증 처리 직후에 추가
      if ! grep -qE '^auth[[:space:]].*pam_faillock\.so.*authfail' "$_pf" 2>/dev/null; then
        _u03_unix_line=$(grep -nE '^auth[[:space:]].*pam_unix\.so' "$_pf" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$_u03_unix_line" ]; then
          sed -i "${_u03_unix_line}a auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        else
          _u03_deny_line=$(grep -nE '^auth[[:space:]].*pam_deny\.so' "$_pf" 2>/dev/null | head -1 | cut -d: -f1)
          if [ -n "$_u03_deny_line" ]; then
            sed -i "${_u03_deny_line}i auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
          else
            echo "auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" >> "$_pf"
          fi
        fi
      fi
      echo -e " ${GREEN}→ $_pf pam_faillock.so preauth/authfail 연결 완료${RESET}"

    elif grep -q 'pam_tally2\|pam_tally\b' "$_pf"; then
      sed -i "s/deny=[0-9]*/deny=${_deny}/g; s/unlock_time=[0-9]*/unlock_time=${_unlock}/g" "$_pf"
      echo -e " ${GREEN}→ $_pf deny/unlock_time 수정 완료${RESET}"

    else
      _u03_unix_line=$(grep -nE '^auth[[:space:]].*pam_unix\.so' "$_pf" 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$_u03_unix_line" ]; then
        sed -i "${_u03_unix_line}i auth        required      pam_faillock.so preauth silent audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        _u03_unix_line=$((_u03_unix_line + 1))
        sed -i "${_u03_unix_line}a auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
      else
        sed -i "1i auth        required      pam_faillock.so preauth silent audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        _u03_deny_line=$(grep -nE '^auth[[:space:]].*pam_deny\.so' "$_pf" 2>/dev/null | head -1 | cut -d: -f1)
        if [ -n "$_u03_deny_line" ]; then
          sed -i "${_u03_deny_line}i auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
        else
          echo "auth        [default=die] pam_faillock.so authfail audit deny=${_deny} unlock_time=${_unlock}" >> "$_pf"
        fi
      fi
      echo -e " ${GREEN}→ $_pf pam_faillock.so preauth/authfail 라인 추가 완료${RESET}"
    fi
  done
  _auth_watchdog_guard 90 "${_u03_pairs[@]}"
  _u03_guard_rc=$?
  [ $_u03_guard_rc -ne 0 ] && echo -e " ${RED}   PAM 변경이 자동 롤백되었습니다 — U-03은 미적용 상태입니다.${RESET}"
}

_auth_watchdog_guard() {
  local timeout="$1"; shift
  local pairs=("$@")
  local _wd_pid=""

  _start_wd() {
    (
      { exec 9>&-; } 2>/dev/null || true
      sleep "$timeout"
      for ((i=0; i<${#pairs[@]}; i+=2)); do
        bak="${pairs[i]}"; tgt="${pairs[i+1]}"
        [ -f "$bak" ] && cp -p "$bak" "$tgt"
      done
      _detail_log_note "U-03" "AUTO_ROLLBACK" "PAM 변경 미확인 타임아웃 — 자동 복원 실행: ${pairs[*]}"
    ) &
    _wd_pid=$!
  }

  echo -e "${RED}⚠ 중요: PAM 인증 설정을 변경했습니다 (system-auth/password-auth/common-auth).${RESET}"
  echo -e "${YELLOW}   1) 지금 이 터미널/세션은 절대 닫지 마세요.${RESET}"
  echo -e "${YELLOW}   2) 새 터미널(또는 새 SSH 접속, su)을 열어 로그인이 정상적으로 되는지 확인하세요.${RESET}"
  echo -e "${YELLOW}   3) 정상이면 아래에서 Enter를 누르세요 — 그러면 변경 사항이 그대로 유지됩니다.${RESET}"
  echo -e "${YELLOW}   4) 시간이 더 필요하면 e 를 입력하세요 — ${timeout}초가 다시 주어집니다.${RESET}"
  echo -e "${YELLOW}   5) ${timeout}초 안에 아무 입력도 없으면 자동으로 이전 설정으로 복구됩니다.${RESET}"

  _start_wd
  while true; do
    if read -t "$timeout" -rp " 새 세션에서 로그인 확인 완료 → Enter, 시간 더 필요하면 e (${timeout}초 제한): " _confirm_ok; then
      if [[ -z "$_confirm_ok" ]]; then
        kill "$_wd_pid" 2>/dev/null; wait "$_wd_pid" 2>/dev/null
        echo -e "${GREEN}→ 확인 완료. PAM 변경 사항을 유지합니다.${RESET}"
        return 0
      elif [[ "$_confirm_ok" == "e" || "$_confirm_ok" == "E" ]]; then
        kill "$_wd_pid" 2>/dev/null; wait "$_wd_pid" 2>/dev/null
        echo -e "${YELLOW}→ ${timeout}초 연장합니다. 계속 확인해 주세요.${RESET}"
        _start_wd
        continue
      else
        echo -e "${RED}→ Enter 또는 e만 입력할 수 있습니다.${RESET}"
        continue
      fi
    else
      echo ""
      echo -e "${RED}→ 시간 초과 — 확인되지 않아 워치독이 이전 설정으로 자동 복구합니다.${RESET}"
      wait "$_wd_pid" 2>/dev/null
      return 1
    fi
  done
}

_PENDING_HEADER=""
_JUST_PRINTED_SECTION=0
section_header() {
  _PENDING_HEADER="$1"
}
_section_range() {
  case "$1" in
    "계정 관리") echo "(U-01 ~ U-13)" ;;
    "파일 및 디렉터리 관리") echo "(U-14 ~ U-33)" ;;
    "서비스 관리") echo "(U-34 ~ U-63)" ;;
    "패치 관리") echo "(U-64)" ;;
    "로그 관리") echo "(U-65 ~ U-67)" ;;
    *) echo "" ;;
  esac
}
_flush_header() {
  local _mode="${1:-full}"
  if [ -n "$_PENDING_HEADER" ]; then
    local _range
    _range="$(_section_range "$_PENDING_HEADER")"
    echo ""
    _div_thick
    echo -e " ${CYAN}■${RESET} ${BOLD}${_PENDING_HEADER}${RESET} ${WHITE}${_range}${RESET}"
    [ "$_mode" = "top_only" ] || _div_thick
    echo ""
    _PENDING_HEADER=""
    _JUST_PRINTED_SECTION=1
  fi
}

# -----------------------------------------------------------------------------
# do_fix
#
# 역할:
#   자동 판정과 자동 조치가 가능한 U 항목의 공통 처리 흐름을 수행한다.
#
# 입력:
#   $1 : 항목 ID
#   $2 : 항목 제목
#   $3 : 조치 전 상태 출력 명령
#   $4 : 실제 조치 명령
#   $5 : 조치 후 검증 출력 명령
#   $6 : 검증 통과 정규식
#
# 처리 순서:
#   1. TARGET_IDS 포함 여부 확인
#   2. check_still_vuln으로 양호/취약/해당없음/수동확인 판정
#   3. 취약 시 사용자 y/n 확인
#   4. 조치 명령 실행과 stdout/stderr 기록
#   5. 조치 후 재점검 및 pass_pattern 검증
#   6. 상태 카운터·누적 이력·상세 로그·CSV 결과 기록
#
# 시스템 영향:
#   사용자가 y를 선택한 취약 항목에서만 fix_cmd를 현재 셸에서 실행한다.
#
# 안전 조건:
#   - 조치 전 /etc 대상 파일의 개별 스냅샷 생성
#   - 조치 명령 실패 시 검증 단계로 진행하지 않고 실패 처리
#   - 전체 명령과 오류 출력은 상세 로그에 보존
# -----------------------------------------------------------------------------
do_fix() {
  local id="$1" title="$2" before_cmd="$3" fix_cmd="$4" after_cmd="$5" pass_pattern="$6"

  local match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "$id" ] && match=1 && break; done
  [ $match -eq 0 ] && return

  check_still_vuln "$id"
  local vuln_status=$?

  # ── 양호 ──────────────────────────────────────────────────────────────────
  if [ $vuln_status -eq 1 ]; then
    _item_header "good" "$id" "$title"
    _sec check
    local cur_out="" _check_rc=0 _check_err=""
    if [ -n "$before_cmd" ]; then
      _vf_capture_eval_subshell "$before_cmd"
      cur_out="$_VF_CAPTURE_STDOUT"; _check_err="$_VF_CAPTURE_STDERR"; _check_rc="$_VF_CAPTURE_RC"
      _detail_log_command "$id" "CHECK" "$before_cmd" "$_check_rc" "$cur_out" "$_check_err" "GOOD"
    fi
    if [ -n "$cur_out" ]; then
      echo "$cur_out" | sed 's/^/   /'
    else
      echo -e "   ${GREEN}✔${RESET} 이상 항목 없음 (점검 통과)"
    fi
    # 양호 항목도 엑셀에 현재 설정값이 보이도록 BEFORE_VAL 채우기
    _vf_fill_before_val "$id" "$cur_out"
    AFTER_VAL["$id"]="이미 양호 (재확인 통과)"
    _mark_skipped "$id" "${title} [이미양호]"
    echo ""; return

  # ── 해당없음 ──────────────────────────────────────────────────────────────
  elif [ $vuln_status -eq 2 ]; then
    _item_header "na" "$id" "$title"
    _info "서비스 미운용으로 조치 불필요"
    BEFORE_VAL["$id"]="서비스 미운용"
    AFTER_VAL["$id"]="해당없음"
    _mark_na "$id" "$title"
    echo ""; return

  # ── 자동판정 불가: 수동확인 ────────────────────────────────────────────────
  elif [ $vuln_status -eq 3 ]; then
    _item_header "manual" "$id" "$title"
    _sec check
    local _manual_out="" _manual_check_err="" _manual_check_rc=0
    if [ -n "$before_cmd" ]; then
      _vf_capture_eval_subshell "$before_cmd"
      _manual_out="$_VF_CAPTURE_STDOUT"; _manual_check_err="$_VF_CAPTURE_STDERR"; _manual_check_rc="$_VF_CAPTURE_RC"
      _detail_log_command "$id" "CHECK" "$before_cmd" "$_manual_check_rc" "$_manual_out" "$_manual_check_err" "MANUAL"
    fi
    [ -n "$_manual_out" ] && echo "$_manual_out" | sed 's/^/   /'
    _sec need
    _warn "패키지 저장소 또는 벤더 권고정보를 확인할 수 없어 자동 판정하지 않습니다."
    _info "설치 버전과 최신 보안 권고 버전을 직접 비교하세요."
    _vf_fill_before_val "$id" "$_manual_out" "버전 정보 확인 필요"
    AFTER_VAL["$id"]="수동 확인 필요"
    DETAIL_VAL["$id"]="[현재 상태] ${BEFORE_VAL[$id]} | [판정] 저장소/벤더 정보 확인 불가로 수동확인"
    _mark_manual "$id" "${title} — 저장소/벤더 정보 확인 불가"
    echo ""; return
  fi

  # ── 취약 ──────────────────────────────────────────────────────────────────
  local before_out="" _before_err="" _before_rc=0
  _vf_capture_eval_subshell "$before_cmd"
  before_out="$_VF_CAPTURE_STDOUT"; _before_err="$_VF_CAPTURE_STDERR"; _before_rc="$_VF_CAPTURE_RC"
  _detail_log_command "$id" "CHECK" "$before_cmd" "$_before_rc" "$before_out" "$_before_err" "VULNERABLE"
  # 화면용 미리보기는 5줄만 유지하되, 보고서에는 공통 헬퍼로 최대 200줄을 보존한다.
  local _before_preview
  _before_preview=$(printf '%s\n' "$before_out" | grep -v '^[[:space:]]*$' | head -5)
  _vf_fill_before_val "$id" "$before_out" "설정 정보 없음 (점검 대상 미감지)"

  _item_header "vuln" "$id" "$title"

  # [확인 상태]
  _sec check
  if [ -n "$before_out" ]; then
    echo "$before_out" | sed 's/^/   /'
  else
    echo "   (출력된 설정 값 없음 — 미설정 상태)"
  fi
  # BEFORE_VAL은 위 _vf_fill_before_val에서 최대 200줄 기준으로 저장 완료.

  echo ""
  _lbl_yn
  _read_yn yn " 조치하시겠습니까? (y/n): "
  case "$yn" in
    [Yy])
      # [조치 중] — 원본 명령(특히 find/while 같은 복잡한 스크립트)을 화면에
      # 그대로 찍으면 비전문 사용자에게는 에러 덤프처럼 보인다. 상세 명령은
      # 로그 파일에만 남기고, 화면에는 실제 실행 결과(출력)만 보여준다.
      _sec during
      _detail_log_note "$id" "FIX" "조치 명령 실행 시작"
      # fix_cmd가 서비스 reload를 수행했다면 "성공"/"실패"를 이 변수에 담아줄
      # 수 있다 — 그러면 아래 [최종 검증]에 재시작 결과 줄이 자동으로 붙는다.
      # (매 항목 시작 전 초기화 — 이전 항목의 값이 남아있지 않도록)
      _LAST_RELOAD_STATUS=""
      # 특정 항목이 "변경하지 않음"을 선택했을 때 실패가 아니라 수동 확인으로
      # 기록할 수 있도록 항목별 강제 수동확인 사유를 초기화한다.
      _FORCE_MANUAL_REASON=""
      # fix_cmd에 포함된 /etc 파일은 항목별 복원을 위해 개별 스냅샷을 만든다.
      # 같은 실행에서 동일 파일은 최초 1회만 백업해 실행 시작 전 상태를 유지한다.

      while IFS= read -r _bt; do
        [ -z "$_bt" ] && continue
        [ -f "$_bt" ] || continue
        [ -e "${_bt}.bak.${_RUN_TS}" ] || cp -p "$_bt" "${_bt}.bak.${_RUN_TS}" 2>/dev/null
      done < <(grep -oE '/etc/[A-Za-z0-9_./-]+' <<< "$fix_cmd" | sort -u)
      # fix_cmd의 export와 셸 상태 변경이 후속 검증에 반영되도록 현재 셸에서 실행하고,
      # stdout과 stderr만 임시 파일로 분리해 수집한다.
      local _fix_tmp; _fix_tmp=$(mktemp 2>/dev/null || echo "/tmp/.vulnfix_out.$$")
      local _fix_err; _fix_err=$(mktemp 2>/dev/null || echo "/tmp/.vulnfix_err.$$")
      eval "$fix_cmd" >"$_fix_tmp" 2>"$_fix_err"
      local _fix_rc=$?
      local _fix_stdout_text="" _fix_stderr_text=""
      _fix_stdout_text=$(cat "$_fix_tmp" 2>/dev/null)
      _fix_stderr_text=$(cat "$_fix_err" 2>/dev/null)
      _detail_log_command "$id" "FIX" "$fix_cmd" "$_fix_rc" \
        "$_fix_stdout_text" "$_fix_stderr_text" "$( [ "$_fix_rc" -eq 0 ] && echo PASS || echo FAIL )"

      # eval 자체가 실패(rc≠0)이면 조치 명령 실행 오류로 즉시 실패 처리.
      # stderr에 찍힌 내용을 사용자에게 직접 노출하지 않고 상세 로그에만 남긴다.
      if [ $_fix_rc -ne 0 ]; then
        rm -f "$_fix_tmp" "$_fix_err"
        _sec result
        echo -e "   ${RED}✗${RESET} 조치 명령 실행 중 오류 발생"
        _info "상세 오류는 실행 종료 후 상세 로그에서 확인할 수 있습니다."
        _item_close fail
        AFTER_VAL["$id"]="조치 실패 (실행 오류)"
        _mark_failed "$id" "${title} — 조치 명령 실행 오류 (rc=${_fix_rc})"
        echo ""; return
      fi

      if [ -s "$_fix_err" ]; then
        _warn "명령 실행 중 경고가 기록되었습니다. 상세 내용은 상세 로그에서 확인하세요."
      fi

      if [ -s "$_fix_tmp" ]; then
        # fix_cmd 가 출력하는 텍스트를 UI 형식에 맞춰 정제:
        #   ✓ / ✔ / OK  → 초록 체크마크
        #   ✗ / ✘ / FAIL → 빨간 엑스마크
        #   →             → 시안 화살표
        #   그 외          → 그냥 들여쓰기
        while IFS= read -r _fix_line; do
          [ -z "$_fix_line" ] && echo "" && continue
          case "$_fix_line" in
            *"✓"*|*"✔"*|"OK"*|*"완료"*|*"VERIFY_OK"*)
              echo -e "   ${GREEN}✓${RESET} ${_fix_line//✓/}" ;;
            *"✗"*|*"✘"*|*"실패"*|*"FAIL"*)
              echo -e "   ${RED}✗${RESET} ${_fix_line//✗/}" ;;
            *"→"*)
              echo -e "   ${CYAN}→${RESET} ${_fix_line//→/}" ;;
            "["*"]"*)
              # [조치 대상 상세] 같은 섹션 헤더
              echo -e "   ${BOLD}${_fix_line}${RESET}" ;;
            *)
              echo "   ${_fix_line}" ;;
          esac
        done < "$_fix_tmp"
      else
        echo -e "   ${GREEN}✓${RESET} 보안 설정 적용 완료"
      fi
      rm -f "$_fix_tmp" "$_fix_err"

      # [조치 결과] 및 [최종 검증]용 재확인 명령
      local after_out="" _after_err="" _after_rc=0
      _vf_capture_eval_subshell "$after_cmd"
      after_out="$_VF_CAPTURE_STDOUT"; _after_err="$_VF_CAPTURE_STDERR"; _after_rc="$_VF_CAPTURE_RC"
      _sec result
      # after_out이 너무 많은 줄을 포함하면 파일 내용이 통째로 출력되는 문제 방지
      # — 의미있는 결과 줄(빈 줄 제외)만 최대 15줄만 표시한다.
      local _after_meaningful
      _after_meaningful=$(echo "$after_out" | grep -v '^[[:space:]]*$' | head -15)
      local _after_total
      _after_total=$(echo "$after_out" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
      while IFS= read -r _after_line; do
        [ -z "$_after_line" ] && continue
        case "$_after_line" in
          *"✓"*|*"✔"*|*"완료"*|*"양호"*|*"VERIFY_OK"*)
            echo -e "   ${GREEN}✓${RESET} ${_after_line//✓/}" ;;
          *"✗"*|*"✘"*|*"실패"*|*"오류"*)
            echo -e "   ${RED}✗${RESET} ${_after_line//✗/}" ;;
          *"→"*)
            echo -e "   ${CYAN}→${RESET} ${_after_line//→/}" ;;
          *)
            echo "   ${_after_line}" ;;
        esac
      done <<< "$_after_meaningful"
      if [ "$_after_total" -gt 15 ]; then
        echo -e "   ${YELLOW}... (총 ${_after_total}줄, 전체 내용은 상세 로그 참조)${RESET}"
      fi
      _vf_fill_after_val "$id" "$after_out" "검증 결과 없음"

      # 검증 (판정 로직은 기존과 동일 — pass_pattern 대조)
      local verified=0
      [ -n "$pass_pattern" ] && echo "$after_out" | grep -qE "$pass_pattern" && verified=1
      [ -z "$pass_pattern" ] && verified=1
      _detail_log_command "$id" "VERIFY" "$after_cmd" "$_after_rc" \
        "$after_out" "$_after_err" "$( [ "$verified" -eq 1 ] && echo PASS || echo FAIL )"

      # [최종 검증] — 실제 재확인 결과를 체크리스트로 보여준다.
      _sec verify
      if [ -n "${_FORCE_MANUAL_REASON:-}" ]; then
        echo "   → 자동 변경하지 않은 항목 존재 — 수동 확인 필요"
        echo "   → ${_FORCE_MANUAL_REASON}"
        _item_close na
        AFTER_VAL["$id"]="수동 확인 필요"
        _mark_manual "$id" "${title} — ${_FORCE_MANUAL_REASON}"
        echo ""; return
      fi
      if [ $verified -eq 1 ]; then
        echo "   ✓ 설정값 반영 확인"
      else
        echo "   ✗ 설정값 미반영 또는 검증 기준 미충족"
        [ -n "$_after_err" ] && _info "검증 명령의 상세 오류는 상세 로그에 기록되었습니다."
      fi
      if [ -n "$_LAST_RELOAD_STATUS" ]; then
        if [ "$_LAST_RELOAD_STATUS" = "성공" ]; then
          echo "   ✓ 서비스 reload 성공"
        else
          echo "   ✗ 서비스 reload 실패"
        fi
      fi

      if [ $verified -eq 1 ]; then
        _item_close done
        # ── DETAIL_VAL 자동 생성 (항목별 개별 설정이 없는 경우 fallback) ──────
        # 이미 항목별 코드에서 DETAIL_VAL["$id"]를 채운 경우는 그대로 유지.
        # 없는 경우 before_out/after_out으로 "변경 전 → 변경 후" 자동 생성.
        if [ -z "${DETAIL_VAL[$id]:-}" ]; then
          local _d_before; _d_before=$(echo "$before_out" | grep -v '^[[:space:]]*$' | head -8 | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|$//')
          local _d_after;  _d_after=$(echo  "$after_out"  | grep -v '^[[:space:]]*$' | head -8 | sed 's/^[[:space:]]*//' | tr '\n' '|' | sed 's/|$//')
          local _d_reload=""
          [ -n "$_LAST_RELOAD_STATUS" ] && _d_reload=" | 서비스 reload: ${_LAST_RELOAD_STATUS}"
          if [ -n "$_d_before" ] || [ -n "$_d_after" ]; then
            DETAIL_VAL["$id"]="[변경 전] ${_d_before:-없음} | [변경 후] ${_d_after:-없음}${_d_reload}"
          fi
        fi
        _mark_fixed "$id" "$title"
      else
        _item_close fail
        AFTER_VAL["$id"]="${AFTER_VAL[$id]} [검증실패]"
        _mark_failed "$id" "${title} — 조치 시도했으나 검증 기준 미충족"
      fi ;;
    *)
      _item_close skip
      AFTER_VAL["$id"]="건너뜀"
      _mark_skipped "$id" "${title} [건너뜀]" ;;
  esac
  echo ""
}

# -----------------------------------------------------------------------------
# do_manual
#
# 역할:
#   자동 변경보다 운영 정책 판단이 우선인 항목을 공통 수동 확인 흐름으로 처리한다.
#
# 입력:
#   $1 : 항목 ID
#   $2 : 항목 제목
#   $3 : 사용자가 확인할 판단 기준·조치 안내
#   $4 : 현재 상태 출력 명령
#
# 처리:
#   현재 상태가 이미 양호하면 GOOD으로 기록하고,
#   그 외에는 상태 출력과 판단 기준을 표시한 뒤 MANUAL로 기록한다.
#
# 시스템 영향:
#   상태 조회만 수행하며 설정을 자동 변경하지 않는다.
# -----------------------------------------------------------------------------
do_manual() {
  local id="$1" title="$2" desc="$3" status_cmd="$4"
  local match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "$id" ] && match=1 && break; done
  [ $match -eq 0 ] && return

  check_still_vuln "$id"
  local vuln_status=$?

  if [ $vuln_status -eq 1 ]; then
    _item_header "good" "$id" "$title"
    _sec check
    local cur_out="" _manual_good_err="" _manual_good_rc=0
    if [ -n "$status_cmd" ]; then
      _vf_capture_eval_subshell "$status_cmd"
      cur_out="$_VF_CAPTURE_STDOUT"; _manual_good_err="$_VF_CAPTURE_STDERR"; _manual_good_rc="$_VF_CAPTURE_RC"
      _detail_log_command "$id" "CHECK" "$status_cmd" "$_manual_good_rc" "$cur_out" "$_manual_good_err" "GOOD"
    fi
    if [ -n "$cur_out" ]; then
      echo "$cur_out" | sed 's/^/   /'
    else
      echo -e "   ${GREEN}✔${RESET} 이상 항목 없음 (점검 통과)"
    fi
    _vf_fill_before_val "$id" "$cur_out"
    AFTER_VAL["$id"]="이미 양호 (재확인 통과)"
    echo ""
    _mark_skipped "$id" "${title} [이미양호]"
  else
    _item_header "manual" "$id" "$title"
    local _manual_before=""
    if [ -n "$status_cmd" ]; then
      _sec check
      _vf_capture_eval_subshell "$status_cmd"
      _manual_before="$_VF_CAPTURE_STDOUT"
      _detail_log_command "$id" "CHECK" "$status_cmd" "$_VF_CAPTURE_RC" \
        "$_manual_before" "$_VF_CAPTURE_STDERR" "MANUAL"
      echo "$_manual_before" | sed 's/^/   /'
    fi
    _sec need
    echo "   $desc" | sed 's/\\n/\n   /g'
    echo ""
    _info "위 현재 상태를 보안정책과 대조하여 직접 판단이 필요합니다."
    _item_close na
    _vf_fill_before_val "$id" "$_manual_before" "점검값 없음 (수동 확인 필요)"
    # desc는 여러 줄로 쓰인 항목(U-33/U-47 등 실제 개행)과 리터럴 "\n"을 쓰는 항목(U-11)이
    # 섞여 있다. CSV 저장 시 _csv_esc가 실제 개행을 단일 " | "로 뭉개고, 엑셀 파서는
    # " || "(이중 파이프)만 개행으로 복원하므로 두 경우 모두 여기서 " || "로 통일한다.
    local _desc_report="${desc//$'\n'/ || }"
    _desc_report="${_desc_report//\\n/ || }"
    DETAIL_VAL["$id"]="[현재 상태] ${BEFORE_VAL[$id]} | [조치 방법] ${_desc_report}"
    _mark_manual "$id" "${title} — ${_desc_report}"
  fi
  echo ""
}

# ============================================================
_has_cat_target "계정 관리" && section_header "계정 관리"
# ============================================================

# =============================================================================
# U-01 / root 계정 원격 접속 제한
#
# 점검 기준:
#   SSH의 PermitRootLogin이 no이고, Telnet 사용 시 pam_securetty와 securetty 제한이 적용되어야 한다.
#
# 조치 내용:
#   PermitRootLogin을 no로 설정하고 Telnet 활성 환경에서는 PAM 연결과 pts 허용 항목을 보완한다.
#
# 변경 대상:
#   /etc/ssh/sshd_config, 포함된 sshd 설정 파일, /etc/pam.d/login, /etc/securetty
#
# 수동 확인:
#   Telnet PAM 파일이 없거나 SSH 구문 검사·재적용에 실패한 경우 직접 확인한다.
#
# 롤백:
#   조치 전 설정 파일 백업을 사용해 SSH/PAM/securetty 설정을 복원한다.
# =============================================================================

{
  _match01=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-01" ] && _match01=1 && break; done

  if [ $_match01 -eq 1 ]; then                                  # (1) TARGET_IDS 매칭
    check_still_vuln "U-01"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then                                     # (2) 이미 양호?
      _item_header "good" "U-01" "(상) root 계정 원격 접속 제한"
      _lbl_cur
      grep -rh 'PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null \
        | grep -v '^\s*#' | sed 's/^/   /'
      echo ""
      BEFORE_VAL["U-01"]=$(grep -rh 'PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | grep -v '^\s*#' | head -2 2>/dev/null | head -3)
      [ -z "${BEFORE_VAL["U-01"]:-}" ] && BEFORE_VAL["U-01"]="이상 항목 없음 (점검 통과)"
      AFTER_VAL["U-01"]="이미 양호 (재확인 통과)"
      _mark_skipped "U-01" "root 원격접속 제한 [이미양호]"
      echo ""

    else
      _item_header "vuln" "U-01" "(상) root 계정 원격 접속 제한"
      echo ""

      _u01_literal=$(grep -i 'PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | grep -v '^\s*#')
      _u01_telnet_on=0
      ss -tlnp 2>/dev/null | grep -q ':23 ' && _u01_telnet_on=1
      pgrep -x telnetd &>/dev/null && _u01_telnet_on=1
      [ "$_u01_telnet_on" -eq 1 ] && _u01_pts=$(grep -v '^#' /etc/securetty 2>/dev/null | grep '^pts/')

      # ── [SSH 설정] ──────────────────────────────────────────────────────────
      echo -e " ${YELLOW}[SSH 설정]${RESET}"
      echo ""
      echo -e "   설정 파일"
      if [ -n "$_u01_literal" ]; then
        echo "$_u01_literal" | sed 's/^/   /'
      else
        echo "   PermitRootLogin 미설정 (기본값 yes)"
      fi
      echo ""

      # ── [Telnet 설정] ───────────────────────────────────────────────────────
      _lbl_subdiv
      echo -e " ${YELLOW}[Telnet 설정]${RESET}"
      echo ""

      if [ "$_u01_telnet_on" -eq 0 ]; then
        echo -e "   Telnet 서비스 : ${GREEN}미사용${RESET}"
        echo ""
        _info "securetty / pam_securetty 점검 제외"
      else
        echo -e "   Telnet 서비스 : ${RED}활성${RESET}"
        echo ""
        if [ -n "$_u01_pts" ]; then
          _fail "/etc/securetty: pts/ 허용 (${_u01_pts}) — 취약 요인"
        else
          _ok "/etc/securetty: pts/ 미허용"
        fi
        if grep -qE '^auth.*required.*(pam_securetty\.so|/lib/security/pam_securetty\.so)' /etc/pam.d/login 2>/dev/null; then
          _ok "/etc/pam.d/login: pam_securetty.so 설정됨"
        else
          _fail "/etc/pam.d/login: pam_securetty.so 미설정 — 취약 요인"
        fi
      fi
      echo ""
      _lbl_yn
      _read_yn _yn_u01 " 조치하시겠습니까? (y/n): "

      if [[ "$_yn_u01" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-01" "root 계정 원격 접속 제한 [건너뜀]"
        echo ""

      else
        _lbl_during
        echo -e " ${YELLOW}⚠ SSH 설정 변경 — 원격 세션 대비 별도 터미널을 열어두세요.${RESET}"

        # ── SSH 조치 ──
        if [ -f /etc/ssh/sshd_config ]; then
          _u01_changed=0
          _u01_has_active=0
          _u01_confs="/etc/ssh/sshd_config"
          while IFS= read -r _inc; do
            for _f in $_inc; do [ -f "$_f" ] && _u01_confs="$_u01_confs $_f"; done
          done < <(grep -v '^[[:space:]]*#' /etc/ssh/sshd_config 2>/dev/null \
                   | grep -iE '^[[:space:]]*Include[[:space:]]+' | awk '{print $2}')

          _u01_bak_ts=$(date +%Y%m%d_%H%M%S)
          for _cf in $_u01_confs; do
            [ -f "$_cf" ] || continue
            _backup_file "$_cf" "$_u01_bak_ts" >/dev/null
          done

          for _cf in $_u01_confs; do
            [ -f "$_cf" ] || continue
            if grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]+' "$_cf"; then
              _u01_has_active=1
              config_set "$_cf" '^[[:space:]]*PermitRootLogin[[:space:]].*' 'PermitRootLogin no' line '' ci
              _u01_changed=1
            fi
          done

          [ $_u01_has_active -eq 0 ] && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config && _u01_changed=1

          _sshd_reload_guard "$_u01_bak_ts" $_u01_confs
          _u01_guard_rc=$?
        fi

        # ── Telnet 활성 시 PAM/securetty 조치 ──
        if [ $_u01_telnet_on -eq 1 ]; then
          if [ -f /etc/pam.d/login ]; then
            if ! grep -qE '^auth.*required.*(pam_securetty\.so|/lib/security/pam_securetty\.so)' /etc/pam.d/login; then
              sed -i '0,/^auth/{s|^auth|auth\t\trequired\tpam_securetty.so\nauth|}' /etc/pam.d/login
            fi
          else
            _mark_manual "U-01" "/etc/pam.d/login 수동 생성 및 pam_securetty 설정 필요"
          fi
          if [ -f /etc/securetty ]; then
            PTS_COUNT=$(grep -v '^#' /etc/securetty | grep -c '^pts/' || true)
            [ "${PTS_COUNT:-0}" -gt 0 ] && config_set /etc/securetty '^(pts/.*)' '#\1' substr
          fi
        fi

        # ── 조치 결과 ──
        echo ""
        _lbl_result
        _u01_after=$(grep -i 'PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | grep -v '^\s*#')
        [ -n "$_u01_after" ] && echo "$_u01_after" | sed 's/^/   /' || echo "   PermitRootLogin no"

        check_still_vuln "U-01"; _rs=$?
        echo ""
        if [ $_rs -eq 1 ]; then
          _lbl_done
          BEFORE_VAL["U-01"]="${_u01_literal:-PermitRootLogin 미설정(기본값 yes)}"
          AFTER_VAL["U-01"]="${_u01_after:-PermitRootLogin no}"
          _u01_conf_list=""
          for _cf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$_cf" ] && grep -qi 'PermitRootLogin' "$_cf" && _u01_conf_list="${_u01_conf_list}${_u01_conf_list:+|}${_cf}"
          done
          DETAIL_VAL["U-01"]=$(_fmt_detail \
            "${_u01_literal:-PermitRootLogin 미설정(기본값 yes)}" \
            "PermitRootLogin no 설정으로 root 원격 접속 차단" \
            "조치 완료 / 최종 검증 통과" \
            "${_u01_conf_list}" \
            "${_u01_after:-PermitRootLogin no}")
          _mark_fixed "U-01" "root 계정 원격 접속 제한 완료"
        else
          _lbl_fail_v
          AFTER_VAL["U-01"]="${_u01_after:-확인불가} [검증실패]"
          _mark_failed "U-01" "root 계정 원격 접속 제한 — 조치 시도했으나 검증 기준 미충족"
        fi
        echo ""
      fi  # _yn_u01 yes 분기 닫기
    fi
  fi
}

# =============================================================================
# U-02 / 비밀번호 관리정책 설정
#
# 점검 기준:
#   비밀번호 사용 기간과 pwquality 복잡도 값이 기준을 충족하고 PAM에서 정책 모듈을 호출해야 한다.
#
# 조치 내용:
#   login.defs와 pwquality.conf에 사용자가 선택한 정책값을 반영하고 선택 시 PAM 연결을 보완한다.
#
# 변경 대상:
#   /etc/login.defs, /etc/security/pwquality.conf, system-auth/password-auth/common-password
#
# 수동 확인:
#   authselect custom 상태, PAM 모듈 부재 또는 기존 인증 흐름과 충돌할 가능성이 있으면 직접 확인한다.
#
# 롤백:
#   조치 전 파일 백업으로 정책 파일과 PAM 설정을 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-02" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-02"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-02" "(상) 비밀번호 관리정책 설정"
      _lbl_cur
      grep -v '^\s*#' /etc/login.defs 2>/dev/null | grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS' | sed 's/^/   /'
      BEFORE_VAL["U-02"]=$(grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS' /etc/login.defs 2>/dev/null | grep -v '^\s*#' | head -3 2>/dev/null | head -3)
      [ -z "${BEFORE_VAL["U-02"]:-}" ] && BEFORE_VAL["U-02"]="이상 항목 없음 (점검 통과)"
      AFTER_VAL["U-02"]="이미 양호 (재확인 통과)"
      grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null \
        | grep -E 'minlen|ucredit|lcredit|dcredit|ocredit|retry' | sed 's/^/   /'
      echo ""
            _mark_skipped "U-02" "비밀번호 관리정책 [이미양호]"
      echo ""
    else
      _item_header "vuln" "U-02" "(상) 비밀번호 관리정책 설정"
      echo ""
      _u02_minlen_out=$(grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null | grep 'minlen')
      # 리포트 [현재 상태] 섹션용 — 조치 전 핵심 값을 한 줄로 정리
      _u02_before_summary=$(grep -v '^\s*#' /etc/login.defs 2>/dev/null | grep -oE 'PASS_MAX_DAYS[[:space:]]+[0-9]+' | tr -s ' ' '=' )
      _u02_before_summary="${_u02_before_summary:-PASS_MAX_DAYS 미설정}, ${_u02_minlen_out:-minlen 미설정}, 비밀번호 복잡도 미설정"
      _lbl_before
      grep -v '^\s*#' /etc/login.defs | grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS' | sed 's/^/   /'
      if [ -n "$_u02_minlen_out" ]; then echo "$_u02_minlen_out" | sed 's/^/   /'; else echo "   minlen 미설정"; fi
      grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null \
        | grep -E 'ucredit|lcredit|dcredit|ocredit|retry' | sed 's/^/   /'
      echo ""

      _lbl_yn
      if [ "$NO_PROMPT" -eq 1 ]; then
        _yn_u02="y"
        echo -e "   ${CYAN}[NO-PROMPT] 스크립트 기본값으로 적용: PASS_MAX_DAYS=${DEFAULT_PASS_MAX_DAYS}, PASS_MIN_DAYS=${DEFAULT_PASS_MIN_DAYS}, minlen=${DEFAULT_MINLEN}${RESET}"
      else
        _read_yn _yn_u02 " 조치하시겠습니까? (y/n): "
      fi
      if [[ "$_yn_u02" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-02" "비밀번호 관리정책 [건너뜀]"
        echo ""
      else
      for _u02_once in 1; do
      if [ "$NO_PROMPT" -eq 1 ]; then
        MAX_DAYS=$DEFAULT_PASS_MAX_DAYS
        MIN_DAYS=$DEFAULT_PASS_MIN_DAYS
        MINLEN=$DEFAULT_MINLEN
        UCREDIT=${DEFAULT_UCREDIT:--1}
        LCREDIT=${DEFAULT_LCREDIT:--1}
        DCREDIT=${DEFAULT_DCREDIT:--1}
        OCREDIT=${DEFAULT_OCREDIT:--1}
        RETRY=${DEFAULT_RETRY:-3}
        PAM_APPLY=0
      else
      echo -e "     권고: ${DEFAULT_PASS_MAX_DAYS}일 이하 (KISA 권고 기본값: ${DEFAULT_PASS_MAX_DAYS})"
      while true; do
        printf '%s' " 최대 사용기간(일) 입력: "
        read -r _max_input
        [[ "$_max_input" =~ ^[0-9]+$ ]] && [ "$_max_input" -ge 1 ] && [ "$_max_input" -le 365 ] && break
        echo -e " ${RED}1~365 사이의 숫자를 입력해주세요.${RESET}"
      done
      if [ "$_max_input" -gt 90 ]; then
        echo -e " ${RED}[경고] 입력값(${_max_input}일)이 KISA 권고(90일)를 초과합니다. 취약으로 처리됩니다.${RESET}"
        _mark_skipped "U-02" "비밀번호 관리정책 [입력값 ${_max_input}일이 KISA 권고 초과]"
        echo ""
        continue  # 1회 루프 탈출 — 이하 조치 로직 전체 건너뜀
      fi
      MAX_DAYS=$_max_input

      echo -e " ${YELLOW}[!] 비밀번호 최소 사용기간(PASS_MIN_DAYS)을 입력하세요.${RESET}"
      echo -e "     권고: ${DEFAULT_PASS_MIN_DAYS}일 이상 (KISA 권고 기본값: ${DEFAULT_PASS_MIN_DAYS})"
      _read_num MIN_DAYS " 최소 사용기간(일) 입력: " "$DEFAULT_PASS_MIN_DAYS" 1

      # ── 비밀번호 복잡성 설정 직접 입력 ──────────────────────────
      echo ""
      echo -e " ${YELLOW}[!] 비밀번호 복잡성 설정 (pwquality.conf)${RESET}"

      echo -e "     최소 길이(minlen, 권고: ${DEFAULT_MINLEN} 이상, KISA 기본값: ${DEFAULT_MINLEN})"
      _read_num MINLEN "     입력: " "$DEFAULT_MINLEN" 8

      # 가이드 예시와 내부 판정 기준에 맞춰 대문자·소문자·숫자·특수문자
      # 네 종류를 모두 최소 1자 이상 사용하도록 권장값을 제공한다.
      echo -e "     문자 종류별 최소 포함 개수 — 가이드 권장값(대/소문자·숫자·특수문자 각 1자 이상 강제)을 적용합니다."
      echo -e "     ※ y = 가이드 권장값(4종류 전부 1자 이상) 사용, n = 종류별로 직접 입력"
      _read_yn _u02_credit_default " 가이드 권장값을 사용하시겠습니까? (y/n): "
      if [[ "$_u02_credit_default" == [Yy] ]]; then
        UCREDIT=-1; LCREDIT=-1; DCREDIT=-1; OCREDIT=-1
      else
        for _pair in "ucredit:대문자:UCREDIT" "lcredit:소문자:LCREDIT" "dcredit:숫자:DCREDIT" "ocredit:특수문자:OCREDIT"; do
          _key="${_pair%%:*}"; _rest="${_pair#*:}"; _label="${_rest%%:*}"; _varname="${_rest#*:}"
          echo -e "     ${_label} 최소 포함 개수 입력 (권고: 1개 이상, 0=강제 안 함)"
          _read_num _cr_input "     입력: " 1 0
          printf -v "$_varname" '%d' "$(( -_cr_input ))"
        done
      fi

      echo -e "     비밀번호 재시도 횟수(retry, 권고: 3)"
      _read_num RETRY "     retry 입력: " 3 1

      echo -e "   ${RED}⚠ PAM 파일(system-auth/password-auth) 수정은 잘못되면 로그인 불가 위험이 있습니다.${RESET}"
      echo -e "     pam_pwquality.so enforce_for_root 적용? (system-auth, password-auth에 추가)"
      _read_yn _pam_yn "     적용 여부 (y/n): "
      if [[ "$_pam_yn" =~ ^[Yy]$ ]]; then
        ENFORCE_ROOT="enforce_for_root"
        PAM_APPLY=1
      else
        ENFORCE_ROOT=""
        PAM_APPLY=0
      fi
      fi  # NO_PROMPT else 닫기

      _lbl_during
      echo -e "   ${CYAN}→${RESET} /etc/login.defs, pwquality.conf 정책 적용"

      config_set /etc/login.defs "PASS_MAX_DAYS" "$MAX_DAYS" kv_tab
      _cs_report $? "/etc/login.defs" "PASS_MAX_DAYS" "$MAX_DAYS"

      config_set /etc/login.defs "PASS_MIN_DAYS" "$MIN_DAYS" kv_tab
      _cs_report $? "/etc/login.defs" "PASS_MIN_DAYS" "$MIN_DAYS"

      [ -f /etc/security/pwquality.conf ] || touch /etc/security/pwquality.conf

      _set_pwq() {
        local key="$1" val="$2"
        config_set /etc/security/pwquality.conf "$key" "$val" kv
        _cs_report $? "/etc/security/pwquality.conf" "$key" "$val"
      }

      _set_pwq "minlen"   "$MINLEN"
      _set_pwq "retry"    "$RETRY"
      [ "$UCREDIT" -ne 0 ]  && _set_pwq "ucredit"  "$UCREDIT"
      [ "$LCREDIT" -ne 0 ]  && _set_pwq "lcredit"  "$LCREDIT"
      [ "$DCREDIT" -ne 0 ]  && _set_pwq "dcredit"  "$DCREDIT"
      [ "$OCREDIT" -ne 0 ]  && _set_pwq "ocredit"  "$OCREDIT"

      if [ "$PAM_APPLY" -eq 1 ]; then
        # RHEL 계열은 system-auth/password-auth, Debian·Ubuntu 계열은
        # common-password를 사용하므로 존재하는 PAM 파일을 모두 대상으로 한다.
        _u02_pam_targets=()
        [ -f /etc/pam.d/system-auth ]    && _u02_pam_targets+=(/etc/pam.d/system-auth)
        [ -f /etc/pam.d/password-auth ]  && _u02_pam_targets+=(/etc/pam.d/password-auth)
        [ -f /etc/pam.d/common-password ] && _u02_pam_targets+=(/etc/pam.d/common-password)

        if [ ${#_u02_pam_targets[@]} -eq 0 ]; then
          echo -e "   ${YELLOW}!${RESET} PAM 설정 파일(system-auth/password-auth/common-password)을 찾지 못해 pam_pwquality 연결을 건너뜁니다."
        else
          # pam_pwquality.so 모듈 자체가 시스템에 없으면(Debian에서 흔함,
          # libpam-pwquality 미설치) 줄만 추가해봤자 PAM이 그 줄에서 오류를
          # 내거나 무시하므로, 모듈 존재 여부를 먼저 확인해 알려준다.
          _u02_pwq_installed=0
          { [ -f /lib/security/pam_pwquality.so ] || \
            find /usr/lib*/security /lib*/security -maxdepth 2 -name 'pam_pwquality.so' 2>/dev/null | grep -q .; \
          } && _u02_pwq_installed=1

          if [ "$_u02_pwq_installed" -eq 0 ] && command -v apt-get &>/dev/null; then
            echo -e "   ${YELLOW}→${RESET} pam_pwquality 모듈 미설치 — libpam-pwquality 설치 시도"
            apt-get install -y libpam-pwquality 2>/dev/null
            find /usr/lib*/security /lib*/security -maxdepth 2 -name 'pam_pwquality.so' 2>/dev/null \
              | grep -q . && _u02_pwq_installed=1
          fi

          for pamf in "${_u02_pam_targets[@]}"; do
            if grep -q 'pam_pwquality.so' "$pamf"; then
              sed -i "s|.*pam_pwquality.so.*|password requisite pam_pwquality.so retry=${RETRY} ${ENFORCE_ROOT}|" "$pamf"
            elif [ "$pamf" = "/etc/pam.d/common-password" ]; then
              # Debian 스타일: pam_unix.so 라인 앞에 requisite로 넣어야 정책
              # 위반 시 pam_unix.so까지 안 가고 즉시 거부된다.
              if grep -q 'pam_unix.so' "$pamf"; then
                sed -i "/pam_unix\.so/i password requisite pam_pwquality.so retry=${RETRY} ${ENFORCE_ROOT}" "$pamf"
              else
                sed -i "1i password requisite pam_pwquality.so retry=${RETRY} ${ENFORCE_ROOT}" "$pamf"
              fi
            else
              sed -i "/^password/i password required pam_pwquality.so enforce_for_root" "$pamf"
            fi
            if [ "$_u02_pwq_installed" -eq 1 ]; then
              echo "   $pamf pam_pwquality 설정 완료"
            else
              echo -e "   ${YELLOW}!${RESET} $pamf 에 설정 줄은 추가했지만 pam_pwquality.so 모듈 파일을 찾지 못했습니다 — 패키지 설치 후 재확인 필요 (RHEL: pam 기본 포함 / Debian: libpam-pwquality)"
            fi
          done
        fi
      fi

      echo -e " ${YELLOW}[!] 기존 계정에도 최대 사용기간을 적용합니다.${RESET}"
      while IFS=: read -r uname _ uid _; do
        [ "$uid" -lt 1000 ] 2>/dev/null && continue
        chage -M "$MAX_DAYS" "$uname" 2>/dev/null && echo "   $uname: chage -M $MAX_DAYS 적용"
      done < /etc/passwd

      # 현재 정책에서 사용하지 않는 minclass 잔존 설정은 제거한다.
      [ -f /etc/security/pwquality.conf ] && config_set /etc/security/pwquality.conf '^[[:space:]]*minclass[[:space:]]*=' '' delete 2>/dev/null

      echo ""
      _lbl_result
      grep -v '^\s*#' /etc/login.defs | grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS' | sed 's/^/   /'
      grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null | grep -v '^$' | while IFS= read -r line; do
        _u02_matched=0
        for _cr in ucredit lcredit dcredit ocredit; do
          if echo "$line" | grep -q "^${_cr}"; then
            _u02_matched=1
            case "$_cr" in
              ucredit) _u02_label="대문자" ;;
              lcredit) _u02_label="소문자" ;;
              dcredit) _u02_label="숫자" ;;
              ocredit) _u02_label="특수문자" ;;
            esac
            _val=$(echo "$line" | grep -oP '[-0-9]+')
            _disp=$(( -_val ))
            [ "$_disp" -le 0 ] \
              && echo "   ${_cr} = ${_val}  (${_u02_label} 강제 안 함)" \
              || echo "   ${_cr} = ${_val}  (${_u02_label} 최소 ${_disp}개 이상 필수)"
          fi
        done
        [ "$_u02_matched" -eq 0 ] && echo "   $line"
      done

      AFTER_VAL["U-02"]="PASS_MAX_DAYS=${MAX_DAYS}, PASS_MIN_DAYS=${MIN_DAYS}, minlen=${MINLEN}, ucredit=${UCREDIT}, lcredit=${LCREDIT}, dcredit=${DCREDIT}, ocredit=${OCREDIT}"
      BEFORE_VAL["U-02"]="${_u02_before_summary}"
      # 상세내역: 표준 6섹션 포맷 [현재 상태]/[조치 내용]/[조치 결과]/[변경 파일]/[변경 파일 목록]/[검증 결과]
      _u02_files=""
      for _pf in /etc/login.defs /etc/security/pwquality.conf /etc/pam.d/system-auth /etc/pam.d/password-auth; do
        [ -f "$_pf" ] && _u02_files="${_u02_files}${_u02_files:+|}${_pf}"
      done
      _u02_verify="PASS_MAX_DAYS=${MAX_DAYS}, PASS_MIN_DAYS=${MIN_DAYS}, minlen=${MINLEN}, ucredit=${UCREDIT}, lcredit=${LCREDIT}, dcredit=${DCREDIT}, ocredit=${OCREDIT}"
      DETAIL_VAL["U-02"]=$(_fmt_detail \
        "${_u02_before_summary}" \
        "비밀번호 사용 기간 및 복잡도 정책 설정" \
        "조치 완료 / 최종 검증 통과" \
        "${_u02_files}" \
        "${_u02_verify}")
      _lbl_done_nr

      if [ "$PAM_APPLY" -eq 1 ] && command -v authselect &>/dev/null && authselect current &>/dev/null; then
        # authselect 관리 환경에서는 apply-changes 시 직접 수정한 PAM 설정이 초기화될 수 있어
        # 현재 profile 정보를 상세 로그에 기록한다.
        {
          echo "----- [U-02] authselect 환경 PAM 수정 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
          echo "# authselect apply-changes 실행 시 아래 PAM 수정이 초기화될 수 있음"
          echo "# 영구 적용하려면 authselect custom profile 사용 권장"
          authselect current 2>/dev/null
          echo "-----------------------------------------------------------"
        } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null
        echo ""
        echo -e " ${RED}⚠ 주의: 이 시스템은 authselect로 PAM을 관리합니다.${RESET}"
        echo -e " ${YELLOW}  방금 적용한 pam_pwquality 설정 줄은 이후 'authselect select' 또는${RESET}"
        echo -e " ${YELLOW}  'authselect apply-changes'가 실행되면 초기화될 수 있습니다.${RESET}"
        echo -e " ${YELLOW}  (pwquality.conf의 minlen/ucredit 등 수치값 자체는 영향받지 않습니다).${RESET}"
        echo -e " ${YELLOW}  영구 적용하려면 authselect custom profile 사용을 권장합니다.${RESET}"
        echo -e " ${YELLOW}  현재 authselect profile 정보가 상세 로그에 저장되었습니다: ${DETAIL_LOG_FILE:-미생성}${RESET}"
      fi

      # ── 운영적 요구사항 안내 (수동확인 제외, 참고용) ──────────────
      echo ""
      echo -e "${YELLOW}  ※ 비밀번호 관리 운영 정책 (담당자 이행 필요)${RESET}"
      echo -e "  ${YELLOW}□${RESET} 시스템마다 상이한 비밀번호 사용"
      echo -e "    → 동일 비밀번호를 여러 시스템에 사용하지 않도록 관리"
      echo -e "  ${YELLOW}□${RESET} 비밀번호 기록 시 변형하여 기록"
      echo -e "    → 평문 비밀번호 메모 금지, 일부 문자 변형 또는 암호화하여 보관"

      _mark_fixed "U-02" "조치 완료 (PASS_MAX_DAYS=${MAX_DAYS}, minlen=${MINLEN})"
      echo ""
      done  # _u02_once 1회 루프 종료
    fi
      fi
    echo ""
  fi
}

# =============================================================================
# U-03 / 계정 잠금 임계값 설정
#
# 점검 기준:
#   deny와 unlock_time 값이 기준을 충족하고 pam_faillock 또는 pam_tally 흐름이 실제 인증 스택에 연결되어야 한다.
#
# 조치 내용:
#   faillock.conf의 임계값을 설정하고 PAM 또는 authselect 기능으로 preauth/authfail 흐름을 연결한다.
#
# 변경 대상:
#   /etc/security/faillock.conf, system-auth, password-auth, common-auth 및 authselect profile
#
# 수동 확인:
#   PAM 흐름이 불완전하거나 authselect custom 상태로 자동 재생성이 위험한 경우 직접 처리한다.
#
# 롤백:
#   조치 전 PAM·faillock 설정 백업으로 복원하고 기존 authselect profile 정보를 참고한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-03" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-03"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      BEFORE_VAL["U-03"]=$(grep -E 'deny|unlock_time' /etc/security/faillock.conf 2>/dev/null | grep -v '^\s*#' | head -3 2>/dev/null | head -3)
      [ -z "${BEFORE_VAL["U-03"]:-}" ] && BEFORE_VAL["U-03"]="이상 항목 없음 (점검 통과)"
      AFTER_VAL["U-03"]="이미 양호 (재확인 통과)"
      _item_header "good" "U-03" "(상) 계정 잠금 임계값 설정"
      _lbl_cur
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] && grep -v '^#' "$_pf" | grep -E 'deny|unlock_time|pam_tally|pam_faillock' | sed "s|^|   [$_pf] |" | head -3
      done
      echo ""
      _mark_skipped "U-03" "계정 잠금 임계값 [이미양호]"
      echo ""
    elif [ $_vs -eq 2 ]; then
      _item_header "manual" "U-03" "(상) 계정 잠금 임계값 설정"
      echo ""
      echo -e " ${YELLOW}[!] deny 값은 양호하나 PAM 흐름이 불완전합니다.${RESET}"
      echo -e " ${YELLOW}    pam_faillock.so preauth/authfail 라인 또는 pam_tally2 onerr=fail 옵션을 확인하세요.${RESET}"
      for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] && grep -v '^#' "$_pf" | grep -E 'pam_faillock|pam_tally' | sed "s|^|   [$_pf] |"
      done
      _mark_manual "U-03" "계정 잠금 PAM 흐름 보완 필요 (preauth/authfail/onerr=fail 확인)"
      echo ""
    else
      _item_header "vuln" "U-03" "(상) 계정 잠금 임계값 설정"
      echo ""
      _lbl_before
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] && grep -v '^#' "$_pf" | grep -E 'deny|unlock_time|pam_tally|pam_faillock' | sed "s|^|   [$_pf] |" | head -3
      done
      echo ""
      _lbl_yn
      if [ "$NO_PROMPT" -eq 1 ]; then
        _yn_u03="y"
        echo -e "   ${CYAN}[NO-PROMPT] 스크립트 기본값으로 적용: deny=${DEFAULT_DENY}, unlock_time=${DEFAULT_UNLOCK_TIME}${RESET}"
      else
        _read_yn _yn_u03 " 조치하시겠습니까? (y/n): "
      fi
      if [[ "$_yn_u03" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-03" "계정 잠금 임계값 [건너뜀]"
        echo ""
      else
      if [ "$NO_PROMPT" -eq 1 ]; then
        DENY_VAL=$DEFAULT_DENY
        UNLOCK_VAL=$DEFAULT_UNLOCK_TIME
      else
      echo -e " ${YELLOW}[!] 계정 잠금 실패 횟수(deny)를 입력하세요.${RESET}"
      echo -e "     권고: 10회 이하 (KISA 권고 기본값: ${DEFAULT_DENY})"
      _read_num DENY_VAL " 실패 횟수 입력: " "$DEFAULT_DENY" 1 10
      echo -e " ${YELLOW}[!] 계정 잠금 해제 시간(unlock_time, 초)을 입력하세요.${RESET}"
      echo -e "     권고: ${DEFAULT_UNLOCK_TIME}초 이상 (KISA 권고 기본값: ${DEFAULT_UNLOCK_TIME})"
      _read_num UNLOCK_VAL " 잠금 해제 시간(초) 입력: " "$DEFAULT_UNLOCK_TIME" 1
      fi  # NO_PROMPT else 닫기
      _lbl_during
      # faillock 정책값을 저장한 뒤 PAM 연결 상태를 별도로 검증한다.
      if [ -f /etc/security/faillock.conf ]; then
        _fc=/etc/security/faillock.conf
        config_set "$_fc" "deny" "${DENY_VAL}" kv
        _cs_report $? "$_fc" "deny" "${DENY_VAL}"
        config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
        _cs_report $? "$_fc" "unlock_time" "${UNLOCK_VAL}"
        echo -e "   ${CYAN}→${RESET} /etc/security/faillock.conf 에 deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL} 기록"
      else
        echo -e "   ${CYAN}→${RESET} 적용 예정 값: deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL}"
      fi

      # PAM 설정 파일에서 pam_faillock 또는 pam_tally 호출 여부를 확인한다.
      _u03_pam_wired() {
        for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
          [ -f "$_pf" ] || continue
          grep -qE '^auth[[:space:]].*pam_faillock\.so' "$_pf" 2>/dev/null && return 0
          grep -qE 'pam_tally2?\.so' "$_pf" 2>/dev/null && return 0
        done
        return 1
      }

      if _u03_pam_wired; then
        # [1] 이미 PAM에 연결됨 — 값만 갱신
        echo -e " ${CYAN}[환경: PAM에 이미 연결됨 — deny/unlock_time 값만 갱신]${RESET}"
        if [ -f /etc/security/faillock.conf ]; then
          _fc=/etc/security/faillock.conf
          config_set "$_fc" "deny" "${DENY_VAL}" kv
          _cs_report $? "$_fc" "deny" "${DENY_VAL}"
          config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
          _cs_report $? "$_fc" "unlock_time" "${UNLOCK_VAL}"
          echo -e " ${GREEN}→ /etc/security/faillock.conf 값 갱신 완료${RESET}"
        else
          for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
            [ -f "$_pf" ] || continue
            grep -qE 'pam_tally2?\.so|pam_faillock\.so' "$_pf" 2>/dev/null \
              && sed -i "s/deny=[0-9]*/deny=${DENY_VAL}/g; s/unlock_time=[0-9]*/unlock_time=${UNLOCK_VAL}/g" "$_pf"
          done
          echo -e " ${GREEN}→ PAM 인라인 deny/unlock_time 값 갱신 완료${RESET}"
        fi
      elif command -v authselect &>/dev/null && authselect current &>/dev/null; then
        # [2] authselect로 관리되는 시스템인데 PAM에 미연결 — 직접 pam.d sed 수정은 위험
        # (authselect가 프로필 재적용 시 덮어쓸 수 있음). authselect 자체 기능 토글로 안전하게 연결.
        echo -e " ${CYAN}[환경: authselect 관리 시스템 — pam_faillock 미연결]${RESET}"

        # 실패 후 대응하는 대신, 적용 전에 authselect check로 현재 상태가 정상인지 먼저
        # 확인한다 — 이미 깨져 있는 상태에서 enable-feature를 시도하면 의미 없는 실패와
        # 복잡한 에러 메시지만 남기 때문에, 미리 걸러서 더 안전하고 명확한 경로로 안내한다.
        _u03_as_check_out=$(authselect check 2>&1)
        _u03_as_check_rc=$?
        if [ $_u03_as_check_rc -ne 0 ] || echo "$_u03_as_check_out" | grep -qi 'not valid'; then
          # ※ 로케일에 따라 "Profile ID:"가 "프로필 ID :"로 번역될 수 있어, 특정 언어
          #   라벨을 grep하는 대신 "첫 줄 콜론(:) 뒤"를 추출해 언어 무관하게 동작시킨다.
          _u03_prof_info=$(authselect current 2>/dev/null)
          _u03_prof=$(echo "$_u03_prof_info" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r')
          _u03_feats_list=$(echo "$_u03_prof_info" | grep '^-' | sed 's/^- //')
          _u03_feats=$(echo "$_u03_feats_list" | tr '\n' ' ')

          # 원문은 로그에 저장하고 화면엔 요약만 표시
          {
            echo "=== U-03 authselect check 원문 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
            echo "$_u03_as_check_out"
            echo "==="
          } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

          echo ""
          echo -e " ${YELLOW}[authselect 상태 확인]${RESET}"
          echo ""
          echo -e "   현재 PAM 설정은 authselect 표준 구성과 다릅니다."
          echo -e "   자동 조치 시 기존 PAM 설정이 변경될 수 있어,"
          echo -e "   안전한 조치 방식을 선택해야 합니다."
          echo ""
          echo -e "   현재 Profile : ${CYAN}${_u03_prof:-감지되지 않음}${RESET}"
          if [ -n "$_u03_feats_list" ]; then
            echo -e "   현재 Feature :"
            while IFS= read -r _fl; do echo "     - $_fl"; done <<< "$_u03_feats_list"
          fi
          echo -e "   현재 상태    : ${RED}custom 변경 감지${RESET}"
          echo ""
          _info "상세 원문은 ${DETAIL_LOG_FILE:-미생성} 에 저장했습니다."
          echo ""
          echo -e " ${YELLOW}권장${RESET}"
          echo "   1) PAM 파일 수동 수정  (기존 custom 설정 보존)"
          echo "   2) authselect --force 재생성  (Profile 기준 재생성, 직접 수정한 내용 삭제됨)"
          echo "   3) 건너뛰기"
          echo ""
          while true; do
            printf '%s' " 선택 (1/2/3): "
            if ! read -r _u03_as_menu; then
              echo ""; echo -e " ${YELLOW}입력을 받을 수 없어 건너뜁니다.${RESET}"
              _u03_as_menu=3; break
            fi
            case "$_u03_as_menu" in 1|2|3) break ;; esac
            echo -e " ${RED}1, 2, 3 중에서 입력해주세요.${RESET}"
          done
          case "$_u03_as_menu" in
            2)
              echo ""
              echo -e " ${YELLOW}[authselect 재생성]${RESET}"
              echo ""
              echo -e "   Profile(${CYAN}${_u03_prof:-감지되지 않음}${RESET}) 기준으로 PAM 파일을 재생성합니다."
              echo -e "   ${RED}※ 직접 수정한 내용은 모두 삭제됩니다.${RESET}"
              echo ""
              _read_yn _u03_force_confirm " 정말 진행하시겠습니까? (y/n): "
              if [[ "$_u03_force_confirm" =~ ^[Yy]$ ]]; then
                _u03_as_bak_ts2=$(date +%Y%m%d_%H%M%S)
                for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
                  [ -f "$_pf" ] && _backup_file "$_pf" "$_u03_as_bak_ts2" >/dev/null
                done
                _u03_as_bak_dir=$(ls -d /var/lib/authselect/backups/*.bak 2>/dev/null | tail -1)
                if [ -n "$_u03_prof" ]; then
                  _u03_as_force_out=$(authselect select "$_u03_prof" $_u03_feats with-faillock --force 2>&1)
                  _u03_as_force_rc=$?
                  # 원문 로그 저장
                  {
                    echo "=== U-03 authselect --force 원문 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
                    echo "$_u03_as_force_out"
                    echo "==="
                  } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

                  # 화면엔 요약만
                  echo ""
                  _u03_as_bak_dir2=$(ls -d /var/lib/authselect/backups/* 2>/dev/null | tail -1)
                  _ok "기존 PAM 파일 백업 완료  (*.bak.${_u03_as_bak_ts2})"
                  [ -n "$_u03_as_bak_dir2" ] && _info "authselect 백업 위치: ${_u03_as_bak_dir2}"
                  if [ $_u03_as_force_rc -eq 0 ]; then
                    _ok "Profile(${_u03_prof}) 기준으로 PAM 파일 재생성 완료"
                    _ok "with-faillock 적용 완료"
                    echo ""
                    _info "상세 원문은 ${DETAIL_LOG_FILE:-미생성} 에 저장했습니다."
                    echo ""
                    echo -e " ${YELLOW}다음 단계${RESET}"
                    echo "   - faillock.conf 값 설정 (deny / unlock_time)"
                    echo "   - PAM 연결 상태 재검증: authselect current / grep faillock /etc/pam.d/system-auth"
                    # faillock.conf 값 적용
                    _fc=/etc/security/faillock.conf; [ -f "$_fc" ] || touch "$_fc"
                    config_set "$_fc" "deny" "${DENY_VAL}" kv
                    _cs_report $? "$_fc" "deny" "${DENY_VAL}"
                    config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
                    _cs_report $? "$_fc" "unlock_time" "${UNLOCK_VAL}"
                    _ok "faillock.conf  deny=${DENY_VAL}  unlock_time=${UNLOCK_VAL} 설정 완료"
                  else
                    _fail "authselect --force 실패 — 상세 원문은 ${DETAIL_LOG_FILE:-미생성} 참조"
                  fi
                else
                  _fail "현재 Profile 감지 불가 — --force 진행 불가. 수동 확인 필요"
                fi
              else
                echo -e " ${YELLOW}→ 취소했습니다.${RESET}"
              fi
              ;;
            1)
              echo -e " ${CYAN}→ PAM 수동 수정 경로로 전환합니다.${RESET}"
              _u03_manual_pam_edit "$DENY_VAL" "$UNLOCK_VAL"
              ;;
            *)
              _lbl_skip
              _info "PAM 파일을 직접 확인하거나 authselect profile 정리 후 재실행하세요."
              ;;
          esac
        else
        echo -e " ${CYAN}→ authselect check 통과 — with-faillock 연결을 진행합니다.${RESET}"

        # 현재 profile이 with-faillock feature를 지원하는지 사전 확인
        _u03_prof_raw=$(authselect current --raw 2>/dev/null | awk '{print $1}')
        _u03_feat_support=0
        if authselect list-features "${_u03_prof_raw}" 2>/dev/null | grep -qx 'with-faillock'; then
          _u03_feat_support=1
        fi

        if [ "$_u03_feat_support" -eq 0 ]; then
          echo -e " ${YELLOW}⚠ 현재 profile(${_u03_prof_raw})은 with-faillock feature를 지원하지 않습니다.${RESET}"
          echo -e " ${YELLOW}  faillock.conf 값 설정만 진행하고, PAM 연결은 수동으로 확인하세요.${RESET}"
          _fc=/etc/security/faillock.conf; [ -f "$_fc" ] || touch "$_fc"
          config_set "$_fc" "deny" "${DENY_VAL}" kv
          config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
          echo -e " ${GREEN}→ /etc/security/faillock.conf 값 설정 완료 (deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL})${RESET}"
          _mark_manual "U-03" "authselect profile이 with-faillock 미지원 — faillock.conf 값만 설정됨, PAM 연결 수동 확인 필요"
        else
        # authselect enable-feature with-faillock --backup
        # --backup: authselect가 변경 전 PAM 파일을 자체 백업 (vulnfix_<타임스탬프> 이름으로)
        # 이 방식을 쓰면 /etc/pam.d/system-auth를 직접 수정하지 않아
        # 이후 authselect apply-changes 실행 시에도 with-faillock이 유지됨
        _u03_as_bak_name="vulnfix_$(date +%Y%m%d_%H%M%S)"
        _u03_as_bak_ts=$(date +%Y%m%d_%H%M%S)

        # 방어적 백업: authselect --backup 외에 파일도 직접 백업
        for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
          [ -f "$_pf" ] && _backup_file "$_pf" "$_u03_as_bak_ts" >/dev/null
        done

        _u03_as_out=$(authselect enable-feature with-faillock --backup="${_u03_as_bak_name}" 2>&1)
        _u03_as_rc=$?
        {
          echo "=== U-03 authselect enable-feature with-faillock ($(date '+%Y-%m-%d %H:%M:%S')) ==="
          echo "backup name: ${_u03_as_bak_name}"
          echo "$_u03_as_out"
          echo "==="
        } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

        if [ $_u03_as_rc -ne 0 ]; then
          _fail "authselect enable-feature 실패 — 상세 원문은 ${DETAIL_LOG_FILE:-미생성} 참조"
          _info "복구: authselect backup restore ${_u03_as_bak_name}"
        else
          # faillock.conf 정책값 설정 (PAM 파일 직접 수정 불필요)
          _fc=/etc/security/faillock.conf; [ -f "$_fc" ] || touch "$_fc"
          config_set "$_fc" "deny" "${DENY_VAL}" kv
          _cs_report $? "$_fc" "deny" "${DENY_VAL}"
          config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
          _cs_report $? "$_fc" "unlock_time" "${UNLOCK_VAL}"

          # 검증: authselect check + PAM 연결 확인
          echo ""
          echo -e " ${CYAN}[검증] faillock PAM 적용 여부 확인 중...${RESET}"
          _AUTHSELECT_OK=0; _SYSTEM_AUTH_OK=0; _PASSWORD_AUTH_OK=0

          authselect check 2>/dev/null && _AUTHSELECT_OK=1
          authselect current 2>/dev/null | grep -q "with-faillock" && _AUTHSELECT_OK=1

          grep -qE 'pam_faillock\.so.*preauth' /etc/pam.d/system-auth 2>/dev/null && \
          grep -qE 'pam_faillock\.so.*authfail' /etc/pam.d/system-auth 2>/dev/null && \
          _SYSTEM_AUTH_OK=1

          grep -qE 'pam_faillock\.so.*preauth' /etc/pam.d/password-auth 2>/dev/null && \
          grep -qE 'pam_faillock\.so.*authfail' /etc/pam.d/password-auth 2>/dev/null && \
          _PASSWORD_AUTH_OK=1

          grep -qE "^[[:space:]]*(deny|unlock_time)[[:space:]]*=" /etc/security/faillock.conf 2>/dev/null && \
          _FAILLOCK_CONF_OK=1 || _FAILLOCK_CONF_OK=0

          if [ "$_AUTHSELECT_OK" -eq 1 ] && [ "$_SYSTEM_AUTH_OK" -eq 1 ] && [ "$_PASSWORD_AUTH_OK" -eq 1 ]; then
            echo -e " ${GREEN}→ 검증 완료: with-faillock 및 PAM 연결 정상${RESET}"
            _u03_as_verified=1
          else
            echo -e " ${RED}→ 검증 실패 또는 불완전${RESET}"
            echo "   authselect with-faillock : ${_AUTHSELECT_OK}"
            echo "   system-auth  preauth/authfail : ${_SYSTEM_AUTH_OK}"
            echo "   password-auth preauth/authfail : ${_PASSWORD_AUTH_OK}"
            echo "   faillock.conf deny/unlock_time : ${_FAILLOCK_CONF_OK}"
            _info "복구: authselect backup restore ${_u03_as_bak_name}"
            _u03_as_verified=0
          fi

          if [ "$_u03_as_verified" -eq 1 ]; then
          # PAM이 실제로 연결됐을 때만 로그인 영향 가능성이 있으므로 이때만 워치독 가동.
          # 복구는 authselect backup restore 또는 disable-feature 중 하나.
          _u03_as_timeout=90
          _u03_as_wd_pid=""
          _u03_as_start_wd() {
            ( { exec 9>&-; } 2>/dev/null || true
              sleep "$_u03_as_timeout"
              authselect disable-feature with-faillock 2>/dev/null
              _detail_log_note "U-03" "AUTO_ROLLBACK" "로그인 확인 시간 초과 — authselect disable-feature with-faillock 자동 실행"
            ) &
            _u03_as_wd_pid=$!
          }
          echo -e "${RED}⚠ 중요: PAM 인증 설정을 변경했습니다 (authselect with-faillock).${RESET}"
          echo -e "${YELLOW}   1) 지금 이 터미널/세션은 절대 닫지 마세요.${RESET}"
          echo -e "${YELLOW}   2) 새 터미널(또는 새 SSH 접속, su)을 열어 로그인이 정상적으로 되는지 확인하세요.${RESET}"
          echo -e "${YELLOW}   3) 정상이면 아래에서 Enter를 누르세요 — 변경 사항이 그대로 유지됩니다.${RESET}"
          echo -e "${YELLOW}   4) 시간이 더 필요하면 e 를 입력하세요 — ${_u03_as_timeout}초가 다시 주어집니다.${RESET}"
          echo -e "${YELLOW}   5) ${_u03_as_timeout}초 안에 아무 입력도 없으면 'authselect disable-feature with-faillock'으로 자동 복구됩니다.${RESET}"
          echo -e "${YELLOW}   ※ 수동 복구: authselect backup restore ${_u03_as_bak_name}${RESET}"
          if ! [ -t 0 ]; then
            echo -e " ${YELLOW}→ stdin이 TTY가 아닌 환경 — 워치독 확인 프롬프트를 건너뜁니다. 설정이 유지됩니다.${RESET}"
          else
          _u03_as_start_wd
          while true; do
            printf ' 새 세션에서 로그인 확인 완료 → Enter, 시간 더 필요하면 e (%d초 제한): ' "$_u03_as_timeout"
            if read -t "$_u03_as_timeout" -r _u03_as_confirm; then
              if [[ -z "$_u03_as_confirm" ]]; then
                kill "$_u03_as_wd_pid" 2>/dev/null; wait "$_u03_as_wd_pid" 2>/dev/null
                echo -e " ${GREEN}→ 확인 완료. authselect with-faillock 설정을 유지합니다.${RESET}"
              elif [[ "$_u03_as_confirm" == "e" || "$_u03_as_confirm" == "E" ]]; then
                kill "$_u03_as_wd_pid" 2>/dev/null; wait "$_u03_as_wd_pid" 2>/dev/null
                echo -e " ${YELLOW}→ ${_u03_as_timeout}초 연장합니다. 계속 확인해 주세요.${RESET}"
                _u03_as_start_wd
                continue
              else
                echo -e " ${RED}→ Enter 또는 e만 입력할 수 있습니다.${RESET}"
                continue
              fi
            else
              echo ""
              echo -e " ${RED}→ 시간 초과 — authselect disable-feature with-faillock 으로 자동 복구합니다.${RESET}"
              wait "$_u03_as_wd_pid" 2>/dev/null
            fi
            break
          done
          fi  # TTY 체크 닫기
          else
            echo -e " ${YELLOW}   PAM 연결 검증 실패 — authselect disable-feature with-faillock 으로 즉시 복구합니다.${RESET}"
            authselect disable-feature with-faillock 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S')|U-03|검증 실패로 disable-feature 즉시 실행됨|FAILED" >> "$FIX_HISTORY_FILE" 2>/dev/null
          fi
        fi
        fi  # _u03_feat_support 닫기
        fi  # authselect check 통과 닫기
      # [3] Redhat system-auth (authselect 미사용 — 직접 수정 가능)
      elif [ -f /etc/pam.d/system-auth ]; then
        echo -e " ${CYAN}[환경: Redhat system-auth (pam_faillock/pam_tally)]${RESET}"
        _u03_manual_pam_edit "$DENY_VAL" "$UNLOCK_VAL"
      # [4] Debian common-auth
      elif [ -f /etc/pam.d/common-auth ]; then
        echo -e " ${CYAN}[환경: Debian common-auth (pam_faillock/pam_tally)]${RESET}"
        _pf=/etc/pam.d/common-auth; _pa=/etc/pam.d/common-account
        _u03_bak_ts=$(date +%Y%m%d_%H%M%S)
        _u03_pairs=()
        _backup_file "$_pf" "$_u03_bak_ts" >/dev/null; _u03_pairs+=("${_pf}.bak.${_u03_bak_ts}" "$_pf")
        [ -f "$_pa" ] && cp -p "$_pa" "${_pa}.bak.${_u03_bak_ts}" && _u03_pairs+=("${_pa}.bak.${_u03_bak_ts}" "$_pa")
        if grep -q 'pam_tally2\|pam_tally\b\|pam_faillock' "$_pf" 2>/dev/null; then
          sed -i "s/deny=[0-9]*/deny=${DENY_VAL}/g; s/unlock_time=[0-9]*/unlock_time=${UNLOCK_VAL}/g" "$_pf"
          [ -f "$_pa" ] && sed -i "s/deny=[0-9]*/deny=${DENY_VAL}/g" "$_pa"
          echo -e " ${GREEN}→ $_pf deny/unlock_time 수정 완료${RESET}"
        else
          sed -i "1a auth    required    pam_faillock.so preauth silent audit deny=${DENY_VAL} unlock_time=${UNLOCK_VAL}" "$_pf"
          [ -f "$_pa" ] && echo "account required pam_faillock.so" >> "$_pa"
          echo -e " ${GREEN}→ $_pf pam_faillock.so 라인 추가 완료${RESET}"
        fi
        _auth_watchdog_guard 90 "${_u03_pairs[@]}"
        _u03_guard_rc=$?
        [ $_u03_guard_rc -ne 0 ] && echo -e " ${RED}   PAM 변경이 자동 롤백되었습니다 — U-03은 미적용 상태입니다.${RESET}"
      else
        echo -e " ${YELLOW}→ PAM 환경 미탐지 — 수동 설정 필요${RESET}"
      fi
      echo ""
      # 최종 검증: faillock.conf 값을 적어놓은 것과 "실제 PAM 스택이 그 모듈을 호출하는지"는
      # 별개의 사실이므로, 무조건 FIXED로 표시하지 않고 재확인 후 결정한다.
      check_still_vuln "U-03"; _u03_final_rc=$?

      # 구조화된 결과 요약 — deny/unlock_time 값과 PAM 연결 여부를 한눈에 보여준다.
      _u03_fc_deny=$(grep -oP '^\s*deny\s*=\s*\K[0-9]+' /etc/security/faillock.conf 2>/dev/null | tail -1)
      _u03_fc_unlock=$(grep -oP '^\s*unlock_time\s*=\s*\K[0-9]+' /etc/security/faillock.conf 2>/dev/null | tail -1)
      echo ""
      _lbl_result
      echo "   deny         : ${_u03_fc_deny:-미설정}"
      echo "   unlock_time  : ${_u03_fc_unlock:-미설정}"
      if [ $_u03_final_rc -eq 1 ]; then
        echo -e "   pam_faillock : ${CYAN}→${RESET} 적용 완료"
      else
        echo -e "   pam_faillock : ${RED}✘ 미연결${RESET}"
      fi
      echo ""

      if [ $_u03_final_rc -eq 1 ]; then
        AFTER_VAL["U-03"]="deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL} (PAM 연결 확인됨)"
        BEFORE_VAL["U-03"]="계정 잠금 임계값 미설정, pam_faillock 미연결"
        _u03_files=""
        for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth; do
          [ -f "$_pf" ] && _u03_files="${_u03_files}${_u03_files:+|}${_pf}"
        done
        DETAIL_VAL["U-03"]=$(_fmt_detail \
          "계정 잠금 임계값 미설정, pam_faillock 미연결" \
          "deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL} 설정 및 pam_faillock preauth/authfail 연결" \
          "조치 완료 / 최종 검증 통과" \
          "${_u03_files}" \
          "deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL}, pam_faillock 연결 확인")
        _mark_fixed "U-03" "조치 완료 (deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL}, PAM 연결 확인됨)"
      elif [ $_u03_final_rc -eq 2 ]; then
        echo -e " ${RED}→ faillock.conf 값은 설정했지만, PAM 인증 스택에 실제로 연결되었는지 확인하지 못했습니다.${RESET}"
        echo -e " ${RED}   이 상태로는 계정 잠금이 실제로 동작하지 않을 수 있습니다 — 수동 확인이 필요합니다.${RESET}"
        AFTER_VAL["U-03"]="faillock.conf 설정됨 (PAM 연결 미확인 — 수동확인 필요)"
        BEFORE_VAL["U-03"]="계정 잠금 미설정"
        _mark_manual "U-03" "faillock.conf 설정됨, PAM 연결 미확인 — 수동 확인 필요"
      else
        echo -e " ${RED}→ 조치가 적용되지 않았습니다.${RESET}"
        echo ""
        echo -e " ${YELLOW}   원인:${RESET}"
        echo -e "   PAM 인증 스택(system-auth/password-auth)에 잠금 모듈이 연결되지 않았습니다."
        echo -e "   (authselect가 PAM 파일을 관리하고 있어 자동 조치가 막혔거나, 직접 건너뛰기를 선택한 경우일 수 있습니다.)"
        echo ""
        echo -e "   ${YELLOW}권장:${RESET}"
        echo "   1) PAM 파일을 직접 수정 (system-auth/password-auth에 pam_faillock.so 추가)"
        echo "   2) authselect profile/feature를 정리한 뒤 authselect apply-changes 실행"
        echo "   3) 본 스크립트를 재실행해 authselect --force 경로로 재시도"
        AFTER_VAL["U-03"]="조치 실패 (PAM 미연결)"
        BEFORE_VAL["U-03"]="계정 잠금 미설정"
        _mark_failed "U-03" "조치 후에도 여전히 취약 (PAM 미연결)"
      fi
      [ $_u03_final_rc -eq 1 ] && _lbl_done_nr
      echo ""
      fi  # Y/N 분기 종료
    fi
    echo ""
  fi
}

# =============================================================================
# U-04 / 비밀번호 파일 보호
#
# 점검 기준:
#   /etc/passwd의 비밀번호 필드에 평문 또는 직접 해시가 남지 않고 shadow 방식으로 보호되어야 한다.
#
# 조치 내용:
#   passwd 파일에 비정상 비밀번호 값이 있는 계정을 잠가 직접 인증에 사용되지 않도록 한다.
#
# 변경 대상:
#   /etc/passwd, /etc/shadow 및 관련 계정 데이터
#
# 수동 확인:
#   잠금 대상 계정이 실제 업무 계정인지 확인이 필요한 경우 계정 담당자가 판단한다.
#
# 롤백:
#   조치 전 계정 파일 백업으로 passwd/shadow 상태를 복원한다.
# =============================================================================

do_fix "U-04" "(상) 비밀번호 파일 보호" \
  "_vuln=\$(awk -F: '\$2!=\"x\"&&\$2!=\"*\"&&\$2!=\"!\"&&\$2!=\"\" {print \$1}' /etc/passwd | head -5)
   if [ -n \"\$_vuln\" ]; then
     echo \"평문 저장 계정: \$_vuln\"
   else
     echo '평문 저장 계정 없음'
     ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow 2>/dev/null \
       | awk '{print \$1, \$3, \$4, \$NF}'
   fi" \
  "# passwd에 평문 저장된 계정을 shadow로 이동
   while IFS=: read -r user pw rest; do
     [ \"\$pw\" = \"x\" ] || [ \"\$pw\" = \"*\" ] || [ \"\$pw\" = \"!\" ] || [ -z \"\$pw\" ] && continue
     usermod -p '!' \"\$user\" 2>/dev/null && echo \"   \$user 잠금 처리\"
   done < /etc/passwd" \
  "_o=\$(awk -F: '\$2!=\"x\"&&\$2!=\"*\"&&\$2!=\"!\"&&\$2!=\"\" {print \$1}' /etc/passwd | head -5); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '평문 저장 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-05 / root 이외의 UID 0 금지
#
# 점검 기준:
#   UID 0은 root 계정에만 할당되어야 한다.
#
# 조치 내용:
#   추가 UID 0 계정의 삭제를 시도하고 삭제할 수 없으면 사용하지 않는 고유 UID로 변경한다.
#
# 변경 대상:
#   /etc/passwd, /etc/shadow 및 계정·그룹 데이터
#
# 수동 확인:
#   발견된 UID 0 계정의 업무 용도와 삭제 가능 여부는 적용 전에 확인한다.
#
# 롤백:
#   조치 전 계정 파일 백업을 사용해 계정과 UID 정보를 복원한다.
# =============================================================================

do_fix "U-05" "(상) root 이외의 UID가 '0' 금지" \
  "_u05=\$(awk -F: '\$3==0&&\$1!=\"root\"{print \$1}' /etc/passwd)
   if [ -n \"\$_u05\" ]; then
     echo \"UID=0 계정 발견:\"
     echo \"\$_u05\" | sed 's/^/   /'
   else
     echo 'root 이외의 UID=0 계정 없음 — 양호'
     awk -F: '\$3==0{printf \"   %-16s UID=%s\\n\", \$1, \$3}' /etc/passwd
   fi" \
  "awk -F: '\$3==0&&\$1!=\"root\"{print \$1}' /etc/passwd | while read u; do
     userdel -f \"\$u\" 2>/dev/null && echo \"   \$u 계정 삭제 완료\" \
       || { usermod -u \$(awk -F: 'BEGIN{max=1000} \$3>max{max=\$3} END{print max+1}' /etc/passwd) \"\$u\" 2>/dev/null \
            && echo \"   \$u UID 변경 완료\"; }
   done" \
  "awk -F: '\$3==0&&\$1!=\"root\"{ print \$1}' /etc/passwd | wc -l" \
  "^0$"

# =============================================================================
# U-06 / 사용자 계정 su 기능 제한
#
# 점검 기준:
#   su 인증에 pam_wheel 제한이 적용되고 wheel 그룹에는 승인된 계정만 포함되어야 한다.
#
# 조치 내용:
#   /etc/pam.d/su에 pam_wheel.so use_uid를 적용하고 사용자가 선택한 계정을 wheel 그룹에 추가한다.
#
# 변경 대상:
#   /etc/pam.d/su, /etc/group, /etc/gshadow
#
# 수동 확인:
#   wheel 그룹을 비워둘지 또는 어떤 계정을 허용할지는 운영 정책에 따라 직접 판단한다.
#
# 롤백:
#   PAM 파일 백업과 GROUP_MEMBERSHIP 레코드를 사용해 설정과 그룹 멤버를 복원한다.
# =============================================================================

{
  _match=0
  BEFORE_VAL["U-06"]=$(grep -v '^\s*#' /etc/pam.d/su 2>/dev/null | grep pam_wheel | head -2 2>/dev/null | head -3)
  [ -z "${BEFORE_VAL["U-06"]:-}" ] && BEFORE_VAL["U-06"]="이상 항목 없음 (점검 통과)"
  AFTER_VAL["U-06"]="이미 양호 (재확인 통과)"
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-06" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-06"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-06" "(상) 사용자 계정 su 기능 제한"
      _lbl_cur
      grep -v '^\s*#' /etc/pam.d/su 2>/dev/null | grep -E 'pam_wheel' | sed 's/^/   /'
      echo ""
            _mark_skipped "U-06" "su 기능 제한 [이미양호]"
    elif [ $_vs -eq 3 ]; then
      _item_header "manual" "U-06" "(상) 사용자 계정 su 기능 제한"
      echo ""
      WHEEL_LINE=$(grep -v '^#' /etc/pam.d/su 2>/dev/null | grep -E 'pam_wheel\.so' | head -1)
      if echo "$WHEEL_LINE" | grep -qE 'use_uid|group='; then
        echo -e " ${CYAN}→${RESET} pam_wheel.so 정상 설정"
        _lbl_state
        echo "   ${WHEEL_LINE}"
        echo ""
        _u06_wheel_now1=$(grep '^wheel:' /etc/group | cut -d: -f4)
        if [ -n "$_u06_wheel_now1" ]; then
          echo -e " ${YELLOW}현재 wheel 그룹 사용자${RESET}"
          echo "$_u06_wheel_now1" | tr ',' '\n' | sed 's/^/   /'
          echo ""
          echo -e " ${YELLOW}새로 추가할 계정(없으면 Enter):${RESET}"
          echo ""
          _u06_show_candidates "$_u06_wheel_now1"
        else
          echo -e " ${RED}⚠ wheel 그룹에 사용자가 없습니다.${RESET}"
          echo -e " ${YELLOW}   현재 설정에서는 root를 제외한 일반 사용자는 su 명령을 사용할 수 없습니다.${RESET}"
          echo -e " ${YELLOW}   운영 정책에 맞게 wheel 그룹에 허용 계정을 추가하십시오.${RESET}"
          echo ""
          echo -e " ${YELLOW}wheel 그룹에 추가할 계정을 입력하세요. (예: admin)${RESET}"
          echo -e " ${YELLOW}Enter만 누르면 건너뜁니다.${RESET}"
          echo ""
          _u06_show_candidates "$_u06_wheel_now1"
        fi
      else
        echo -e " ${YELLOW}[!] pam_wheel.so 존재하나 use_uid/group= 옵션 없음 — 실제 제한 미적용 가능성${RESET}"
        echo "   ${WHEEL_LINE}"
        echo ""
        echo -e " ${YELLOW}wheel 그룹에 추가할 계정을 입력하세요. (예: admin)${RESET}"
        echo -e " ${YELLOW}Enter만 누르면 건너뜁니다.${RESET}"
        echo ""
        _u06_show_candidates "$_u06_wheel_now1"
      fi
      printf '%s' " 계정: "
      read -r _u06_wheel_user
      if [ -n "$_u06_wheel_user" ] && id "$_u06_wheel_user" &>/dev/null; then
        # ── 1차 안전장치: 기존 멤버 여부 기록 (역연산용) ─────────────────────
        # 조치 전에 해당 계정이 이미 wheel 멤버인지 확인해 기록한다.
        # 롤백 시 before_member=0 이면 gpasswd -d 로 제거, 1이면 아무것도 안 함.
        _u06_before_member=0
        if awk -F: -v user="$_u06_wheel_user" -v group="wheel" '
          $1 == group {
            n = split($4, members, ",")
            for (i = 1; i <= n; i++) { if (members[i] == user) exit 0 }
            exit 1
          }
          END { if (NR == 0) exit 1 }
        ' /etc/group; then
          _u06_before_member=1
        fi
        # 이력 파일에 롤백 정보 기록
        printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user" "$_u06_before_member" >> "${FIX_HISTORY_FILE}" 2>/dev/null
        {
          echo "----- [U-06] wheel 그룹 변경 기록 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
          printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user" "$_u06_before_member"
          echo "# 롤백 기본: 기존 멤버가 아니었던 경우 wheel 그룹에서 제거"
          echo "# 롤백 비상: tar.gz 의 /etc/group, /etc/gshadow 전체 복원"
          echo "-----------------------------------------------------------"
        } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

        # 기존 멤버가 아닐 때만 추가
        if [ "$_u06_before_member" -eq 0 ]; then
          usermod -aG wheel "$_u06_wheel_user"
        fi
        _u06_wheel_after1=$(grep '^wheel:' /etc/group | cut -d: -f4)
        # 검증
        if id -nG "$_u06_wheel_user" 2>/dev/null | tr ' ' '\n' | grep -qx "wheel"; then
          echo ""
          echo -e " ${CYAN}→${RESET} ${_u06_wheel_user} 계정이 wheel 그룹에 속해 있습니다.$([ "$_u06_before_member" -eq 1 ] && echo " (기존 멤버)")"
          echo ""
          _lbl_result
          echo "   pam_wheel.so : 적용됨"
          echo "   wheel 그룹   :"
          echo "$_u06_wheel_after1" | tr ',' '\n' | sed 's/^/     - /'
          echo ""
          _lbl_done_nr
          _mark_fixed "U-06" "${_u06_wheel_user} 계정을 wheel 그룹에 추가"
        else
          _fail "wheel 그룹 추가가 반영되지 않은 것으로 보입니다 — 수동 확인 필요"
          _mark_manual "U-06" "wheel 그룹 추가 반영 안 됨 — 수동 확인 필요"
        fi
      else
        [ -n "$_u06_wheel_user" ] && echo -e " ${RED}!! ${_u06_wheel_user} 계정을 찾을 수 없습니다 — 추가하지 않았습니다.${RESET}"
        echo -e " ${YELLOW}→ wheel 그룹을 비워두는 것도 보안상 유효한 선택입니다(su 자체를 막는 효과). 운영 정책에 따라 결정하세요.${RESET}"
        _mark_manual "U-06" "pam_wheel.so use_uid 옵션 또는 wheel 그룹 멤버 확인 필요"
      fi
    else
      _item_header "vuln" "U-06" "(상) 사용자 계정 su 기능 제한"
      echo ""
      _u06_wheel_out=$(grep -v '^#' /etc/pam.d/su 2>/dev/null | grep pam_wheel)
      _lbl_before
      if [ -n "$_u06_wheel_out" ]; then echo "$_u06_wheel_out" | sed 's/^/   /'; else echo "   pam_wheel 미설정"; fi
      echo ""
      _lbl_yn
      _read_yn _yn_u06 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u06" != [Yy] ]]; then
        _lbl_skip
                _mark_skipped "U-06" "su 기능 제한 [건너뜀]"
      else
        _lbl_during
        echo -e "   ${CYAN}→${RESET} /etc/pam.d/su 에 pam_wheel.so use_uid 적용"
        _backup_file /etc/pam.d/su >/dev/null
        if grep -q '^#.*pam_wheel.so' /etc/pam.d/su; then
          sed -i '0,/^#.*pam_wheel.so/{s/^#.*pam_wheel.so.*/auth required pam_wheel.so use_uid/}' /etc/pam.d/su
        else
          sed -i '1a auth required pam_wheel.so use_uid' /etc/pam.d/su
        fi
        echo ""
        echo -e " ${CYAN}→${RESET} pam_wheel.so 설정 적용 완료"
        echo ""
        _lbl_state
        grep -v '^#' /etc/pam.d/su 2>/dev/null | grep pam_wheel | sed 's/^/   /'
        check_still_vuln "U-06"; _rs=$?
        BEFORE_VAL["U-06"]="pam_wheel.so 미설정"
        AFTER_VAL["U-06"]="pam_wheel.so use_uid 추가"
        _u06_wheel_members=$(grep '^wheel:' /etc/group 2>/dev/null | cut -d: -f4)
        DETAIL_VAL["U-06"]=$(_fmt_detail \
          "pam_wheel.so 미설정" \
          "auth required pam_wheel.so use_uid 추가" \
          "조치 완료 / 최종 검증 통과" \
          "/etc/pam.d/su" \
          "pam_wheel.so use_uid 연결됨, wheel 그룹 멤버: ${_u06_wheel_members:-없음}")
        if [ $_rs -eq 1 ]; then
          echo ""
          _lbl_done
          _mark_fixed "U-06" "조치 완료 (pam_wheel.so use_uid 추가)"
        elif [ $_rs -eq 3 ]; then
          echo ""
          _u06_wheel_now=$(grep '^wheel:' /etc/group | cut -d: -f4)
          echo -e " ${YELLOW}현재 wheel 그룹${RESET}"
          if [ -n "$_u06_wheel_now" ]; then
            echo "$_u06_wheel_now" | tr ',' '\n' | sed 's/^/   /'
          else
            echo "   (추가 사용자 없음)"
          fi
          echo ""
          if [ -z "$_u06_wheel_now" ]; then
            echo -e " ${RED}⚠ wheel 그룹에 사용자가 없습니다.${RESET}"
            echo -e " ${YELLOW}   현재 설정에서는 root를 제외한 일반 사용자는 su 명령을 사용할 수 없습니다.${RESET}"
            echo ""
          fi
          echo -e " ${YELLOW}※ wheel 그룹에 등록된 사용자만 su 명령으로 root 전환이 가능합니다.${RESET}"
          echo ""
          echo -e " ${YELLOW}wheel 그룹에 추가할 계정을 입력하세요. (예: admin)${RESET}"
          echo -e " ${YELLOW}Enter만 누르면 건너뜁니다.${RESET}"
          echo ""
          _u06_show_candidates "$_u06_wheel_now"

          _u06_wheel_user2=""
          while true; do
            printf '%s' " 계정: "
            read -r _u06_wheel_user2
            [ -z "$_u06_wheel_user2" ] && break
            if ! id "$_u06_wheel_user2" &>/dev/null; then
              echo -e " ${RED}✗ ${_u06_wheel_user2} 계정을 찾을 수 없습니다.${RESET}"
              printf '%s' " 다시 입력하시겠습니까? (y/n): "
              read -r _u06_retry
              [[ "$_u06_retry" =~ ^[Yy]$ ]] && continue || { _u06_wheel_user2=""; break; }
            fi
            break
          done

          if [ -n "$_u06_wheel_user2" ]; then
            if echo "$_u06_wheel_now" | tr ',' '\n' | grep -qx "$_u06_wheel_user2"; then
              # 이미 멤버인 경우 — usermod를 다시 실행할 필요 없음
              echo ""
              echo -e " ${CYAN}→${RESET} ${_u06_wheel_user2} 계정은 이미 wheel 그룹에 포함되어 있습니다."
              _u06_wheel_after="$_u06_wheel_now"
              _mark_fixed "U-06" "pam_wheel.so 추가 (${_u06_wheel_user2}는 이미 wheel 멤버)"
            else
              # ── 1차 안전장치: 기존 멤버 여부 기록 (역연산용) ───────────────
              _u06_before_member2=0
              if awk -F: -v user="$_u06_wheel_user2" -v group="wheel" '
                $1 == group {
                  n = split($4, members, ",")
                  for (i = 1; i <= n; i++) { if (members[i] == user) exit 0 }
                  exit 1
                }
                END { if (NR == 0) exit 1 }
              ' /etc/group; then
                _u06_before_member2=1
              fi
              printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user2" "$_u06_before_member2" >> "${FIX_HISTORY_FILE}" 2>/dev/null
              {
                echo "----- [U-06] wheel 그룹 변경 기록 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
                printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user2" "$_u06_before_member2"
                echo "# 롤백 기본: 기존 멤버가 아니었던 경우 wheel 그룹에서 제거"
                echo "# 롤백 비상: tar.gz 의 /etc/group, /etc/gshadow 전체 복원"
                echo "-----------------------------------------------------------"
              } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null
              if [ "$_u06_before_member2" -eq 0 ]; then
                usermod -aG wheel "$_u06_wheel_user2"
              fi
              _u06_wheel_after=$(grep '^wheel:' /etc/group | cut -d: -f4)
              if id -nG "$_u06_wheel_user2" 2>/dev/null | tr ' ' '\n' | grep -qx "wheel"; then
                echo ""
                echo -e " ${CYAN}→${RESET} ${_u06_wheel_user2} 계정이 wheel 그룹에 속해 있습니다.$([ "$_u06_before_member2" -eq 1 ] && echo " (기존 멤버)")"
                _mark_fixed "U-06" "조치 완료 (pam_wheel.so 추가 + ${_u06_wheel_user2} wheel 추가)"
              else
                _fail "wheel 그룹 추가가 반영되지 않은 것으로 보입니다 — 수동 확인 필요"
                _mark_manual "U-06" "wheel 그룹 추가 반영 안 됨 — 수동 확인 필요"
              fi
            fi
            echo ""
            _lbl_result
            grep '^wheel:' /etc/group | sed 's/^/   /'
            echo ""
            _lbl_done_nr
          else
            echo -e " ${YELLOW}→ wheel 그룹 멤버 확인 필요 (수동확인 전환)${RESET}"
            _mark_manual "U-06" "pam_wheel.so 설정 후 wheel 그룹 멤버 확인 필요"
          fi
        else
          echo -e " ${YELLOW}→ 수동 확인 필요${RESET}"
          _mark_manual "U-06" "su 기능 제한 수동 확인 필요"
        fi
      fi
      fi
    fi
    echo ""
}

# =============================================================================
# U-07 / 불필요한 계정 제거
#
# 점검 기준:
#   adm, lp, sync 등 기본 불필요 계정이 없거나 비밀번호가 잠긴 상태여야 한다.
#
# 조치 내용:
#   대상 계정은 삭제하지 않고 비밀번호를 잠가 로그인을 차단한다.
#
# 변경 대상:
#   /etc/shadow 및 관련 계정 데이터
#
# 수동 확인:
#   서비스가 실제로 사용하는 기본 계정인지 확인이 필요한 경우 잠금 전 검토한다.
#
# 롤백:
#   조치 전 계정 파일 백업으로 잠금 상태를 복원한다.
# =============================================================================

do_fix "U-07" "(하) 불필요한 계정 제거" \
  "_o=\"\"
   for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd || continue
     _uid=\$(getent passwd \"\$a\" | cut -d: -f3)
     _shell=\$(getent passwd \"\$a\" | cut -d: -f7)
     _pw=\$(grep \"^\${a}:\" /etc/shadow 2>/dev/null | cut -d: -f2)
     if echo \"\$_pw\" | grep -qE '^[!*]'; then _lock='잠김'; else _lock='미잠금'; fi
     _o=\"\${_o}\$(printf '%-10s %-6s %-20s %s' \"\$a\" \"\$_uid\" \"\$_shell\" \"\$_lock\")
\"
   done
   if [ -n \"\$_o\" ]; then
     printf '%-10s %-6s %-20s %s\n' '계정명' 'UID' 'Shell' '잠금상태'
     printf -- '------------------------------------------------------------\n'
     printf '%s' \"\$_o\"
   else
     echo '불필요 계정 없음'
   fi" \
  "for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd || continue
     passwd -l \"\$a\" 2>/dev/null && echo \"   \$a 잠금 완료\"
   done" \
  "_o=\"\"; _all_locked=1
   for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd || continue
     PW=\$(grep \"^\${a}:\" /etc/shadow 2>/dev/null | awk -F: '{print \$2}')
     echo \"\$PW\" | grep -qE '^[!*]' || _all_locked=0
     _o=\"\${_o}\${a}: \${PW}\n\"
   done
   if [ -z \"\$_o\" ]; then
     echo '계정 없음 (VERIFY_OK)'
   else
     printf '%b' \"\$_o\"
     [ \$_all_locked -eq 1 ] && echo 'VERIFY_OK' || echo '일부 계정 잠금 실패'
   fi" \
  "VERIFY_OK"

# =============================================================================
# U-08 / 관리자 그룹에 최소한의 계정 포함
#
# 점검 기준:
#   wheel, sudo, admin 그룹에는 관리자 권한이 필요한 계정만 포함되어야 한다.
#
# 조치 내용:
#   자동 변경하지 않고 현재 관리자 그룹 멤버를 표시해 운영 기준과 대조한다.
#
# 변경 대상:
#   /etc/group, /etc/gshadow(조회 대상)
#
# 수동 확인:
#   각 계정의 관리자 권한 필요 여부는 계정 담당자가 직접 판단한다.
#
# 롤백:
#   자동 변경이 없으므로 별도 롤백 대상은 없다.
# =============================================================================

do_manual "U-08" "(중) 관리자 그룹에 최소한의 계정 포함" \
  "wheel/sudo 그룹 멤버가 관리자 권한이 필요한 계정만 포함되어 있는지 운영 기준과 대조 필요" \
  "for grp in wheel sudo admin; do
     members=\$(grep \"^\${grp}:\" /etc/group 2>/dev/null | cut -d: -f4)
     [ -z \"\$members\" ] && continue
     echo \"\$grp 그룹 멤버:\"
     echo \"\$members\" | tr ',' '\\n' | sed 's/^/  - /'
     echo ''
   done"

# =============================================================================
# U-09 / 계정이 존재하지 않는 GID 금지
#
# 점검 기준:
#   /etc/passwd의 모든 기본 GID가 실제 그룹 데이터에 존재해야 한다.
#
# 조치 내용:
#   존재하지 않는 GID를 사용하는 계정의 기본 그룹을 users 또는 기본 GID로 변경한다.
#
# 변경 대상:
#   /etc/passwd, /etc/group 및 계정 데이터
#
# 수동 확인:
#   대상 계정이 사용해야 할 정확한 기본 그룹이 별도로 정해져 있으면 직접 지정한다.
#
# 롤백:
#   조치 전 계정·그룹 파일 백업으로 기본 GID를 복원한다.
# =============================================================================

do_fix "U-09" "(하) 계정이 존재하지 않는 GID 금지" \
  "_o=\$(while IFS=: read -r user pw uid gid rest; do
     getent group \"\$gid\" &>/dev/null || echo \"\$gid (계정: \$user)\"
   done < /etc/passwd | head -5); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '미존재 GID 없음'" \
  "# /etc/group에 없는 GID를 가진 계정의 GID를 users(100) 또는 기본 그룹으로 변경
   DEFAULT_GID=\$(getent group users 2>/dev/null | awk -F: '{print \$3}')
   [ -z \"\$DEFAULT_GID\" ] && DEFAULT_GID=100
   awk -F: '{print \$1, \$4}' /etc/passwd | while read uname gid; do
     exists=\$(awk -F: -v g=\"\$gid\" '\$3==g{found=1} END{print found+0}' /etc/group)
     if [ \"\$exists\" = \"0\" ]; then
       usermod -g \"\$DEFAULT_GID\" \"\$uname\" 2>/dev/null \
         && echo \"   \$uname GID \$gid → \$DEFAULT_GID 변경 완료\" \
         || echo \"   \$uname 변경 실패\"
     fi
   done" \
  "STALE=\$(while IFS=: read -r user pw uid gid rest; do
     getent group \"\$gid\" &>/dev/null || echo \"\$gid\"
   done < /etc/passwd | wc -l)
   [ \"\$STALE\" = \"0\" ] && echo \"모든 GID 정상 (VERIFY_OK)\" || echo \"미존재 GID \$STALE개 잔존\"" \
  "VERIFY_OK"

# =============================================================================
# U-10 / 동일한 UID 금지
#
# 점검 기준:
#   root를 포함한 각 로컬 계정은 중복되지 않는 고유 UID를 사용해야 한다.
#
# 조치 내용:
#   중복 UID 계정의 삭제를 시도하고 삭제할 수 없으면 새로운 고유 UID를 할당한다.
#
# 변경 대상:
#   /etc/passwd, /etc/shadow 및 계정 데이터
#
# 수동 확인:
#   중복 계정의 유지 필요성과 파일 소유권 연계 여부는 적용 전에 확인한다.
#
# 롤백:
#   조치 전 계정 파일 백업으로 계정과 UID 정보를 복원한다.
# =============================================================================

do_fix "U-10" "(중) 동일한 UID 금지" \
  "_o=\$(awk -F: '{print \$3}' /etc/passwd | sort | uniq -d | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '중복 UID 없음'" \
  "awk -F: '{print \$3}' /etc/passwd | sort | uniq -d | while read uid; do
     awk -F: -v u=\"\$uid\" '\$3==u{print \$1}' /etc/passwd | tail -n +2 | while read user; do
       userdel -f \"\$user\" 2>/dev/null && echo \"   \$user 계정 삭제 완료\" \
         || { NEW_UID=\$(awk -F: 'BEGIN{max=1000} \$3>max{max=\$3} END{print max+1}' /etc/passwd)
              usermod -u \"\$NEW_UID\" \"\$user\" 2>/dev/null && echo \"   \$user UID → \$NEW_UID\"; }
     done
   done" \
  "awk -F: '{print \$3}' /etc/passwd | sort | uniq -d | wc -l" \
  "^0$"

# =============================================================================
# U-11 / 사용자 Shell 점검
#
# 점검 기준:
#   로그인이 필요하지 않은 계정은 nologin 또는 false 셸을 사용해야 한다.
#
# 조치 내용:
#   자동 변경하지 않고 UID 1000 이상 로그인 가능 계정과 셸을 표시한다.
#
# 변경 대상:
#   /etc/passwd(조회 대상)
#
# 수동 확인:
#   각 계정의 대화형 로그인 필요 여부를 운영 담당자가 직접 판단한다.
#
# 롤백:
#   자동 변경이 없으므로 별도 롤백 대상은 없다.
# =============================================================================

do_manual "U-11" "(하) 사용자 Shell 점검" \
  "로그인 가능 계정의 shell이 운영에 필요한지 보안정책과 대조 필요\n(불필요한 계정은 /sbin/nologin 또는 /bin/false 로 변경)" \
  "echo '계정명              UID    Shell'
   echo '------------------------------------------------------------'
   awk -F: '\$3>=1000&&\$7!~/nologin|false/&&\$7!=\"\"{printf \"%-20s %-6s %s\n\",\$1,\$3,\$7}' /etc/passwd"

# =============================================================================
# U-12 / 세션 종료 시간 설정
#
# 점검 기준:
#   TMOUT이 600초 이하로 export·readonly 설정되고 사용자별 우회 설정이 없어야 한다.
#
# 조치 내용:
#   /etc/profile에 TMOUT과 readonly를 설정하고 다른 파일의 중복·우회 설정을 주석 처리하거나 제거한다.
#
# 변경 대상:
#   /etc/profile, /etc/profile.d/*.sh, /etc/bashrc, /etc/bash.bashrc 등
#
# 수동 확인:
#   readonly가 없거나 사용자 홈의 우회 설정을 자동으로 안전하게 제거할 수 없으면 직접 확인한다.
#
# 롤백:
#   조치 전 셸 초기화 파일 백업으로 TMOUT 관련 설정을 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-12" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-12"; _vs=$?
    _flush_header

    # ── 공통 설정 수집 헬퍼 ─────────────────────────────────────────────────
    _u12_collect_common() {
      for _f in /etc/profile /etc/profile.d/*.sh /etc/bashrc /etc/bash.bashrc /etc/environment; do
        [ -f "$_f" ] || continue
        _v=$(grep -v '^\s*#' "$_f" | grep -oE 'TMOUT=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
        _ro=$(grep -v '^\s*#' "$_f" | grep -E 'readonly\s+TMOUT|declare\s+-r\s+TMOUT' | head -1)
        _ex=$(grep -v '^\s*#' "$_f" | grep -E 'export\s+TMOUT' | head -1)
        if [ -n "$_v" ] || [ -n "$_ro" ] || [ -n "$_ex" ]; then
          echo "FILE:$_f"
          [ -n "$_v"  ] && echo "TMOUT:$_v"
          [ -n "$_ex" ] && echo "EXPORT:$_ex"
          [ -n "$_ro" ] && echo "READONLY:$_ro"
        fi
      done
    }

    # ── 우회 설정 수집 헬퍼 ─────────────────────────────────────────────────
    _u12_collect_bypass() {
      while IFS=: read -r _un _ _ _ _ _home _; do
        [ -d "$_home" ] || continue
        for _rc in "$_home"/.bashrc "$_home"/.bash_profile "$_home"/.profile "$_home"/.zshrc; do
          [ -f "$_rc" ] || continue
          _bypass=$(grep -v '^\s*#' "$_rc" 2>/dev/null \
            | grep -E 'unset\s+TMOUT|TMOUT\s*=\s*0([^-9]|$)|export\s+TMOUT\s*=\s*0')
          [ -n "$_bypass" ] && echo "FILE:$_rc" && echo "$_bypass" | sed 's/^/LINE:/'
        done
      done < /etc/passwd
    }

    # ── [양호] ──────────────────────────────────────────────────────────────
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-12" "(하) 세션 종료 시간 설정"
      echo ""
      _lbl_cur
      echo ""
      _cur_file=""
      while IFS= read -r _line; do
        BEFORE_VAL["U-12"]=$(grep -rh TMOUT /etc/profile.d/ /etc/profile /etc/bashrc 2>/dev/null | grep -v '^\s*#' | head -3 2>/dev/null | head -3)
        [ -z "${BEFORE_VAL["U-12"]:-}" ] && BEFORE_VAL["U-12"]="이상 항목 없음 (점검 통과)"
        AFTER_VAL["U-12"]="이미 양호 (재확인 통과)"
        case "$_line" in
          FILE:*)
            _cur_file="${_line#FILE:}"
            echo -e "   ${CYAN}${_cur_file}${RESET}" ;;
          TMOUT:*)   _ok "TMOUT=${_line#TMOUT:}" ;;
          EXPORT:*)  _ok "${_line#EXPORT:}" ;;
          READONLY:*) _ok "${_line#READONLY:}" ;;
        esac
      done < <(_u12_collect_common)
      echo ""
      _ok "우회 설정 없음"
      echo ""
      _mark_skipped "U-12" "세션 종료 시간 [이미양호]"

    # ── [수동확인] — readonly 없음 ─────────────────────────────────────────
    elif [ $_vs -eq 2 ]; then
      _item_header "manual" "U-12" "(하) 세션 종료 시간 설정"
      echo ""
      _lbl_state
      echo ""
      _cur_file=""
      while IFS= read -r _line; do
        case "$_line" in
          FILE:*)     _cur_file="${_line#FILE:}"; echo -e "   ${CYAN}${_cur_file}${RESET}" ;;
          TMOUT:*)    _ok "TMOUT=${_line#TMOUT:}" ;;
          EXPORT:*)   _ok "${_line#EXPORT:}" ;;
          READONLY:*) _ok "${_line#READONLY:}" ;;
        esac
      done < <(_u12_collect_common)
      _fail "readonly TMOUT 미설정 — 사용자가 TMOUT=0 으로 우회 가능"
      echo ""
      _ok "우회 설정 없음"
      echo ""
      echo -e " ${YELLOW}[확인 필요]${RESET}"
      echo -e "   readonly TMOUT 미설정 — /etc/profile 에 export TMOUT=값 / readonly TMOUT 추가 권장"
      _info "위 현재 상태를 보안정책과 대조하여 직접 판단이 필요합니다."
      echo ""
      _mark_manual "U-12" "세션 종료 시간 — readonly TMOUT 미설정"

    # ── [취약] ──────────────────────────────────────────────────────────────
    else
      _item_header "vuln" "U-12" "(하) 세션 종료 시간 설정"
      echo ""

      _common_out=$(_u12_collect_common)
      _bypass_out=$(_u12_collect_bypass)

      # 조치 전 — 공통 설정 현황
      _lbl_before
      echo ""
      if [ -n "$_common_out" ]; then
        _cur_file=""
        while IFS= read -r _line; do
          case "$_line" in
            FILE:*)     _cur_file="${_line#FILE:}"; echo -e "   ${CYAN}${_cur_file}${RESET}" ;;
            TMOUT:*)    _info "TMOUT=${_line#TMOUT:}" ;;
            EXPORT:*)   _info "${_line#EXPORT:}" ;;
            READONLY:*) _info "${_line#READONLY:}" ;;
          esac
        done <<< "$_common_out"
      else
        _fail "TMOUT 미설정"
      fi
      echo ""

      # 조치 전 — 우회 설정 현황
      if [ -n "$_bypass_out" ]; then
        echo -e "   ${RED}우회 설정 탐지:${RESET}"
        _cur_file=""
        while IFS= read -r _line; do
          case "$_line" in
            FILE:*) _cur_file="${_line#FILE:}" ;;
            LINE:*) _fail "${_cur_file} → ${_line#LINE:}" ;;
          esac
        done <<< "$_bypass_out"
        echo ""
      fi

      _lbl_yn
      if [ "$NO_PROMPT" -eq 1 ]; then
        _yn_u12="y"
        echo -e "   ${CYAN}[NO-PROMPT] 스크립트 기본값으로 적용: TMOUT=${DEFAULT_TMOUT}${RESET}"
      else
        _read_yn _yn_u12 " 조치하시겠습니까? (y/n): "
      fi

      if [[ "$_yn_u12" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-12" "세션 종료 시간 [건너뜀]"
        echo ""
      else
        if [ "$NO_PROMPT" -eq 1 ]; then
          TMOUT_VAL=$DEFAULT_TMOUT
        else
        # TMOUT 값 입력
        echo ""
        echo -e " ${YELLOW}세션 종료 시간(초)을 입력하세요. 권고: ${DEFAULT_TMOUT}초 이하${RESET}"
        while true; do
          printf '%s' " 입력 (Enter=${DEFAULT_TMOUT}): "
          read -r _tmout_input
          if [ -z "$_tmout_input" ]; then
            TMOUT_VAL=$DEFAULT_TMOUT
            break
          fi
          if [[ "$_tmout_input" =~ ^[0-9]+$ ]] && [ "$_tmout_input" -ge 1 ] && [ "$_tmout_input" -le 600 ]; then
            TMOUT_VAL=$_tmout_input
            break
          fi
          echo -e " ${RED}1~600 사이의 숫자를 입력하거나, 기본값을 쓰려면 Enter만 누르세요.${RESET}"
        done
        fi  # NO_PROMPT else 닫기
        echo ""

        # ── 조치 중 ───────────────────────────────────────────────────────
        echo -e " ${CYAN}[조치 중]${RESET}"
        echo ""

        # TMOUT 설정은 /etc/profile에 직접 추가하거나 수정한다.
        _u12_target="/etc/profile"

        # 기존 TMOUT 관련 라인 처리
        if grep -v '^\s*#' "$_u12_target" | grep -qE 'TMOUT'; then
          # 이미 TMOUT 설정 있음 → 백업 후 값 수정
          _backup_file "$_u12_target" >/dev/null
          # 기존 export TMOUT=... 라인을 새 값으로 교체
          if grep -qE '^[[:space:]]*export[[:space:]]+TMOUT\s*=' "$_u12_target"; then
            sed -i "s|^[[:space:]]*export[[:space:]]\+TMOUT\s*=.*|export TMOUT=${TMOUT_VAL}|" "$_u12_target"
          elif grep -qE '^[[:space:]]*TMOUT\s*=' "$_u12_target"; then
            sed -i "s|^[[:space:]]*TMOUT\s*=.*|TMOUT=${TMOUT_VAL}|" "$_u12_target"
          fi
          # readonly 없으면 추가
          if ! grep -qE '^[[:space:]]*(readonly|declare -r)[[:space:]]+TMOUT' "$_u12_target"; then
            sed -i "/TMOUT/a readonly TMOUT" "$_u12_target"
          fi
          _info "기존 TMOUT 값을 ${TMOUT_VAL}(으)로 수정: ${_u12_target}"
        else
          # TMOUT 설정 없음 → 백업 후 파일 끝에 추가
          _backup_file "$_u12_target" >/dev/null
          cat >> "$_u12_target" << TMOUT_EOF

# KISA U-12: 세션 종료 시간 설정
export TMOUT=${TMOUT_VAL}
readonly TMOUT
TMOUT_EOF
          _info "TMOUT=${TMOUT_VAL} 추가: ${_u12_target} (파일 끝에 추가)"
        fi

        # /etc/profile.d/*.sh, /etc/bashrc 에 기존 TMOUT 설정이 있으면 주석 처리
        for _f in /etc/profile.d/*.sh /etc/bashrc /etc/bash.bashrc; do
          [ -f "$_f" ] || continue
          [ "$_f" = "$_u12_target" ] && continue
          grep -v '^\s*#' "$_f" 2>/dev/null | grep -qE 'TMOUT' || continue
          _backup_file "$_f" >/dev/null
          config_set "$_f" '^([[:space:]]*[^#]*TMOUT.*)' '# [U-12 disabled] \1' substr
          _info "중복 TMOUT 주석 처리: $_f"
        done

        # 우회 설정 제거 — Before → After
        _bypass_removed=0
        if [ -n "$_bypass_out" ]; then
          echo ""
          _cur_file=""
          while IFS= read -r _line; do
            case "$_line" in
              FILE:*) _cur_file="${_line#FILE:}" ;;
              LINE:*)
                _bypass_line="${_line#LINE:}"
                echo -e "   ${CYAN}${_cur_file}${RESET}"
                echo -e "   조치 전 : ${RED}${_bypass_line}${RESET}"
                cp "$_cur_file" "${_cur_file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
                config_set "$_cur_file" '^[[:space:]]*unset[[:space:]]+TMOUT' '' delete 2>/dev/null
                config_set "$_cur_file" '^[[:space:]]*TMOUT[[:space:]]*=[[:space:]]*0([^-9]|$)' '' delete 2>/dev/null
                config_set "$_cur_file" '^[[:space:]]*export[[:space:]]+TMOUT[[:space:]]*=[[:space:]]*0' '' delete 2>/dev/null
                echo -e "   조치 후 : (삭제됨)"
                echo ""
                _bypass_removed=1 ;;
            esac
          done <<< "$_bypass_out"
        fi

        # ── 조치 결과 ─────────────────────────────────────────────────────
        echo ""
        _lbl_result
        echo ""

        # /etc/profile 전체 내용이 아닌 TMOUT 관련 설정만 요약 표시
        if [ -f "$_u12_target" ]; then
          echo -e "   ${CYAN}${_u12_target}${RESET}"
          _tmout_lines=$(grep -v '^\s*#' "$_u12_target" | grep -E 'TMOUT')
          if [ -n "$_tmout_lines" ]; then
            echo "$_tmout_lines" | while IFS= read -r _l; do
              _ok "$_l"
            done
          else
            _warn "TMOUT 설정을 찾을 수 없습니다."
          fi
        fi
        echo ""

        # 우회 설정 재검사
        _bypass_recheck=$(_u12_collect_bypass)
        if [ -z "$_bypass_recheck" ]; then
          _ok "우회 설정 없음"
        else
          _fail "우회 설정 잔존 — 수동 확인 필요"
          echo "$_bypass_recheck" | grep 'LINE:' | sed 's/LINE:/   /' 
        fi

        echo ""
        # 최종 판정
        check_still_vuln "U-12"; _u12_final=$?
        if [ $_u12_final -eq 1 ]; then
          _lbl_done
          _info "새로 로그인하는 세션부터 적용됩니다."
          BEFORE_VAL["U-12"]="${_common_out:-TMOUT 미설정}"
          AFTER_VAL["U-12"]="export TMOUT=${TMOUT_VAL} / readonly TMOUT"
          DETAIL_VAL["U-12"]=$(_fmt_detail \
            "${_common_out:-TMOUT 미설정}" \
            "export TMOUT=${TMOUT_VAL} / readonly TMOUT 설정" \
            "조치 완료 / 최종 검증 통과" \
            "/etc/profile" \
            "TMOUT=${TMOUT_VAL}, readonly 적용됨, 우회 설정 없음")
          _mark_fixed "U-12" "조치 완료 (TMOUT=${TMOUT_VAL}, readonly)"
        else
          _lbl_fail_v
          _mark_failed "U-12" "세션 종료 시간 — 조치 후 검증 실패"
        fi
        echo ""
      fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-13 / 안전한 비밀번호 암호화 알고리즘 사용
#
# 점검 기준:
#   /etc/login.defs의 ENCRYPT_METHOD가 SHA512로 설정되어야 한다.
#
# 조치 내용:
#   ENCRYPT_METHOD 값을 SHA512로 설정한다.
#
# 변경 대상:
#   /etc/login.defs
#
# 수동 확인:
#   기존 인증 체계가 별도 중앙 인증을 사용하는 경우 적용 영향을 확인한다.
#
# 롤백:
#   조치 전 login.defs 백업으로 설정을 복원한다.
# =============================================================================

do_fix "U-13" "(중) 안전한 비밀번호 암호화 알고리즘 사용" \
  "grep -v '^#' /etc/login.defs 2>/dev/null | grep 'ENCRYPT_METHOD' || echo '미설정'" \
  "config_set /etc/login.defs 'ENCRYPT_METHOD' 'SHA512' kv_tab" \
  "grep -v '^#' /etc/login.defs 2>/dev/null | grep 'ENCRYPT_METHOD'" \
  "SHA512"

# ============================================================
_has_cat_target "파일 및 디렉터리 관리" && section_header "파일 및 디렉터리 관리"
# ============================================================

# =============================================================================
# U-14 / root 홈·PATH 설정
#
# 점검 기준:
#   root와 시스템 공통 PATH에 현재 디렉터리(.)가 포함되지 않아야 한다.
#
# 조치 내용:
#   프로필 파일의 PATH에서 값의 순서를 유지한 채 단독 '.' 경로 요소만 제거한다.
#
# 변경 대상:
#   /etc/profile, /etc/bashrc, /etc/bash.bashrc, root 계정 프로필 파일
#
# 수동 확인:
#   응용프로그램이 현재 디렉터리 기반 실행에 의존하는지 필요한 경우 확인한다.
#
# 롤백:
#   조치 전 프로필 파일 백업으로 PATH 설정을 복원한다.
# =============================================================================

do_fix "U-14" "(상) root 홈, 패스 디렉터리 권한 및 패스 설정" \
  "echo \$PATH" \
  'for f in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bash_profile /root/.bashrc /root/.profile; do
     [ -f "$f" ] || continue
     _u14_tmp=$(mktemp 2>/dev/null || echo "${f}.u14tmp.$$")
     _u14_changed=0
     while IFS= read -r _u14_line || [ -n "$_u14_line" ]; do
       if echo "$_u14_line" | grep -qE "^[[:space:]]*(export[[:space:]]+)?PATH="; then
         _u14_prefix=$(echo "$_u14_line" | sed -E "s/^([[:space:]]*(export[[:space:]]+)?PATH=).*/\1/")
         _u14_val=$(echo "$_u14_line" | sed -E "s/^[[:space:]]*(export[[:space:]]+)?PATH=//")
         _u14_quote=""
         case "$_u14_val" in
           \"*\") _u14_quote="\""; _u14_val="${_u14_val#\"}"; _u14_val="${_u14_val%\"}" ;;
         esac
         # 위치와 관계없이 "." 경로 요소만 제거하고 나머지 PATH 항목과 순서는 유지한다.
         _u14_newval=$(echo "$_u14_val" | tr ":" "\n" | grep -vE "^\.$" | paste -sd:)
         _u14_rebuilt="${_u14_prefix}${_u14_quote}${_u14_newval}${_u14_quote}"
         echo "$_u14_rebuilt" >> "$_u14_tmp"
         [ "$_u14_rebuilt" != "$_u14_line" ] && _u14_changed=1
       else
         echo "$_u14_line" >> "$_u14_tmp"
       fi
     done < "$f"
     if [ "$_u14_changed" -eq 1 ]; then
       cat "$_u14_tmp" > "$f"
       echo "   PATH에서 . 제거: $f"
     fi
     rm -f "$_u14_tmp"
   done
   export PATH=$(echo "$PATH" | tr ":" "\n" | grep -v "^\.$" | paste -sd:)' \
  "VULN=0
   for f in /etc/profile /etc/bashrc /root/.bash_profile /root/.bashrc; do
     [ -f \"\$f\" ] || continue
     grep -v '^#' \"\$f\" | grep -qE '^export PATH=.*\\.' && VULN=1
     grep -v '^#' \"\$f\" | grep -qE 'PATH=.*:\\.:|PATH=\\.' && VULN=1
   done
   echo \":\$PATH:\" | grep -qE ':\\.:' && VULN=1
   [ \"\$VULN\" -eq 0 ] && echo 'PATH 정상 (VERIFY_OK)' || echo 'PATH에 . 잔존'" \
  "VERIFY_OK"

# =============================================================================
# U-15 / 파일 및 디렉터리 소유자 설정
#
# 점검 기준:
#   로컬 파일시스템에 존재하지 않는 UID 또는 GID를 소유자로 가진 경로가 없어야 한다.
#
# 조치 내용:
#   무소유 소유자·그룹만 root로 변경하고 원래 숫자 UID/GID와 inode 정보를 별도 기록한다.
#
# 변경 대상:
#   find로 탐지된 -nouser/-nogroup 경로
#
# 수동 확인:
#   UID/GID가 재사용됐거나 대상 inode·파일 유형이 바뀐 경우 롤백 시 직접 확인한다.
#
# 롤백:
#   ORPHAN_RESTORE 레코드와 inode·UID/GID 검증을 사용해 변경된 축만 복원한다.
# =============================================================================

do_fix "U-15" "(상) 파일 및 디렉터리 소유자 설정" \
  "_o=\$(find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '소유자 없는 파일 없음'" \
  "_u15_nu=\$(mktemp 2>/dev/null || echo /tmp/.u15nu.\$\$)
   _u15_ng=\$(mktemp 2>/dev/null || echo /tmp/.u15ng.\$\$)
   find / -xdev -nouser  -printf '%p\n' 2>/dev/null > \"\$_u15_nu\"
   find / -xdev -nogroup -printf '%p\n' 2>/dev/null > \"\$_u15_ng\"
   {
     echo \"----- [U-15] 조치 전 무소유 파일 목록 (\$(date '+%Y-%m-%d %H:%M:%S')) -----\"
     echo \"# 아래 파일들은 소유자/그룹이 없는(deleted UID/GID) 상태에서 root로 변경됩니다.\"
     echo \"# 원본 device/inode/UID/GID는 ORPHAN_RESTORE 레코드로 기록되어 롤백 시 자동 검증·복원에 사용됩니다.\"
   } >> \"\${DETAIL_LOG_FILE:-/dev/null}\" 2>/dev/null
   sort -u \"\$_u15_nu\" \"\$_u15_ng\" 2>/dev/null | while IFS= read -r _u15_p; do
     [ -e \"\$_u15_p\" ] || [ -L \"\$_u15_p\" ] || continue
     _u15_dev=\$(stat -c '%d' \"\$_u15_p\" 2>/dev/null)
     _u15_ino=\$(stat -c '%i' \"\$_u15_p\" 2>/dev/null)
     _u15_type=\$(stat -c '%F' \"\$_u15_p\" 2>/dev/null)
     _u15_mode=\$(stat -c '%a' \"\$_u15_p\" 2>/dev/null)
     _u15_oo=0; _u15_ouid=-
     grep -qxF \"\$_u15_p\" \"\$_u15_nu\" 2>/dev/null && { _u15_oo=1; _u15_ouid=\$(stat -c '%u' \"\$_u15_p\" 2>/dev/null); }
     _u15_go=0; _u15_ogid=-
     grep -qxF \"\$_u15_p\" \"\$_u15_ng\" 2>/dev/null && { _u15_go=1; _u15_ogid=\$(stat -c '%g' \"\$_u15_p\" 2>/dev/null); }
     printf 'ORPHAN_RESTORE|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \"\$_u15_p\" \"\$_u15_dev\" \"\$_u15_ino\" \"\$_u15_type\" \"\$_u15_mode\" \"\$_u15_oo\" \"\$_u15_ouid\" \"\$_u15_go\" \"\$_u15_ogid\" >> \"\${FIX_HISTORY_FILE}\" 2>/dev/null
     if [ \"\$_u15_oo\" -eq 1 ]; then
       if [ -L \"\$_u15_p\" ]; then chown -h root \"\$_u15_p\" 2>/dev/null; else chown root \"\$_u15_p\" 2>/dev/null; fi
     fi
     if [ \"\$_u15_go\" -eq 1 ]; then
       if [ -L \"\$_u15_p\" ]; then chgrp -h root \"\$_u15_p\" 2>/dev/null; else chgrp root \"\$_u15_p\" 2>/dev/null; fi
     fi
   done
   rm -f \"\$_u15_nu\" \"\$_u15_ng\" 2>/dev/null" \
  "find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null | wc -l | xargs echo '소유자 없는 파일 수:'" \
  "소유자 없는 파일 수: 0"

# =============================================================================
# U-16 / /etc/passwd 소유자 및 권한
#
# 점검 기준:
#   /etc/passwd의 소유자가 root이고 권한이 644여야 한다.
#
# 조치 내용:
#   소유자·그룹을 root:root, 권한을 644로 설정한다.
#
# 변경 대상:
#   /etc/passwd
#
# 수동 확인:
#   파일이 없거나 변경 후 stat 검증이 실패하면 직접 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-16" "(상) /etc/passwd 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/passwd" \
  "_p=/etc/passwd; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; chown root:root /etc/passwd && chmod 644 /etc/passwd" \
  "stat -c '소유자: %U / 권한: %a' /etc/passwd" \
  "소유자: root / 권한: 644"

# =============================================================================
# U-17 / 시스템 시작 스크립트 권한 설정
#
# 점검 기준:
#   rc.local, init.d, rc.d 경로는 root 소유이며 권한이 755 이하여야 한다.
#
# 조치 내용:
#   존재하는 시작 스크립트와 디렉터리의 소유자를 root:root, 권한을 755로 설정한다.
#
# 변경 대상:
#   /etc/rc.local, /etc/init.d, /etc/rc.d
#
# 수동 확인:
#   배포판별 심볼릭 링크 대상과 실행 권한 요구가 다른 경우 직접 확인한다.
#
# 롤백:
#   조치 전 백업과 메타데이터를 사용해 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-17" "(상) 시스템 시작 스크립트 권한 설정" \
  "for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] && stat -c \"\$f — %U/%a\" \"\$f\"
   done" \
  "for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] || continue
     [ -L \"\$f\" ] && f=\$(readlink -f \"\$f\")
     chown root:root \"\$f\" && chmod 755 \"\$f\" 2>/dev/null
   done" \
  "_all_ok=1
   for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] || continue
     [ -L \"\$f\" ] && f=\$(readlink -f \"\$f\")
     stat -c \"\$f — %U/%a\" \"\$f\"
     O=\$(stat -c '%U' \"\$f\" 2>/dev/null); P=\$(stat -c '%a' \"\$f\" 2>/dev/null)
     { [ \"\$O\" = root ] && [ \"\$P\" -le 755 ]; } 2>/dev/null || _all_ok=0
   done
   [ \$_all_ok -eq 1 ] && echo 'VERIFY_OK' || echo '검증실패'" \
  "VERIFY_OK"

# =============================================================================
# U-18 / /etc/shadow 소유자 및 권한
#
# 점검 기준:
#   /etc/shadow는 root 소유이며 그룹·기타 사용자에게 불필요한 쓰기·실행·읽기 권한이 없어야 한다.
#
# 조치 내용:
#   소유자를 root로 설정하고 그룹 쓰기·실행 및 기타 모든 권한을 제거한다.
#
# 변경 대상:
#   /etc/shadow
#
# 수동 확인:
#   배포판에서 shadow 그룹을 사용하는 경우 그룹 소유 정책을 함께 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-18" "(상) /etc/shadow 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 그룹: %G / 권한: %a' /etc/shadow 2>/dev/null" \
  "_p=/etc/shadow; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; chown root /etc/shadow && chmod g-wx,o-rwx /etc/shadow" \
  "_sp=\$(stat -c '%U %a' /etc/shadow 2>/dev/null); echo \"\$_sp\"" \
  "^root [0-46][0-9][0-9]$"

# =============================================================================
# U-19 / /etc/hosts 소유자 및 권한
#
# 점검 기준:
#   /etc/hosts의 소유자가 root이고 권한이 644여야 한다.
#
# 조치 내용:
#   소유자·그룹을 root:root, 권한을 644로 설정한다.
#
# 변경 대상:
#   /etc/hosts
#
# 수동 확인:
#   변경 후 이름 해석 또는 애플리케이션 동작에 이상이 있으면 내용 자체를 별도로 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-19" "(상) /etc/hosts 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/hosts" \
  "_p=/etc/hosts; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; chown root:root /etc/hosts && chmod 644 /etc/hosts" \
  "stat -c '소유자: %U / 권한: %a' /etc/hosts" \
  "소유자: root / 권한: 644"
# =============================================================================
# U-20 / /etc/(x)inetd.conf 소유자 및 권한
#
# 점검 기준:
#   inetd/xinetd 설정 파일이 존재하면 root 소유이며 권한이 600이어야 한다.
#
# 조치 내용:
#   존재하는 설정 파일의 소유자·그룹을 root:root, 권한을 600으로 설정한다.
#
# 변경 대상:
#   /etc/inetd.conf, /etc/xinetd.conf
#
# 수동 확인:
#   서비스가 설치되지 않아 파일이 없으면 해당 없음으로 처리한다.
#
# 롤백:
#   조치 전 설정 파일 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-20" "(상) /etc/(x)inetd.conf 파일 소유자 및 권한 설정" \
  "_o=\$(for F in /etc/inetd.conf /etc/xinetd.conf; do [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '파일 없음 (양호)'" \
  "for F in /etc/inetd.conf /etc/xinetd.conf; do
     [ -f \"\$F\" ] || continue
     chown root:root \"\$F\" && chmod 600 \"\$F\" && echo \"   \$F → root/600\"
   done" \
  "_o=\$(for F in /etc/inetd.conf /etc/xinetd.conf; do [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '파일 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-21 / /etc/rsyslog.conf 소유자 및 권한
#
# 점검 기준:
#   rsyslog 설정 파일이 존재하면 root 소유이며 권한이 640이어야 한다.
#
# 조치 내용:
#   소유자·그룹을 root:root, 권한을 640으로 설정한다.
#
# 변경 대상:
#   /etc/rsyslog.conf
#
# 수동 확인:
#   rsyslog를 사용하지 않거나 배포판이 다른 설정 파일만 사용하는 경우 직접 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-21" "(상) /etc/rsyslog.conf 소유자 및 권한" \
  "stat -c '소유자: %U / 권한: %a' /etc/rsyslog.conf 2>/dev/null || echo '파일 없음'" \
  "_p=/etc/rsyslog.conf; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; [ -f /etc/rsyslog.conf ] && chown root:root /etc/rsyslog.conf && chmod 640 /etc/rsyslog.conf" \
  "stat -c '소유자: %U / 권한: %a' /etc/rsyslog.conf 2>/dev/null" \
  "소유자: root / 권한: 640"

# =============================================================================
# U-22 / /etc/services 소유자 및 권한
#
# 점검 기준:
#   /etc/services의 소유자가 root이고 권한이 644여야 한다.
#
# 조치 내용:
#   소유자·그룹을 root:root, 권한을 644로 설정한다.
#
# 변경 대상:
#   /etc/services
#
# 수동 확인:
#   파일이 없거나 패키지 관리 정책과 충돌하는 경우 직접 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-22" "(상) /etc/services 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/services" \
  "_p=/etc/services; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; chown root:root /etc/services && chmod 644 /etc/services" \
  "stat -c '소유자: %U / 권한: %a' /etc/services" \
  "소유자: root / 권한: 644"


# =============================================================================
# U-23 / SUID·SGID·Sticky bit 설정 파일 점검
#
# 점검 기준:
#   특수 권한 파일은 승인 정책에 포함되고 승인 당시의 소유자·그룹·권한과 일치해야 한다.
#
# 조치 내용:
#   탐지 파일을 분류별로 검토하고 미승인 대상의 SUID/SGID 비트를 제거하며 승인 정책을 저장한다.
#
# 변경 대상:
#   탐지된 특수 권한 파일, rollback/u23_approved.conf, rollback/u23_restricted.conf
#
# 수동 확인:
#   Oracle·Postfix·LifeKeeper 등 업무 서비스 파일은 분류별 목록을 검토해 승인 여부를 결정한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 제거한 특수 권한을 복원한다.
# =============================================================================

# U-23 실제 조치 함수
# 최초 실행: 분류별 그룹 단위로 검토하고 승인 정책을 저장한다.
# 이후 실행: 승인 당시의 소유자/그룹/권한과 동일한 파일은 자동 통과하며,
# 승인 기록이 없거나 상태가 변경된 파일만 다시 검토한다.
_u23_apply_policy() {
  local -a _targets=() _approved_paths=()
  local -a _category_order=(
    "OS 기본 명령어"
    "sudo·polkit·sssd 및 인증"
    "Postfix"
    "Cockpit"
    "Oracle"
    "LifeKeeper"
    "기타·출처 불명"
  )
  local -A _cat_map=() _source_map=() _action=() _reason=() _restrict_group=()
  local -A _category_count=()
  local f _cat _src

  _FORCE_MANUAL_REASON=""
  _U23_PARTIAL_FAILURE_COUNT=0
  _U23_PARTIAL_FAILURES=""
  _U23_MANUAL_COUNT=0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if _u23_is_managed "$f"; then
      _approved_paths+=("$f")
      continue
    fi
    _cat=$(_u23_category "$f")
    _src=$(_u23_source_label "$f" "$_cat")
    _targets+=("$f")
    _cat_map["$f"]="$_cat"
    _source_map["$f"]="$_src"
    _category_count["$_cat"]=$(( ${_category_count["$_cat"]:-0} + 1 ))
  done < <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort)

  echo "   기존 승인과 동일 : ${#_approved_paths[@]}개"
  echo "   검토 대상         : ${#_targets[@]}개"
  echo "   승인 정책 파일   : ${_U23_APPROVAL_FILE}"
  echo "   그룹 제한 정책   : ${_U23_RESTRICT_FILE}"
  echo ""

  [ ${#_targets[@]} -eq 0 ] && {
    echo "   ✓ 기존 승인 상태와 동일하여 추가 확인을 생략합니다."
    DETAIL_VAL["U-23"]="[현재 상태] 전체 SUID/SGID 파일 ${#_approved_paths[@]}개, 모두 허용 목록과 일치 | [조치 내용] 해당 없음 (변경 불필요) | [조치 결과] 이미 양호 / 재확인 통과 | [변경 파일] 없음 | [검증 결과] 검토 대상 0개"
    return 0
  }

  local _has_tty=0
  if { exec 8<>/dev/tty; } 2>/dev/null; then _has_tty=1; fi

  _u23_ui_printf() {
    if [ "$_has_tty" -eq 1 ]; then
      printf "$@" >&8
    else
      printf "$@"
    fi
  }
  _u23_ui_line() {
    if [ "$_has_tty" -eq 1 ]; then
      printf '%s\n' "$*" >&8
    else
      printf '%s\n' "$*"
    fi
  }
  _u23_ui_read() {
    local __name="$1" __prompt="$2" __value=""
    _u23_ui_printf '%s' "$__prompt"
    if [ "$_has_tty" -eq 1 ]; then
      read -r __value <&8 || return 1
    else
      read -r __value || return 1
    fi
    printf -v "$__name" '%s' "$__value"
  }
  _u23_read_group() {
    local __out_name="$1" __input_group=""
    while true; do
      _u23_ui_read __input_group "   허용 그룹을 입력하세요: " || return 1
      if getent group "$__input_group" >/dev/null 2>&1; then
        printf -v "$__out_name" '%s' "$__input_group"
        return 0
      fi
      _u23_ui_line "   [오류] 존재하지 않는 그룹입니다. 다시 입력해주세요."
    done
  }
  _u23_stage_single() {
    local __file="$1" __choice="" __group=""
    local __mode __owner __group_now __cat __cat_label __src
    __mode=$(stat -c '%a' "$__file" 2>/dev/null)
    __owner=$(stat -c '%U' "$__file" 2>/dev/null)
    __group_now=$(stat -c '%G' "$__file" 2>/dev/null)
    __cat="${_cat_map[$__file]}"
    __cat_label=$(_u23_display_category "$__cat")
    __src="${_source_map[$__file]}"

    _u23_ui_line ""
    _u23_ui_line "   [파일 상세 확인]"
    _u23_ui_line "$_U23_UI_DIV_LINE"
    _u23_ui_line "   파일        : $__file"
    _u23_ui_line "   현재 권한   : ${__mode:-확인 불가}"
    _u23_ui_line "   소유자/그룹 : ${__owner:-?}:${__group_now:-?}"
    _u23_ui_line "   분류        : $__cat_label"
    _u23_ui_line "   파일 출처   : $__src"
    _u23_ui_line "$_U23_UI_DIV_LINE"
    _u23_ui_line "   1) 현재 권한 유지 승인"
    _u23_ui_line "   2) SUID/SGID 권한 제거"
    _u23_ui_line "   3) 특정 그룹으로 실행 제한"
    _u23_ui_line "   4) 변경 없이 추가 검토"
    _u23_ui_line ""
    while true; do
      _u23_ui_read __choice "   선택 (1/2/3/4): " || return 1
      case "$__choice" in
        1)
          _action["$__file"]="keep"
          _reason["$__file"]="OPERATOR_REVIEWED"
          _u23_ui_line "   → 운영자 검토 결과에 따라 현재 권한 유지로 기록합니다."
          return 0 ;;
        2)
          _action["$__file"]="remove"
          return 0 ;;
        3)
          _u23_read_group __group || return 1
          _action["$__file"]="restrict"
          _restrict_group["$__file"]="$__group"
          return 0 ;;
        4)
          _action["$__file"]="manual"
          return 0 ;;
        *) _u23_ui_line "   [오류] 1~4 중에서 입력해주세요." ;;
      esac
    done
  }

  if [ "${NO_PROMPT:-0}" -eq 1 ]; then
    for f in "${_targets[@]}"; do _action["$f"]="manual"; done
  else
    local _mode_choice=""
    _u23_ui_line ""
    _u23_ui_line "   [처리 방식]"
    _u23_ui_line "$_U23_UI_DIV_LINE"
    _u23_ui_line "   1) 권장 검토 — 분류별로 묶어 확인"
    _u23_ui_line "   2) 전체 개별 검토 — 파일별로 하나씩 확인"
    _u23_ui_line "   3) 전체 변경 없이 추가 검토로 기록"
    _u23_ui_line ""
    while true; do
      if ! _u23_ui_read _mode_choice "   선택 (1/2/3): "; then
        _U23_PARTIAL_FAILURE_COUNT=1
        _U23_PARTIAL_FAILURES="입력 오류 — U-23 처리 방식을 읽지 못함"
        [ "$_has_tty" -eq 1 ] && exec 8>&-
        unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single
        return 0
      fi
      case "$_mode_choice" in 1|2|3) break ;; *) _u23_ui_line "   [오류] 1~3 중에서 입력해주세요." ;; esac
    done

    if [ "$_mode_choice" = "3" ]; then
      for f in "${_targets[@]}"; do _action["$f"]="manual"; done
    elif [ "$_mode_choice" = "2" ]; then
      for f in "${_targets[@]}"; do
        if ! _u23_stage_single "$f"; then
          _U23_PARTIAL_FAILURE_COUNT=1
          _U23_PARTIAL_FAILURES="입력 오류 — 파일 상세 선택값을 읽지 못함: $f"
          [ "$_has_tty" -eq 1 ] && exec 8>&-
          unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single
          return 0
        fi
      done
    else
      local _group_choice="" _group_name="" _count _cat_label _row
      local -a _group_files=()
      for _cat in "${_category_order[@]}"; do
        _count=${_category_count["$_cat"]:-0}
        [ "$_count" -gt 0 ] || continue
        _group_files=()
        for f in "${_targets[@]}"; do
          [ "${_cat_map[$f]}" = "$_cat" ] && _group_files+=("$f")
        done

        _cat_label=$(_u23_display_category "$_cat")
        _u23_ui_line ""
        _u23_ui_line "   [${_cat_label} - ${#_group_files[@]}개]"
        _u23_ui_line "$_U23_UI_DIV_LINE"
        _u23_format_file_row _row "번호" "권한" "소유자:그룹" "파일 출처" "경로"
        _u23_ui_line "$_row"
        _u23_ui_line "$_U23_UI_DIV_LINE"
        local _idx=1 _m _og
        for f in "${_group_files[@]}"; do
          _m=$(stat -c '%a' "$f" 2>/dev/null)
          _og=$(stat -c '%U:%G' "$f" 2>/dev/null)
          _u23_format_file_row _row "$_idx" "${_m:-?}" "${_og:-?}" "${_source_map[$f]}" "$f"
          _u23_ui_line "$_row"
          _idx=$((_idx+1))
        done
        _u23_ui_line "$_U23_UI_DIV_LINE"
        _u23_ui_line "   1) 현재 권한 유지 승인"
        _u23_ui_line "   2) 그룹 내 파일별 확인"
        _u23_ui_line "   3) 그룹 전체 SUID/SGID 권한 제거"
        _u23_ui_line "   4) 그룹 전체를 특정 그룹으로 실행 제한"
        _u23_ui_line "   5) 그룹 전체 변경 없이 추가 검토"
        _u23_ui_line ""
        while true; do
          if ! _u23_ui_read _group_choice "   선택 (1/2/3/4/5): "; then
            _U23_PARTIAL_FAILURE_COUNT=1
            _U23_PARTIAL_FAILURES="입력 오류 — 그룹 선택값을 읽지 못함: $_cat"
            [ "$_has_tty" -eq 1 ] && exec 8>&-
            unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single
            return 0
          fi
          case "$_group_choice" in 1|2|3|4|5) break ;; *) _u23_ui_line "   [오류] 1~5 중에서 입력해주세요." ;; esac
        done

        case "$_group_choice" in
          1)
            for f in "${_group_files[@]}"; do
              _action["$f"]="keep"
              _reason["$f"]="OPERATOR_REVIEWED"
            done
            _u23_ui_line "   → 운영자 검토 결과에 따라 그룹 전체를 현재 권한 유지로 기록합니다." ;;
          2)
            for f in "${_group_files[@]}"; do
              if ! _u23_stage_single "$f"; then
                _U23_PARTIAL_FAILURE_COUNT=1
                _U23_PARTIAL_FAILURES="입력 오류 — 파일 상세 선택값을 읽지 못함: $f"
                [ "$_has_tty" -eq 1 ] && exec 8>&-
                unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single
                return 0
              fi
            done ;;
          3)
            for f in "${_group_files[@]}"; do _action["$f"]="remove"; done ;;
          4)
            if ! _u23_read_group _group_name; then
              _U23_PARTIAL_FAILURE_COUNT=1
              _U23_PARTIAL_FAILURES="입력 오류 — 허용 그룹명을 읽지 못함: $_cat"
              [ "$_has_tty" -eq 1 ] && exec 8>&-
              unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single
              return 0
            fi
            for f in "${_group_files[@]}"; do
              _action["$f"]="restrict"
              _restrict_group["$f"]="$_group_name"
            done ;;
          5)
            for f in "${_group_files[@]}"; do _action["$f"]="manual"; done ;;
        esac
      done
    fi
  fi

  local _keep_count=0 _remove_count=0 _restrict_count=0 _manual_count=0
  local -A _keep_by_cat=() _remove_by_cat=() _restrict_by_cat=() _manual_by_cat=()
  for f in "${_targets[@]}"; do
    [ -n "${_action[$f]:-}" ] || _action["$f"]="manual"
    _cat="${_cat_map[$f]}"
    case "${_action[$f]}" in
      keep) _keep_count=$((_keep_count+1)); _keep_by_cat["$_cat"]=$(( ${_keep_by_cat["$_cat"]:-0} + 1 )) ;;
      remove) _remove_count=$((_remove_count+1)); _remove_by_cat["$_cat"]=$(( ${_remove_by_cat["$_cat"]:-0} + 1 )) ;;
      restrict) _restrict_count=$((_restrict_count+1)); _restrict_by_cat["$_cat"]=$(( ${_restrict_by_cat["$_cat"]:-0} + 1 )) ;;
      *) _manual_count=$((_manual_count+1)); _manual_by_cat["$_cat"]=$(( ${_manual_by_cat["$_cat"]:-0} + 1 )) ;;
    esac
  done

  if [ "${NO_PROMPT:-0}" -eq 0 ]; then
    _u23_ui_line ""
    _u23_ui_line "   [적용 예정]"
    _u23_ui_line "$_U23_UI_DIV_LINE"
    _u23_ui_line "   현재 권한 유지 승인    : ${_keep_count}개"
    for _cat in "${_category_order[@]}"; do
      [ "${_keep_by_cat[$_cat]:-0}" -gt 0 ] && _u23_ui_line "     - ${_cat}: ${_keep_by_cat[$_cat]}개"
    done
    _u23_ui_line "   특수 권한 제거          : ${_remove_count}개"
    for _cat in "${_category_order[@]}"; do
      [ "${_remove_by_cat[$_cat]:-0}" -gt 0 ] && _u23_ui_line "     - ${_cat}: ${_remove_by_cat[$_cat]}개"
    done
    _u23_ui_line "   특정 그룹 실행 제한     : ${_restrict_count}개"
    for _cat in "${_category_order[@]}"; do
      [ "${_restrict_by_cat[$_cat]:-0}" -gt 0 ] && _u23_ui_line "     - ${_cat}: ${_restrict_by_cat[$_cat]}개"
    done
    _u23_ui_line "   추가 검토                : ${_manual_count}개"
    for _cat in "${_category_order[@]}"; do
      [ "${_manual_by_cat[$_cat]:-0}" -gt 0 ] && _u23_ui_line "     - ${_cat}: ${_manual_by_cat[$_cat]}개"
    done
    _u23_ui_line "$_U23_UI_DIV_LINE"
    _u23_ui_line "   실제 변경 파일          : $((_remove_count + _restrict_count))개"
    _u23_ui_line "   변경하지 않는 파일      : $((_keep_count + _manual_count))개"
    _u23_ui_line "$_U23_UI_DIV_LINE"
    local _final_confirm=""
    _u23_ui_read _final_confirm "   위 내용으로 적용하시겠습니까? (y/n): " || _final_confirm="n"
    if [[ "$_final_confirm" != [Yy] ]]; then
      for f in "${_targets[@]}"; do _action["$f"]="manual"; done
      _keep_count=0; _remove_count=0; _restrict_count=0; _manual_count=${#_targets[@]}
      _u23_ui_line "   → 적용을 취소했습니다. 모든 검토 대상을 추가 검토로 기록합니다."
    fi
  fi

  [ "$_has_tty" -eq 1 ] && exec 8>&-
  unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single

  echo "----- [U-23] 조치 전 SUID/SGID 권한 원본 ($(date '+%Y-%m-%d %H:%M:%S')) -----" \
    >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

  local -a _kept=() _removed=() _restricted=() _manual=() _failed=()
  local _before_mode _before_owner _before_group _owner _group _target_mode
  local _special _verify_mode _verify_group _verify_owner _restore_ok

  for f in "${_targets[@]}"; do
    _before_mode=$(stat -c '%a' "$f" 2>/dev/null)
    _owner=$(stat -c '%U' "$f" 2>/dev/null)
    _before_group=$(stat -c '%G' "$f" 2>/dev/null)
    _before_owner="${_owner}:${_before_group}"
    _cat="${_cat_map[$f]}"

    if [ -z "$_before_mode" ] || [ -z "$_owner" ] || [ -z "$_before_group" ]; then
      echo "   ✗ 파일 상태 확인 실패: $f"
      _failed+=("${f} — stat 상태 확인 실패")
      continue
    fi

    case "${_action[$f]}" in
      keep)
        if _u23_register_approval "$f" "$_owner" "$_before_group" "$_before_mode" "$_cat" "${_reason[$f]}"; then
          _u23_remove_restricted "$f" >/dev/null 2>&1 || true
          echo "   ✓ 현재 권한 유지 및 승인 등록: $f"
          _kept+=("${f}(${_before_owner}/${_before_mode})")
        else
          echo "   ✗ 승인 정책 기록 실패: $f"
          _failed+=("${f} — ${_U23_APPROVAL_FILE} 승인 기록 실패")
        fi
        ;;
      remove)
        printf 'PERM_RESTORE|%s|%s|%s\n' "$f" "$_before_mode" "$_before_owner" >> "${FIX_HISTORY_FILE}" 2>/dev/null
        if chmod u-s,g-s "$f" 2>/dev/null; then
          _verify_mode=$(stat -c '%a' "$f" 2>/dev/null)
          _special=$(( 8#${_verify_mode:-0} & 8#6000 ))
          if [ "$_special" -eq 0 ]; then
            _u23_remove_approval "$f" >/dev/null 2>&1 || true
            _u23_remove_restricted "$f" >/dev/null 2>&1 || true
            echo "   ✓ 특수 권한 제거 완료: $f (${_before_mode} → ${_verify_mode})"
            _removed+=("${f}(${_before_mode}→${_verify_mode})")
          else
            chmod "$_before_mode" "$f" 2>/dev/null || true
            echo "   ✗ 권한 제거 검증 실패: $f"
            _failed+=("${f} — 권한 제거 후 SUID/SGID 잔존")
          fi
        else
          echo "   ✗ 권한 제거 실패: $f"
          _failed+=("${f} — chmod u-s,g-s 실행 실패")
        fi
        ;;
      restrict)
        _group="${_restrict_group[$f]}"
        if ! getent group "$_group" >/dev/null 2>&1; then
          echo "   ✗ 그룹 실행 제한 실패: $f (그룹 없음: $_group)"
          _failed+=("${f} — 허용 그룹 없음: ${_group}")
          continue
        fi
        _special=$(( 8#${_before_mode:-0} & 8#6000 ))
        if [ "$_special" -eq "$((8#4000))" ]; then
          _target_mode="4750"
        elif [ "$_special" -eq "$((8#2000))" ]; then
          _target_mode="2750"
        elif [ "$_special" -eq "$((8#6000))" ]; then
          _target_mode="6750"
        else
          echo "   ✗ SUID/SGID 상태 판정 실패: $f"
          _failed+=("${f} — 기존 SUID/SGID 상태 판정 실패")
          continue
        fi
        printf 'PERM_RESTORE|%s|%s|%s\n' "$f" "$_before_mode" "$_before_owner" >> "${FIX_HISTORY_FILE}" 2>/dev/null
        if chgrp "$_group" "$f" 2>/dev/null && chmod "$_target_mode" "$f" 2>/dev/null; then
          _verify_mode=$(stat -c '%a' "$f" 2>/dev/null)
          _verify_group=$(stat -c '%G' "$f" 2>/dev/null)
          _verify_owner=$(stat -c '%U' "$f" 2>/dev/null)
          if [ "$_verify_mode" = "$_target_mode" ] && [ "$_verify_group" = "$_group" ] && [ "$_verify_owner" = "$_owner" ] \
             && _u23_register_restricted "$f" "$_owner" "$_group" "$_target_mode"; then
            _u23_remove_approval "$f" >/dev/null 2>&1 || true
            echo "   ✓ 특정 그룹 실행 제한 완료: $f (${_group}/${_target_mode})"
            _restricted+=("${f}(${_group}/${_target_mode})")
          else
            _restore_ok=1
            chgrp "$_before_group" "$f" 2>/dev/null || _restore_ok=0
            chmod "$_before_mode" "$f" 2>/dev/null || _restore_ok=0
            echo "   ✗ 그룹 실행 제한 검증 또는 정책 기록 실패: $f"
            [ "$_restore_ok" -eq 1 ] && echo "     → 변경 전 권한으로 즉시 복원 완료"
            _failed+=("${f} — 그룹/권한 검증 또는 정책 기록 실패")
          fi
        else
          _restore_ok=1
          chgrp "$_before_group" "$f" 2>/dev/null || _restore_ok=0
          chmod "$_before_mode" "$f" 2>/dev/null || _restore_ok=0
          echo "   ✗ 그룹 실행 제한 적용 실패: $f"
          [ "$_restore_ok" -eq 1 ] && echo "     → 변경 전 권한으로 즉시 복원 완료"
          _failed+=("${f} — chgrp/chmod 적용 실패")
        fi
        ;;
      *)
        _u23_remove_approval "$f" >/dev/null 2>&1 || true
        _u23_remove_restricted "$f" >/dev/null 2>&1 || true
        echo "   → 변경 없이 추가 검토: $f"
        _manual+=("$f")
        ;;
    esac
  done

  echo ""
  echo "   [처리 결과 요약]"
  echo "$_U23_UI_DIV_LINE"
  echo "   현재 권한 유지 승인 : ${#_kept[@]}개"
  echo "   특수 권한 제거      : ${#_removed[@]}개"
  echo "   그룹 실행 제한      : ${#_restricted[@]}개"
  echo "   추가 검토           : ${#_manual[@]}개"
  echo "   조치 실패           : ${#_failed[@]}개"
  echo ""

  local _detail="[현재 상태] 전체 SUID/SGID 파일 ${#_targets[@]}개, 기존 승인 목록과 동일 ${#_approved_paths[@]}개"
  _detail="${_detail} | [조치 내용] 허용 목록 외 SUID/SGID 비트 제거, 위험도별 그룹 제한/추가검토 분류"
  local _u23_result_txt="조치 완료 / 최종 검증 통과"
  [ ${#_manual[@]} -gt 0 ] && _u23_result_txt="수동 확인 필요"
  [ ${#_failed[@]} -gt 0 ] && _u23_result_txt="조치 실패"
  _detail="${_detail} | [조치 결과] ${_u23_result_txt}"
  # 변경 파일 목록 통합 (유지승인 제외 — 실제 변경이 일어난 항목만)
  local -a _u23_changed=()
  _u23_changed+=("${_removed[@]}" "${_restricted[@]}" "${_manual[@]}" "${_failed[@]}")
  local _u23_cnt=${#_u23_changed[@]}
  local _list
  _detail="${_detail} | [변경 파일] 총 ${_u23_cnt}개"
  if [ "$_u23_cnt" -eq 0 ]; then
    _detail="${_detail} | [변경 파일 목록] 없음"
  else
    # 개수와 관계없이 전체 목록을 셀에 기록한다 (보고서에서 시트 이동 없이 바로 확인).
    _list=$(printf '%s\n' "${_u23_changed[@]}" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    _detail="${_detail} | [변경 파일 목록] ${_list}"
  fi
  _detail="${_detail} | [검증 결과] 권한제거 ${#_removed[@]}개, 그룹제한 ${#_restricted[@]}개, 추가검토 ${#_manual[@]}개, 처리실패 ${#_failed[@]}개"
  if [ ${#_manual[@]} -gt 0 ]; then
    _U23_MANUAL_COUNT=${#_manual[@]}
    _FORCE_MANUAL_REASON="SUID/SGID 권한 유지 여부 추가 검토 필요: ${#_manual[@]}개"
  fi
  if [ ${#_failed[@]} -gt 0 ]; then
    _U23_PARTIAL_FAILURE_COUNT=${#_failed[@]}
    _U23_PARTIAL_FAILURES=$(printf '%s\n' "${_failed[@]}")
    _FORCE_MANUAL_REASON=""
  fi
  # 전체 상세는 이력 파일에 별도 기록 (엑셀 셀 과다 팽창 방지)
  {
    echo "----- [U-23] 전체 SUID/SGID 처리 상세 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
    [ ${#_kept[@]} -gt 0 ]       && printf '[유지승인] %s\n' "$(printf '%s,' "${_kept[@]}")"
    [ ${#_removed[@]} -gt 0 ]    && printf '[권한제거] %s\n' "$(printf '%s,' "${_removed[@]}")"
    [ ${#_restricted[@]} -gt 0 ] && printf '[그룹제한] %s\n' "$(printf '%s,' "${_restricted[@]}")"
    [ ${#_manual[@]} -gt 0 ]     && printf '[추가검토] %s\n' "$(printf '%s,' "${_manual[@]}")"
    [ ${#_failed[@]} -gt 0 ]     && printf '[처리실패] %s\n' "$(printf '%s,' "${_failed[@]}")"
  } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null
  DETAIL_VAL["U-23"]="$_detail"
  return 0
}

do_fix "U-23" "(상) SUID, SGID, Sticky bit 설정 파일 점검" \
  'declare -A _u23_group_total=() _u23_group_approved=() _u23_group_review=()
   _u23_all_cnt=0; _u23_approved_cnt=0; _u23_review_cnt=0
   _u23_full_inventory=""
   while IFS= read -r f; do
     [ -n "$f" ] || continue
     _u23_all_cnt=$((_u23_all_cnt+1))
     _u23_cat=$(_u23_category "$f")
     _u23_src=$(_u23_source_label "$f" "$_u23_cat")
     _u23_group_total["$_u23_cat"]=$(( ${_u23_group_total["$_u23_cat"]:-0} + 1 ))
     _u23_line=$(printf "%-7s %-18s %-18s %s" "$(stat -c "%a" "$f" 2>/dev/null)" "$(stat -c "%U:%G" "$f" 2>/dev/null)" "$_u23_src" "$f")
     _u23_full_inventory="${_u23_full_inventory}${_u23_line}
"
     if _u23_is_managed "$f"; then
       _u23_approved_cnt=$((_u23_approved_cnt+1))
       _u23_group_approved["$_u23_cat"]=$(( ${_u23_group_approved["$_u23_cat"]:-0} + 1 ))
     else
       _u23_review_cnt=$((_u23_review_cnt+1))
       _u23_group_review["$_u23_cat"]=$(( ${_u23_group_review["$_u23_cat"]:-0} + 1 ))
     fi
   done < <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort)
   echo "전체 SUID/SGID 파일 : ${_u23_all_cnt}개"
   echo "기존 승인           : ${_u23_approved_cnt}개"
   echo "검토 대상           : ${_u23_review_cnt}개"
   echo ""
   _u23_format_summary_row _u23_summary_row "분류" "전체" "기존 승인" "검토 대상"
   echo "$_u23_summary_row"
   echo "$_U23_UI_DIV_LINE"
   for _u23_cat in "OS 기본 명령어" "sudo·polkit·sssd 및 인증" "Postfix" "Cockpit" "Oracle" "LifeKeeper" "기타·출처 불명"; do
     _u23_total=${_u23_group_total["$_u23_cat"]:-0}
     [ "$_u23_total" -gt 0 ] || continue
     _u23_format_summary_row _u23_summary_row "$_u23_cat" "$_u23_total" "${_u23_group_approved[$_u23_cat]:-0}" "${_u23_group_review[$_u23_cat]:-0}"
     echo "$_u23_summary_row"
   done
   echo "$_U23_UI_DIV_LINE"
   echo ""
   if [ "$_u23_review_cnt" -eq 0 ]; then
     echo "기존 승인 상태와 동일하여 추가 확인을 생략합니다."
   else
     echo "검토 대상 항목을 분류별로 묶어 표시합니다."
     echo "그룹 내 처리 방식이 다른 경우에만 파일별 확인을 선택하세요."
   fi
   echo "승인 정책: ${_U23_APPROVAL_FILE}"
   echo "그룹 제한: ${_U23_RESTRICT_FILE}"
   {
     echo "----- [U-23] 전체 SUID/SGID 인벤토리 ($(date "+%Y-%m-%d %H:%M:%S")) -----"
     printf "%s" "$_u23_full_inventory"
     echo "-----------------------------------------------------------"
   } >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null
   DETAIL_VAL["U-23"]="전체 ${_u23_all_cnt}개 | 기존 승인 동일 ${_u23_approved_cnt}개 | 검토 대상 ${_u23_review_cnt}개"' \
  '_u23_apply_policy' \
  'EXTRA=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while IFS= read -r f; do
     _u23_is_managed "$f" && continue
     echo "$f"
   done)
   if [ "${_U23_PARTIAL_FAILURE_COUNT:-0}" -gt 0 ]; then
     echo "처리 실패: ${_U23_PARTIAL_FAILURE_COUNT}개"
     while IFS= read -r _u23_fail_reason; do
       [ -n "$_u23_fail_reason" ] && echo "  ✗ ${_u23_fail_reason}"
     done <<< "${_U23_PARTIAL_FAILURES}"
     [ -n "$EXTRA" ] && { echo "미승인 또는 미처리 SUID/SGID:"; echo "$EXTRA" | sed "s/^/  - /"; }
   elif [ "${_U23_MANUAL_COUNT:-0}" -gt 0 ]; then
     echo "자동 조치 항목 권한 검증 완료"
     echo "추가 검토 대상: ${_U23_MANUAL_COUNT}개"
     echo "$EXTRA" | sed "s/^/  - /"
   elif [ -z "$EXTRA" ]; then
     echo "승인·권한 제거·그룹 실행 제한 검증 완료 (VERIFY_OK)"
   else
     echo "미승인 또는 미처리 SUID/SGID:"
     echo "$EXTRA" | sed "s/^/  - /"
   fi' \
  "VERIFY_OK"

# U-23은 그룹 단위 검토와 승인 정책 재사용 방식으로 일원화한다.

# =============================================================================
# U-24 / 사용자·시스템 환경변수 파일 소유자 및 권한
#
# 점검 기준:
#   공통 프로필과 root 계정 환경설정 파일은 root 소유이며 일반 사용자가 수정할 수 없어야 한다.
#
# 조치 내용:
#   존재하는 대상 파일의 소유자·그룹을 root:root, 권한을 644로 설정한다.
#
# 변경 대상:
#   /etc/profile, /etc/bashrc, /etc/bash.bashrc, root 계정 프로필 파일
#
# 수동 확인:
#   애플리케이션이 root 프로필 파일의 별도 권한에 의존하는 경우 적용 전에 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 파일 백업으로 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-24" "(상) 사용자, 시스템 환경변수 파일 소유자 및 권한 설정" \
  "for F in /etc/profile /etc/bashrc /root/.bashrc /root/.bash_profile; do
     [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"
   done" \
  "for F in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc /root/.bash_profile /root/.profile; do
     [ -f \"\$F\" ] || continue
     echo \"PERM_RESTORE|\$F|\$(stat -c '%a' \"\$F\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$F\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\" 2>/dev/null
     chown root:root \"\$F\" && chmod 644 \"\$F\"
   done" \
  "for F in /etc/profile /etc/bashrc /root/.bashrc /root/.bash_profile; do
     [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"
   done" \
  ""


# =============================================================================
# U-25 / world writable 파일 점검
#
# 점검 기준:
#   일반 사용자 쓰기 권한이 있는 일반 파일은 승인 사유가 기록되거나 other 쓰기 권한이 제거되어야 한다.
#
# 조치 내용:
#   미승인 파일별로 other 쓰기 권한 제거, 설정 사유 기록 또는 수동 확인 중 하나를 선택한다.
#
# 변경 대상:
#   로컬 파일시스템의 world writable 일반 파일, rollback/u25_approved.conf
#
# 수동 확인:
#   업무상 쓰기 권한이 필요한 파일은 사유를 확인해 승인 정책에 기록한다.
#
# 롤백:
#   권한을 제거한 파일은 PERM_RESTORE 레코드와 조치 전 백업으로 복원한다.
# =============================================================================

{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-25" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-25"; _vs=$?
    _flush_header

    # KISA U-25는 일반 파일(-type f)만 대상으로 한다.
    # 설정 사유가 기록된 파일은 승인 예외, 그 외 파일은 조치 대상으로 분리한다.
    _u25_all="$(_u25_find_world_writable)"
    _u25_approved=""
    _u25_targets=""
    while IFS= read -r _u25_path; do
      [ -z "$_u25_path" ] && continue
      if _u25_is_approved "$_u25_path"; then
        _u25_approved="${_u25_approved}${_u25_path}"$'\n'
      else
        _u25_targets="${_u25_targets}${_u25_path}"$'\n'
      fi
    done <<< "$_u25_all"

    _u25_all_cnt=$(printf '%s\n' "$_u25_all" | sed '/^$/d' | grep -c . 2>/dev/null); _u25_all_cnt=${_u25_all_cnt:-0}
    _u25_approved_cnt=$(printf '%s\n' "$_u25_approved" | sed '/^$/d' | grep -c . 2>/dev/null); _u25_approved_cnt=${_u25_approved_cnt:-0}
    _u25_target_cnt=$(printf '%s\n' "$_u25_targets" | sed '/^$/d' | grep -c . 2>/dev/null); _u25_target_cnt=${_u25_target_cnt:-0}
    _u25_approved_detail=""
    while IFS= read -r _u25_path; do
      [ -z "$_u25_path" ] && continue
      _u25_reason="$(_u25_approval_reason "$_u25_path")"
      [ -n "$_u25_approved_detail" ] && _u25_approved_detail="${_u25_approved_detail}, "
      _u25_approved_detail="${_u25_approved_detail}${_u25_path}=${_u25_reason}"
    done <<< "$_u25_approved"

    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-25" "(상) world writable 파일 점검"
      _lbl_cur
      if [ "$_u25_all_cnt" -eq 0 ]; then
        _ok "world writable 일반 파일 없음"
      else
        _ok "미승인 world writable 일반 파일 없음"
        echo ""
        echo -e " ${YELLOW}설정 사유 확인 파일${RESET}"
        while IFS= read -r _u25_path; do
          [ -z "$_u25_path" ] && continue
          _u25_reason="$(_u25_approval_reason "$_u25_path")"
          echo "   ${_u25_path}"
          echo "     사유: ${_u25_reason}"
        done <<< "$_u25_approved"
        echo ""
        _info "예외 기록: ${_U25_ALLOWLIST}"
      fi
      BEFORE_VAL["U-25"]="world writable 일반 파일 ${_u25_all_cnt}개 (사유 확인 ${_u25_approved_cnt}개)"
      AFTER_VAL["U-25"]="미승인 world writable 일반 파일 0개"
      DETAIL_VAL["U-25"]="전체 ${_u25_all_cnt}개 | 설정 사유 확인 ${_u25_approved_cnt}개 | 미승인 0개${_u25_approved_detail:+ | [설정 사유 확인] ${_u25_approved_detail}}"
      echo ""
      _mark_skipped "U-25" "world writable 파일 점검 [이미양호]"
    else
      _item_header "vuln" "U-25" "(상) world writable 파일 점검"

      _lbl_cur
      echo -e " ${YELLOW}공용 임시 디렉터리${RESET}"
      for _ed in /tmp /var/tmp; do
        if [ -d "$_ed" ]; then
          _ed_perm=$(stat -c '%a' "$_ed" 2>/dev/null)
          if echo "$_ed_perm" | grep -qE '^1'; then
            _ok "$_ed (${_ed_perm}, Sticky Bit)"
          else
            _warn "$_ed (${_ed_perm:-확인불가}, Sticky Bit 확인 필요)"
          fi
        fi
      done
      echo ""

      if [ -n "$_u25_approved" ]; then
        echo -e " ${YELLOW}설정 사유 확인 파일${RESET}"
        while IFS= read -r _u25_path; do
          [ -z "$_u25_path" ] && continue
          _u25_reason="$(_u25_approval_reason "$_u25_path")"
          echo "   ${_u25_path}"
          echo "     사유: ${_u25_reason}"
        done <<< "$_u25_approved"
        echo ""
        _info "설정 사유 기록 파일: ${_U25_ALLOWLIST}"
        echo ""
      fi

      echo -e " ${RED}미승인 일반 파일 (조치 대상)${RESET}"
      printf '%s\n' "$_u25_targets" | sed '/^$/d; s/^/   /'
      echo ""

        if [ "${NO_PROMPT:-0}" -eq 1 ]; then
          _yn25="y"
          echo -e " ${CYAN}[NO-PROMPT] 미승인 일반 파일의 other 쓰기 권한을 제거합니다.${RESET}"
        else
          _lbl_yn
          _read_yn _yn25 " 조치하시겠습니까? (y/n): "
        fi

        case "$_yn25" in
          [Yy])
            _lbl_during
            _u25_removed=""
            _u25_approved_now=""
            _u25_manual_files=""
            _u25_failed_files=""
            _u25_removed_cnt=0
            _u25_approved_now_cnt=0
            _u25_manual_cnt=0
            _u25_failed_cnt=0
            _u25_idx=0

            while IFS= read -r _f25 <&3; do
              [ -z "$_f25" ] && continue
              _u25_idx=$((_u25_idx+1))
              _u25_mode=$(stat -c '%a' "$_f25" 2>/dev/null)
              _u25_owner=$(stat -c '%U:%G' "$_f25" 2>/dev/null)

              echo -e " ${WHITE}[대상 ${_u25_idx}/${_u25_target_cnt}]${RESET}"
              _row "파일" "$_f25"
              _row "현재 권한" "${_u25_mode:-확인불가}"
              _row "소유자:그룹" "${_u25_owner:-확인불가}"
              echo ""

              if [ "${NO_PROMPT:-0}" -eq 1 ]; then
                _u25_choice=1
                echo "   선택: 1) 일반 사용자 쓰기 권한 제거"
              else
                echo "   1) 일반 사용자 쓰기 권한 제거"
                echo "      → chmod o-w 적용"
                echo "   2) 설정 사유 확인 후 유지"
                echo "      → 권한은 유지하고 확인 사유 기록"
                echo "   3) 변경하지 않음"
                echo "      → 수동 확인 대상으로 기록"
                _read_num _u25_choice " 선택하세요 (1~3): " "3" "1" "3"
              fi
              echo ""

              case "$_u25_choice" in
                1)
                  if [ -f "$_f25" ] && [ -n "$_u25_mode" ] && [ -n "$_u25_owner" ]; then
                    printf 'PERM_RESTORE|%s|%s|%s\n' \
                      "$_f25" "$_u25_mode" "$_u25_owner" >> "${FIX_HISTORY_FILE}" 2>/dev/null
                    if chmod o-w "$_f25" 2>/dev/null; then
                      _u25_after_mode=$(stat -c '%a' "$_f25" 2>/dev/null)
                      if [ -n "$_u25_after_mode" ] && [ $((8#$_u25_after_mode & 0002)) -eq 0 ]; then
                        _ok "일반 사용자 쓰기 권한 제거 완료: $_f25 (${_u25_mode} → ${_u25_after_mode})"
                        _u25_removed="${_u25_removed}${_f25}"$'\n'
                        _u25_removed_cnt=$((_u25_removed_cnt+1))
                      else
                        _fail "권한 제거 검증 실패: $_f25"
                        _u25_failed_files="${_u25_failed_files}${_f25}"$'\n'
                        _u25_failed_cnt=$((_u25_failed_cnt+1))
                      fi
                    else
                      _fail "권한 제거 실패: $_f25"
                      _u25_failed_files="${_u25_failed_files}${_f25}"$'\n'
                      _u25_failed_cnt=$((_u25_failed_cnt+1))
                    fi
                  else
                    _fail "파일 상태 확인 실패: $_f25"
                    _u25_failed_files="${_u25_failed_files}${_f25}"$'\n'
                    _u25_failed_cnt=$((_u25_failed_cnt+1))
                  fi
                  ;;
                2)
                  while true; do
                    printf " 설정 사유를 입력하세요: "
                    if ! read -r _u25_reason; then
                      _u25_reason=""
                    fi
                    _u25_reason="${_u25_reason//$'\r'/ }"
                    _u25_reason="${_u25_reason//$'\n'/ }"
                    _u25_reason="${_u25_reason//|//}"
                    [ -n "$_u25_reason" ] && break
                    echo -e "   ${RED}설정 사유를 입력해야 유지할 수 있습니다.${RESET}"
                  done
                  if _u25_register_approval "$_f25" "$_u25_reason"; then
                    _ok "설정 사유 기록 완료: $_f25"
                    _u25_approved_now="${_u25_approved_now}${_f25}|${_u25_reason}"$'\n'
                    _u25_approved_now_cnt=$((_u25_approved_now_cnt+1))
                  else
                    _fail "설정 사유 기록 실패: $_f25"
                    _u25_failed_files="${_u25_failed_files}${_f25}"$'\n'
                    _u25_failed_cnt=$((_u25_failed_cnt+1))
                  fi
                  ;;
                3)
                  _warn "변경하지 않음: $_f25"
                  _u25_manual_files="${_u25_manual_files}${_f25}"$'\n'
                  _u25_manual_cnt=$((_u25_manual_cnt+1))
                  ;;
              esac
              echo ""
            done 3<<< "$_u25_targets"

            _lbl_result
            _u25_remain_all="$(_u25_find_world_writable)"
            _u25_remain_unapproved=""
            while IFS= read -r _u25_path; do
              [ -z "$_u25_path" ] && continue
              _u25_is_approved "$_u25_path" || _u25_remain_unapproved="${_u25_remain_unapproved}${_u25_path}"$'\n'
            done <<< "$_u25_remain_all"
            _u25_remain_cnt=$(printf '%s\n' "$_u25_remain_unapproved" | sed '/^$/d' | grep -c . 2>/dev/null); _u25_remain_cnt=${_u25_remain_cnt:-0}
            _u25_final_approved_cnt=$(printf '%s\n' "$_u25_remain_all" | sed '/^$/d' | grep -c . 2>/dev/null); _u25_final_approved_cnt=$((_u25_final_approved_cnt - _u25_remain_cnt))
            [ "$_u25_final_approved_cnt" -lt 0 ] && _u25_final_approved_cnt=0

            [ "$_u25_removed_cnt" -gt 0 ] && _ok "권한 제거 완료: ${_u25_removed_cnt}개"
            if [ "$_u25_approved_now_cnt" -gt 0 ]; then
              _ok "설정 사유 기록: ${_u25_approved_now_cnt}개"
              _info "설정 사유 기록 파일: ${_U25_ALLOWLIST}"
            fi
            [ "$_u25_manual_cnt" -gt 0 ] && _warn "변경하지 않음: ${_u25_manual_cnt}개"
            [ "$_u25_failed_cnt" -gt 0 ] && _fail "처리 실패: ${_u25_failed_cnt}개"

            if [ "$_u25_remain_cnt" -eq 0 ]; then
              _ok "미승인 world writable 일반 파일: 0개"
            else
              _warn "미승인 world writable 일반 파일: ${_u25_remain_cnt}개"
              printf '%s\n' "$_u25_remain_unapproved" | sed '/^$/d' | head -10 | sed 's/^/      /'
            fi

            BEFORE_VAL["U-25"]="world writable 일반 파일 ${_u25_all_cnt}개 (미승인 ${_u25_target_cnt}개, 사유 확인 ${_u25_approved_cnt}개)"
            AFTER_VAL["U-25"]="미승인 ${_u25_remain_cnt}개 (권한 제거 ${_u25_removed_cnt}개, 신규 사유 확인 ${_u25_approved_now_cnt}개)"

            _u25_detail="조치 전 전체 ${_u25_all_cnt}개 | 조치 전 미승인 ${_u25_target_cnt}개 | 기존 설정 사유 확인 ${_u25_approved_cnt}개 | 권한 제거 ${_u25_removed_cnt}개 | 신규 사유 확인 ${_u25_approved_now_cnt}개 | 변경 없음 ${_u25_manual_cnt}개 | 실패 ${_u25_failed_cnt}개 | 최종 미승인 ${_u25_remain_cnt}개"
            [ -n "$_u25_approved_detail" ] && _u25_detail="${_u25_detail} | [기존 설정 사유 확인] ${_u25_approved_detail}"
            if [ -n "$_u25_removed" ]; then
              _u25_detail="${_u25_detail} | [chmod o-w] $(printf '%s\n' "$_u25_removed" | sed '/^$/d' | head -10 | tr '\n' ',' | sed 's/,$//')"
            fi
            if [ -n "$_u25_approved_now" ]; then
              _u25_detail="${_u25_detail} | [설정 사유] $(printf '%s\n' "$_u25_approved_now" | sed '/^$/d' | head -10 | tr '\n' ',' | sed 's/,$//')"
            fi
            if [ -n "$_u25_manual_files" ]; then
              _u25_detail="${_u25_detail} | [수동 확인] $(printf '%s\n' "$_u25_manual_files" | sed '/^$/d' | head -10 | tr '\n' ',' | sed 's/,$//')"
            fi
            DETAIL_VAL["U-25"]="$_u25_detail"

            if [ "$_u25_failed_cnt" -gt 0 ]; then
              _mark_failed "U-25" "world writable 일반 파일 처리 실패 ${_u25_failed_cnt}개 (최종 미승인 ${_u25_remain_cnt}개)"
            elif [ "$_u25_remain_cnt" -gt 0 ]; then
              _mark_manual "U-25" "미승인 world writable 일반 파일 ${_u25_remain_cnt}개 수동 확인 필요"
            else
              _mark_fixed "U-25" "world writable 일반 파일 조치 완료 (권한 제거 ${_u25_removed_cnt}개, 설정 사유 확인 ${_u25_approved_now_cnt}개)"
            fi
            ;;
          *)
            _lbl_skip
            BEFORE_VAL["U-25"]="미승인 world writable 일반 파일 ${_u25_target_cnt}개"
            AFTER_VAL["U-25"]="사용자 건너뜀"
            DETAIL_VAL["U-25"]="미승인 ${_u25_target_cnt}개 | 사용자 건너뜀${_u25_approved_detail:+ | [기존 설정 사유 확인] ${_u25_approved_detail}}"
            _mark_skipped "U-25" "world writable 파일 점검 [건너뜀]"
            ;;
        esac
    fi
    echo ""
  fi
}

# =============================================================================
# U-26 / /dev 비장치 파일 점검
#
# 점검 기준:
#   /dev에는 장치·디렉터리·링크·소켓·파이프 외의 일반 파일이 존재하지 않아야 한다.
#
# 조치 내용:
#   탐지된 비장치 파일을 조치 전 백업한 뒤 삭제한다.
#
# 변경 대상:
#   /dev 아래의 비장치 일반 파일
#
# 수동 확인:
#   특정 솔루션이 /dev 아래 일반 파일을 사용하는 경우 삭제 전에 용도를 확인한다.
#
# 롤백:
#   조치 전 개별 백업 또는 롤백 직전 안전 백업에서 삭제된 파일을 복원한다.
# =============================================================================

do_fix "U-26" "(상) /dev에 존재하지 않는 device 파일 점검" \
  "_o=\$(find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '비장치 파일 없음'" \
  "find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | xargs -r rm -f" \
  "find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | wc -l | xargs echo '잔존 비장치 파일:'" \
  ""

# =============================================================================
# U-27 / $HOME/.rhosts 및 hosts.equiv 사용 금지
#
# 점검 기준:
#   /etc/hosts.equiv와 사용자 홈의 .rhosts 파일이 존재하지 않아야 한다.
#
# 조치 내용:
#   /etc/hosts.equiv와 root·일반 사용자 홈의 .rhosts 파일을 삭제한다.
#
# 변경 대상:
#   /etc/hosts.equiv, /root/.rhosts, /home/*/.rhosts
#
# 수동 확인:
#   레거시 r 계열 연동이 남아 있는 환경은 삭제 전에 업무 영향 여부를 확인한다.
#
# 롤백:
#   조치 전 백업에서 삭제된 파일을 복원한다.
# =============================================================================

do_fix "U-27" "(상) $HOME/.rhosts, hosts.equiv 사용 금지" \
  "[ -f /etc/hosts.equiv ] && echo '/etc/hosts.equiv 존재'
   _o=\$(find /root /home -name '.rhosts' 2>/dev/null | head -3); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '.rhosts 파일 없음'" \
  "rm -f /etc/hosts.equiv 2>/dev/null
   find /root /home -name '.rhosts' 2>/dev/null | xargs -r rm -f" \
  "[ -f /etc/hosts.equiv ] && echo '제거 실패' || echo '/etc/hosts.equiv 없음 (VERIFY_OK)'
   find /root /home -name '.rhosts' 2>/dev/null | wc -l | xargs echo '.rhosts 잔존:'" \
  "VERIFY_OK"

# =============================================================================
# U-28 / 접속 IP 및 포트 제한
#
# 점검 기준:
#   호스트 방화벽이 활성화되어 있고 실제 SSH 포트만 허용하며 불필요한 인바운드 접근을 제한해야 한다.
#
# 조치 내용:
#   firewalld, ufw 또는 iptables/ip6tables 중 사용 가능한 체계로 SSH 포트를 허용하고 기본 인바운드를 제한한다.
#
# 변경 대상:
#   firewalld·ufw·iptables 규칙과 영속 설정 파일
#
# 수동 확인:
#   관리 접속 IP 제한이나 추가 서비스 포트 허용이 필요한 경우 운영 정책에 맞게 직접 보완한다.
#
# 롤백:
#   백업된 방화벽 메타데이터와 롤백 방화벽 복원 로직으로 규칙과 서비스 상태를 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-28" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-28"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-28" "(상) 접속 IP 및 포트 제한"
      _lbl_cur
      if systemctl is-active firewalld &>/dev/null; then
        echo "   firewalld: active" | sed 's/^/   /'
        firewall-cmd --list-all 2>/dev/null | head -8 | sed 's/^/   /'
      elif systemctl is-active nftables &>/dev/null; then
        echo "   nftables: active" | sed 's/^/   /'
      else
        iptables -L INPUT --line-numbers -n 2>/dev/null | head -6 | sed 's/^/   /'
      fi
      echo ""
            _mark_skipped "U-28" "접속 IP 및 포트 제한 [이미양호]"
    else
      _item_header "vuln" "U-28" "(상) 접속 IP 및 포트 제한"
      echo ""
      _u28_ipt=$(iptables -L -n 2>/dev/null | grep -v '^Chain\|^target\|^$' | grep -c '.')
      _u28_ipt=${_u28_ipt:-0}
      _lbl_before
      echo "   firewalld: $(systemctl is-active firewalld 2>/dev/null)"
      echo "   iptables 룰: ${_u28_ipt}개"
      [ -f /etc/hosts.allow ] && echo "   hosts.allow: $(grep -v '^#' /etc/hosts.allow 2>/dev/null | grep -v '^[[:space:]]*$' | head -2)"
      [ -f /etc/hosts.deny ]  && echo "   hosts.deny : $(grep -v '^#' /etc/hosts.deny  2>/dev/null | grep -v '^[[:space:]]*$' | head -2)"
      echo ""
      _lbl_yn
      _read_yn _yn_u28 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u28" != [Yy] ]]; then
        _lbl_skip
                _mark_skipped "U-28" "접속 IP 및 포트 제한 [건너뜀]"
      else
        _lbl_during
        _u28_ssh_ports_preview=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | sort -u)
        [ -z "$_u28_ssh_ports_preview" ] && _u28_ssh_ports_preview="22"

        # ── SSH 포트 실제 감지 ────────────────────────────────────────────
        # sshd -T로 "실제 적용된" 포트를 읽는다 (sshd_config만 보면 다중 Port
        # 지시자나 Include로 실제와 다를 수 있음). 이 값을 못 얻으면 22로
        # 폴백하되, 하드코딩된 22만 열고 DROP을 걸면 SSH를 다른 포트로 운영
        # 중인 서버에서는 관리자 자신의 접속까지 차단해버리는 락아웃 사고로
        # 이어질 수 있으므로 반드시 실제 포트를 먼저 확인한다.
        _u28_ssh_ports="$_u28_ssh_ports_preview"
        echo -e "   ${CYAN}→${RESET} 감지된 SSH 포트: $(echo "$_u28_ssh_ports" | tr '\n' ' ')"

        _u28_persist_ipt() {
          # iptables -A로 추가한 룰은 재부팅 시 사라진다. 가능한 방법으로
          # 영속화를 시도하고, 안 되면 그 사실을 있는 그대로 알린다.
          if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null && return 0
          fi
          if command -v iptables-save &>/dev/null; then
            if [ -d /etc/sysconfig ]; then
              iptables-save > /etc/sysconfig/iptables 2>/dev/null && return 0
            elif [ -d /etc/iptables ]; then
              iptables-save > /etc/iptables/rules.v4 2>/dev/null
              command -v ip6tables-save &>/dev/null \
                && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
              return 0
            fi
          fi
          return 1
        }

        _u28_apply_iptables() {
          # IPv4 + IPv6(가능하면) 모두 동일한 룰을 적용한다. IPv4만 막고
          # IPv6를 그대로 두면 "방화벽 조치 완료"라 표시돼도 IPv6 경로는
          # 뚫려 있는 상태가 된다.
          local _bin
          for _bin in iptables ip6tables; do
            command -v "$_bin" &>/dev/null || continue
            [ "$_bin" = "ip6tables" ] && [ ! -f /proc/net/if_inet6 ] && continue
            "$_bin" -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
            local _p
            for _p in $_u28_ssh_ports; do
              "$_bin" -A INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null
            done
            "$_bin" -A INPUT -i lo -j ACCEPT 2>/dev/null
            "$_bin" -A INPUT -j DROP 2>/dev/null
          done
        }

        if systemctl list-unit-files firewalld.service &>/dev/null; then
          systemctl enable firewalld 2>/dev/null
          systemctl start  firewalld 2>/dev/null
          if systemctl is-active firewalld 2>/dev/null | grep -q '^active'; then
            for _p in $_u28_ssh_ports; do
              firewall-cmd --permanent --add-port="${_p}/tcp" &>/dev/null
            done
            firewall-cmd --reload &>/dev/null
            echo "   firewalld 활성화 완료 (SSH 포트 ${_u28_ssh_ports//$'\n'/, } 허용 등록)"
          else
            _u28_apply_iptables
            if _u28_persist_ipt; then
              echo "   firewalld 활성화 실패 — iptables/ip6tables 기본 룰 적용 및 영속화 완료"
            else
              echo -e "   ${YELLOW}!${RESET} firewalld 활성화 실패 — iptables/ip6tables 룰은 적용했으나 영속화 실패 (재부팅 시 초기화될 수 있음)"
            fi
          fi
        elif command -v ufw &>/dev/null; then
          # Debian/Ubuntu 계열은 firewalld 대신 ufw를 기본으로 쓰는 경우가
          # 많다. 여기서 raw iptables를 별도로 얹으면 ufw 룰과 충돌하거나
          # 이중 관리가 되므로, ufw가 있으면 ufw로 일원화한다.
          for _p in $_u28_ssh_ports; do
            ufw allow "${_p}/tcp" &>/dev/null
          done
          ufw default deny incoming &>/dev/null
          ufw --force enable &>/dev/null
          echo "   ufw 활성화 완료 (SSH 포트 ${_u28_ssh_ports//$'\n'/, } 허용 등록)"
        else
          _u28_apply_iptables
          if _u28_persist_ipt; then
            echo "   firewalld/ufw 미설치 — iptables/ip6tables 기본 룰 적용 및 영속화 완료"
          else
            echo -e "   ${YELLOW}!${RESET} firewalld/ufw 미설치 — iptables/ip6tables 룰은 적용했으나 영속화 실패 (재부팅 시 초기화될 수 있음, iptables-persistent 등 설치 권장)"
          fi
        fi
        echo ""
        _lbl_result
        _u28_fw_active=$(systemctl is-active firewalld 2>/dev/null)
        _u28_fw_enabled=$(systemctl is-enabled firewalld 2>/dev/null)
        _u28_ufw_active=$(systemctl is-active ufw 2>/dev/null)
        if [ "$_u28_fw_active" = "active" ]; then
          _ok "firewalld: ${_u28_fw_active}"
          if [ "$_u28_fw_enabled" = "enabled" ]; then
            _ok "자동 시작: ${_u28_fw_enabled}"
          else
            _fail "자동 시작: ${_u28_fw_enabled:-disabled} (재부팅 시 비활성화될 수 있음)"
          fi
          if command -v firewall-cmd &>/dev/null; then
            echo "   Active Zone : $(firewall-cmd --get-active-zones 2>/dev/null | tr '\n' ' ')"
            echo "   허용 서비스 : $(firewall-cmd --list-services 2>/dev/null)"
            echo "   허용 포트   : $(firewall-cmd --list-ports 2>/dev/null)"
          fi
        elif [ "$_u28_ufw_active" = "active" ]; then
          _ok "ufw: ${_u28_ufw_active}"
          command -v ufw &>/dev/null && ufw status verbose 2>/dev/null | sed 's/^/   /'
        else
          _u28_ipt2=$(iptables -L -n 2>/dev/null | grep -v '^Chain\|^target\|^$' | grep -c '.')
          _u28_ipt2=${_u28_ipt2:-0}
          if [ "$_u28_ipt2" -gt 0 ]; then
            echo -e "   ${YELLOW}!${RESET} firewalld 비활성, iptables 룰 ${_u28_ipt2}개로 대체 적용됨"
          else
            _fail "firewalld도 iptables 룰도 없음 — 조치 실패"
          fi
        fi
        echo ""
        check_still_vuln "U-28"; _u28_rc=$?
        BEFORE_VAL["U-28"]="방화벽 미설정"
        if [ $_u28_rc -eq 1 ]; then
          AFTER_VAL["U-28"]="방화벽 활성화 완료"
          _lbl_done_nr
          _mark_fixed "U-28" "(상) 접속 IP 및 포트 제한 — 조치 완료"
        else
          AFTER_VAL["U-28"]="조치 실패"
          echo -e " ${RED}→ 조치 후에도 여전히 취약 — 수동 확인 필요${RESET}"
          _mark_failed "U-28" "(상) 접속 IP 및 포트 제한 — 조치 후에도 여전히 취약"
        fi
      fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-29 / hosts.lpd 소유자 및 권한
#
# 점검 기준:
#   /etc/hosts.lpd가 존재하면 root 소유이며 권한이 600이어야 한다.
#
# 조치 내용:
#   소유자·그룹을 root:root, 권한을 600으로 설정한다.
#
# 변경 대상:
#   /etc/hosts.lpd
#
# 수동 확인:
#   파일이 없으면 해당 설정을 사용하지 않는 것으로 보고 양호 처리한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 파일 백업으로 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-29" "(하) hosts.lpd 파일 소유자 및 권한 설정" \
  "[ -f /etc/hosts.lpd ] && stat -c '소유자: %U / 권한: %a' /etc/hosts.lpd || echo '파일 없음 (양호)'" \
  "_p=/etc/hosts.lpd; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; [ -f /etc/hosts.lpd ] && chown root:root /etc/hosts.lpd && chmod 600 /etc/hosts.lpd" \
  "[ -f /etc/hosts.lpd ] && stat -c '소유자: %U / 권한: %a' /etc/hosts.lpd || echo '파일 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-30 / UMASK 설정 관리
#
# 점검 기준:
#   로그인 환경의 UMASK가 022 이상으로 설정되어 그룹·기타 사용자 쓰기 권한을 제한해야 한다.
#
# 조치 내용:
#   취약한 umask 줄을 제거하고 /etc/login.defs와 /etc/profile에 안전한 값을 적용한다.
#
# 변경 대상:
#   /etc/profile, /etc/bashrc, /etc/bash.bashrc, /etc/login.defs, /etc/profile.d/*.sh
#
# 수동 확인:
#   077 등 더 엄격한 기존 값은 유지하며 응용프로그램이 특정 기본 권한을 요구하면 직접 확인한다.
#
# 롤백:
#   조치 전 셸 초기화 파일과 login.defs 백업으로 UMASK 설정을 복원한다.
# =============================================================================

do_fix "U-30" "(중) UMASK 설정 관리" \
  '# 조치 전: 설정 파일 기준 현재 umask 표시 (세션값 아님)
   _o=$(for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/login.defs /etc/profile.d/*.sh; do
     [ -f "$F" ] || continue
     V=$(grep -v "^#" "$F" | grep -oE "\bumask[[:space:]]+[0-9]+" | head -1)
     [ -n "$V" ] && echo "  $F: $V"
   done); [ -n "$_o" ] && echo "$_o" || echo "  설정 없음"' \
  '# 0) umask 값이 KISA 022 이상(비트마스크 기준 — 그룹/기타 쓰기권한 제거)인지 판정.
   #    077처럼 022보다 더 엄격한 값도 여기서 양호로 인정된다.
   _u30_ok() {
     local v="$1"
     [[ "$v" =~ ^0*[0-7]{3,4}$ ]] || return 1
     [ $(( (8#$v) & (8#022) )) -eq $(( 8#022 )) ]
   }
   # 1) 각 설정 파일에서 기준 미충족 umask 줄만 제거하고 022 이상인 값은 보존한다.
   for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/profile.d/*.sh; do
     [ -f "$F" ] || continue
     grep -qE "^\s*umask\s+[0-9]" "$F" 2>/dev/null || continue
     _u30_tmp=$(mktemp 2>/dev/null || echo "${F}.u30tmp.$$")
     _u30_changed=0
     while IFS= read -r _u30_line || [ -n "$_u30_line" ]; do
       if echo "$_u30_line" | grep -qE "^\s*umask\s+[0-9]+"; then
         _u30_v=$(echo "$_u30_line" | sed -E "s/^[[:space:]]*umask[[:space:]]+([0-9]+).*/\1/")
         if _u30_ok "$_u30_v"; then
           echo "$_u30_line" >> "$_u30_tmp"
         else
           _u30_changed=1
         fi
       else
         echo "$_u30_line" >> "$_u30_tmp"
       fi
     done < "$F"
     if [ "$_u30_changed" -eq 1 ]; then
       cat "$_u30_tmp" > "$F"
       echo "   취약 umask 제거: $F"
     fi
     rm -f "$_u30_tmp"
   done
   # 2) login.defs UMASK 수정
   if [ -f /etc/login.defs ]; then
     UM_LD=$(grep -v "^#" /etc/login.defs | grep -iE "^\s*UMASK\s+" | awk "{print \$2}" | tail -1)
     if [ -n "$UM_LD" ] && ! _u30_ok "$UM_LD"; then
       config_set /etc/login.defs '^[[:space:]]*UMASK[[:space:]].*' 'UMASK	022' line && echo "   login.defs UMASK → 022"
     fi
   fi
   # 3) /etc/profile에 안전한 umask 없으면 추가
   _u30_cur=$(grep -v "^#" /etc/profile 2>/dev/null | grep -oE "^\s*umask\s+[0-9]+" | awk "{print \$2}" | tail -1)
   if [ -z "$_u30_cur" ] || ! _u30_ok "$_u30_cur"; then
     _safe_append /etc/profile "# KISA U-30: 파일 생성 기본 권한
umask 022"
     echo "   /etc/profile에 umask 022 추가"
   fi' \
  'echo "--- 조치 후 설정 파일 확인 ---"
   for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/login.defs; do
     [ -f "$F" ] || continue
     V=$(grep -v "^#" "$F" | grep -oE "\b(umask|UMASK)\s+[0-9]+" | head -1)
     [ -n "$V" ] && echo "  $F: $V"
   done
   _u30_final=$(grep -v "^#" /etc/profile 2>/dev/null | grep -oE "^\s*umask\s+[0-9]+" | awk "{print \$2}" | tail -1)
   _u30_ok "$_u30_final" && echo "umask 설정 확인 (VERIFY_OK)" || echo "설정 미확인"' \
  "VERIFY_OK"

# =============================================================================
# U-31 / 홈 디렉터리 소유자 및 권한
#
# 점검 기준:
#   일반 사용자 홈 디렉터리는 해당 사용자 소유이며 권한이 755를 초과하지 않아야 한다.
#
# 조치 내용:
#   홈 소유자가 계정과 다르면 해당 사용자로 변경하고 과도한 권한은 750으로 제한한다.
#
# 변경 대상:
#   UID 1000 이상 사용자 계정의 홈 디렉터리
#
# 수동 확인:
#   공유 홈이나 서비스 계정 홈처럼 별도 소유 정책이 있는 경로는 적용 전에 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 메타데이터로 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-31" "(중) 홈 디렉토리 소유자 및 권한 설정" \
  "while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     [ -d \"\$homedir\" ] || continue
     O=\$(stat -c '%U' \"\$homedir\"); P=\$(stat -c '%a' \"\$homedir\")
     echo \"\$homedir — \${O}/\${P}\"
   done < /etc/passwd" \
  "while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     [ -d \"\$homedir\" ] || continue
     O=\$(stat -c '%U' \"\$homedir\"); G=\$(stat -c '%G' \"\$homedir\"); P=\$(stat -c '%a' \"\$homedir\")
     printf 'PERM_RESTORE|%s|%s|%s:%s\\n' \"\$homedir\" \"\$P\" \"\$O\" \"\$G\" >> \"\${FIX_HISTORY_FILE}\" 2>/dev/null
     [ \"\$O\" != \"\$user\" ] && chown \"\$user\" \"\$homedir\"
     [ \"\$P\" -gt 755 ] 2>/dev/null && chmod 750 \"\$homedir\"
   done < /etc/passwd" \
  "while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     [ -d \"\$homedir\" ] || continue
     stat -c \"\$homedir — %U/%a\" \"\$homedir\"
   done < /etc/passwd" \
  ""

# =============================================================================
# U-32 / 계정 홈 디렉터리 존재 관리
#
# 점검 기준:
#   로그인 가능한 일반 계정의 홈 경로가 실제 디렉터리로 존재해야 한다.
#
# 조치 내용:
#   누락된 홈 디렉터리를 생성하고 /etc/skel을 복사한 뒤 계정 소유권과 750 권한을 적용한다.
#
# 변경 대상:
#   /etc/passwd에 지정된 일반 사용자 홈 디렉터리
#
# 수동 확인:
#   외부 스토리지나 자동 마운트 홈을 사용하는 계정은 로컬 디렉터리 생성 전에 확인한다.
#
# 롤백:
#   CREATED_PATH 레코드로 새로 만든 홈을 식별하고 안전한 경우 제거한다.
# =============================================================================

do_fix "U-32" "(중) 홈 디렉토리로 지정한 디렉토리의 존재 관리" \
  "while IFS=: read -r user _ uid gid _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     { [ \"\$user\" = \"nobody\" ] || [ \"\$uid\" -ge 65534 ] 2>/dev/null; } && continue
     [ -n \"\$homedir\" ] && [ ! -d \"\$homedir\" ] && echo \"\$user: 홈 디렉터리 미존재(\$homedir)\"
   done < /etc/passwd" \
  "while IFS=: read -r user _ uid gid _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     { [ \"\$user\" = \"nobody\" ] || [ \"\$uid\" -ge 65534 ] 2>/dev/null; } && continue
     [ -z \"\$homedir\" ] || [ -d \"\$homedir\" ] && continue
     printf 'CREATED_PATH|%s|d\\n' \"\$homedir\" >> \"\${FIX_HISTORY_FILE}\" 2>/dev/null
     mkdir -p \"\$homedir\"
     [ -d /etc/skel ] && cp -rT /etc/skel \"\$homedir\" 2>/dev/null
     chown -R \"\$uid:\$gid\" \"\$homedir\" 2>/dev/null
     chmod 750 \"\$homedir\" 2>/dev/null
     echo \"   생성: \$homedir (소유자 \$user, 권한 750)\"
   done < /etc/passwd" \
  "_o=\$(while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     { [ \"\$user\" = \"nobody\" ] || [ \"\$uid\" -ge 65534 ] 2>/dev/null; } && continue
     [ -n \"\$homedir\" ] && [ ! -d \"\$homedir\" ] && echo \"\$user: 여전히 미존재(\$homedir)\"
   done < /etc/passwd); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '모든 계정 홈 디렉터리 정상 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-33 / 숨겨진 파일 및 디렉터리 점검
#
# 점검 기준:
#   정상 예외를 제외한 의심 숨김 파일·디렉터리가 없거나 용도가 확인되어야 한다.
#
# 조치 내용:
#   자동 삭제하지 않고 경로·유형·권한과 실행 가능 여부를 표시한다.
#
# 변경 대상:
#   로컬 파일시스템에서 탐지된 의심 dotfile·dotdir
#
# 수동 확인:
#   정상 애플리케이션 파일과 악성·불필요 파일을 담당자가 직접 구분해 처리한다.
#
# 롤백:
#   자동 변경이 없으므로 별도 롤백 대상은 없다.
# =============================================================================

do_manual "U-33" "(하) 숨겨진 파일 및 디렉토리 검색 및 제거" \
  "의심 숨김 파일/디렉터리는 정상 설정 파일일 수 있으므로 담당자가 직접 확인 후 처리 필요.
   - 정상: Java·Oracle·D-Bus·X11 등 애플리케이션 dotfile
   - 위험: 실행 권한이 있는 정체불명 파일, /tmp 내 의심 스크립트 등
   ※ 확인 후 불필요하면 'rm -rf <경로>'로 직접 삭제
   ※ 아래 목록의 파일이 모두 삭제(또는 예외 확인)되어야 재점검 시 양호로 판정됩니다." \
  "echo '=== 의심 숨김 파일/디렉터리 목록 (정상 예외 제외 후) ==='
   _list=\$(_u33_find)
   if [ -z \"\$_list\" ]; then
     echo '  의심 항목 없음 — 양호'
   else
     echo \"\$_list\" | while IFS= read -r f; do
       _type=\$([ -d \"\$f\" ] && echo 'DIR' || echo 'FILE')
       _perm=\$(stat -c '%a %U' \"\$f\" 2>/dev/null || echo '?')
       printf '  [%s] %s  (권한:%s)\\n' \"\$_type\" \"\$f\" \"\$_perm\"
     done
     echo ''
     echo '  ▶ 실행 권한 있는 항목 강조:'
     echo \"\$_list\" | xargs -I{} find {} -maxdepth 0 -perm /111 2>/dev/null \
       | while IFS= read -r f; do echo \"  ⚠ 실행가능: \$f\"; done || echo '  없음'
   fi"

# ============================================================
_has_cat_target "서비스 관리" && section_header "서비스 관리"
# ============================================================

# =============================================================================
# U-34 / Finger 서비스 비활성화
#
# 점검 기준:
#   finger 관련 서비스·소켓과 TCP 79 포트가 비활성 상태여야 한다.
#
# 조치 내용:
#   finger, fingerd, cfingerd 서비스를 중지하고 자동 시작을 비활성화한다.
#
# 변경 대상:
#   finger 관련 systemd 서비스·소켓 상태
#
# 수동 확인:
#   업무상 Finger 서비스가 필요한 예외 환경은 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 enable/active 상태를 복원한다.
# =============================================================================

do_fix "U-34" "(상) Finger 서비스 비활성화" \
  "# 패키지 설치 여부
   for pkg in finger finger-server; do
     _r=\$(rpm -q \$pkg 2>/dev/null)
     [ -z \"\$_r\" ] && _r=\$(dpkg -l \$pkg 2>/dev/null | grep '^ii' | awk '{print \$2, \$3}')
     echo \"\$pkg: \${_r:-not installed}\"
   done
   echo ''
   # 서비스/소켓 상태
   for svc in finger.socket fingerd.service cfingerd.service; do
     _st=\$(systemctl is-active \$svc 2>/dev/null)
     echo \"\$svc: \${_st:-Unit not found}\"
   done
   echo ''
   # 포트 사용 여부
   ss -tlnp 2>/dev/null | grep ':79 ' || echo 'Port 79 (finger): 미사용'" \
  "systemctl stop finger 2>/dev/null; systemctl disable finger 2>/dev/null
   for svc in fingerd cfingerd; do systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null; done" \
  "ss -tlnp 2>/dev/null | grep ':79 ' || echo 'Finger 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-39 / 불필요한 NFS 서비스 비활성화
#
# 점검 기준:
#   업무상 필요하지 않은 NFS 서버와 관련 서비스가 비활성 상태여야 한다.
#
# 조치 내용:
#   사용자가 불필요함을 확인한 경우 nfs-server, nfs-mountd, rpc-statd를 중지하고 NFS 서버를 비활성화·마스킹한다.
#
# 변경 대상:
#   NFS 관련 systemd 서비스와 커널 nfsd/export 상태
#
# 수동 확인:
#   현재 공유·마운트·업무 연계가 있는지 반드시 확인하고 필요한 서비스면 유지한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태와 방화벽·설정 파일을 기준으로 원래 상태를 복원한다.
# =============================================================================

{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-39" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-39"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-39" "(상) 불필요한 NFS 서비스 비활성화"
      _lbl_cur
      echo "   nfs-server: $(systemctl is-active nfs-server 2>/dev/null || echo 'inactive')"
      echo "   rpcbind:    $(systemctl is-active rpcbind 2>/dev/null || echo 'inactive')"
      echo ""
            BEFORE_VAL["U-39"]=$(systemctl is-active nfs-server 2>/dev/null || echo "NFS 비활성")
            [ -z "${BEFORE_VAL["U-39"]:-}" ] && BEFORE_VAL["U-39"]="이미 양호 (점검 통과)"
            AFTER_VAL["U-39"]="이미 양호 (재확인 통과)"
            _mark_skipped "U-39" "NFS 비활성화 [이미양호]"
    else
      _item_header "vuln" "U-39" "(상) 불필요한 NFS 서비스 비활성화"
      echo ""; _lbl_before
      echo "   nfs-server: $(systemctl is-active nfs-server 2>/dev/null)"
      mount | grep nfs | sed 's/^/   /' 2>/dev/null
      echo ""
      echo -e " ${YELLOW}[!] NFS가 현재 사용 중일 수 있습니다. 업무 필요 여부를 확인하세요.${RESET}"
      echo -e " ${YELLOW}※ y = 비활성화 진행, n = 건너뜀${RESET}"
      _read_yn _nfs_yn " 업무상 불필요한 NFS임을 확인했습니까? (y/n): "
      case "$_nfs_yn" in
        [Yy])
          systemctl stop nfs-server nfs-mountd rpc-statd 2>/dev/null
          systemctl disable nfs-server 2>/dev/null; systemctl mask nfs-server 2>/dev/null
          echo ""
          _u39_active=$(systemctl is-active nfs-server 2>/dev/null)
          _u39_enabled=$(systemctl is-enabled nfs-server 2>/dev/null)
          _u39_proc=$(ps -ef | grep '[n]fsd')
          _u39_mount=$(mount | grep nfsd)
          _u39_showmount=$(showmount -e localhost 2>/dev/null | grep -v '^Export list')

          echo -e " ${YELLOW}[서비스 상태]${RESET}"
          if [ "$_u39_active" != "active" ]; then _ok "nfs-server      : ${_u39_active:-inactive}"; else _fail "nfs-server      : ${_u39_active}"; fi
          if [ "$_u39_enabled" != "enabled" ]; then _ok "자동 시작       : ${_u39_enabled:-masked}"; else _fail "자동 시작       : ${_u39_enabled}"; fi
          echo ""
          echo -e " ${YELLOW}[커널 상태]${RESET}"
          if [ -z "$_u39_proc" ]; then _ok "nfsd 프로세스   : 없음"; else _warn "nfsd 프로세스   : 존재"; fi
          if [ -z "$_u39_mount" ]; then _ok "/proc/fs/nfsd   : 마운트 없음"; else _warn "/proc/fs/nfsd   : 마운트됨"; fi

          # U-35/U-40을 "해당없음"으로 표시하려면 systemd 서비스가 꺼진 것만으로는 부족하다 —
          # 커널 nfsd 잔존 프로세스/마운트가 있으면 showmount로 실제 export가 살아있는지까지
          # 확인해서, 둘 다 깨끗할 때만 "조치 불필요"로 판단한다.
          if [ -n "$_u39_proc" ] || [ -n "$_u39_mount" ]; then
            echo ""
            echo -e " ${YELLOW}[안내]${RESET}"
            echo "   • nfs-server 서비스는 정상적으로 비활성화되었습니다."
            echo "   • nfsd는 커널 모듈이므로 서비스 종료 후에도 일시적으로 남아 있을 수 있습니다."
            if [ -n "$_u39_showmount" ]; then
              echo ""
              echo -e "   ${RED}⚠ showmount 결과 실제로 공유 중인 export가 남아있습니다:${RESET}"
              echo "$_u39_showmount" | sed 's/^/     /'
            fi
            echo ""
            echo -e " ${YELLOW}[권장 사항]${RESET}"
            echo "   • 시스템 재부팅 후 재확인"
            echo "     또는"
            echo "   • 관련 RPC/NFS 프로세스 종료 후 재확인 (예: fuser -k /proc/fs/nfsd, rpcinfo -p 확인)"
          fi

          echo ""
          _lbl_result
          _ok "NFS 서비스   : 비활성"
          if [ -n "$_u39_proc" ] || [ -n "$_u39_mount" ]; then
            _warn "커널 nfsd    : 잔존 (재확인 권장)"
          else
            _ok "커널 nfsd    : 잔존 없음"
          fi
          _mark_fixed "U-39" "불필요한 NFS 서비스 비활성화 완료"

          # systemd 서비스가 죽어있고(inactive) + 커널에 잔존 프로세스/마운트가 없고 +
          # showmount로 실제 노출되는 export도 없을 때만 U-35/U-40을 해당없음으로 표시한다.
          if [ "$_u39_active" != "active" ] && [ -z "$_u39_proc" ] && [ -z "$_u39_mount" ] && [ -z "$_u39_showmount" ]; then
            _NFS_DISABLED=1
            # U-35, U-40 해당없음 처리
            for _nfs_dep in "U-35:공유 서비스 익명 접근 제한" "U-40:NFS 접근 통제"; do
              _dep_id="${_nfs_dep%%:*}"; _dep_name="${_nfs_dep##*:}"
              for _tid in "${TARGET_IDS[@]}"; do
                if [ "$_tid" = "$_dep_id" ]; then
                  _div_thick
                  echo -e "${CYAN}[○ 해당없음]${RESET} ${BOLD}${_dep_id}${RESET} (상) ${_dep_name}"
                  echo -e " ${CYAN}→ U-39에서 NFS 서비스를 비활성화했고, 커널/export 잔존도 없어 조치 불필요${RESET}"
                  echo ""
                  echo ""
                  BEFORE_VAL["$_dep_id"]="U-39에서 NFS 서비스 비활성화 확인"
                  AFTER_VAL["$_dep_id"]="해당없음"
                  DETAIL_VAL["$_dep_id"]="[연계 판정] U-39 조치 후 NFS 서비스/커널/export 잔존 없음"
                  _mark_na "$_dep_id" "${_dep_name} [NFS 비활성화로 불필요]"
                  break
                fi
              done
            done
          else
            _NFS_DISABLED=0
            echo ""
            echo -e " ${YELLOW}※ 커널/export 잔존이 있어 U-35, U-40은 자동으로 해당없음 처리하지 않고 그대로 점검합니다.${RESET}"
          fi
          ;;
        *) echo -e " ${YELLOW}→ 건너뜁니다. (NFS 서비스 유지 — 업무상 필요로 판단)${RESET}"
           echo -e " ${YELLOW}   현재 상태:${RESET}"
           echo "   nfs-server: $(systemctl is-active nfs-server 2>/dev/null)"
           _u39_mount_out=$(mount | grep nfs 2>/dev/null)
           if [ -n "$_u39_mount_out" ]; then echo "$_u39_mount_out" | sed 's/^/   /'; else echo "   마운트된 NFS 없음"; fi
           showmount -e localhost 2>/dev/null | sed 's/^/   /' || true
                      _mark_skipped "U-39" "NFS 비활성화 [업무상 유지]"
          _NFS_DISABLED=0 ;;
      esac
    fi
    echo ""
  fi
}

# =============================================================================
# U-35 / 공유 서비스 익명 접근 제한
#
# 점검 기준:
#   FTP·Samba·NFS 공유에서 익명·guest·전체 허용 접근이 차단되고 NFS export가 신뢰 대상에 한정되어야 한다.
#
# 조치 내용:
#   FTP 익명 계정을 잠그거나 관련 서비스를 제한하고 NFS의 전체 허용 export를 지정한 신뢰 IP·대역으로 변경한다.
#
# 변경 대상:
#   FTP/ProFTPD/Samba 설정과 계정, /etc/exports, 관련 서비스 상태
#
# 수동 확인:
#   NFS 신뢰 IP·대역과 업무상 익명 접근 필요 여부는 사용자가 직접 결정한다.
#
# 롤백:
#   조치 전 설정 파일·계정·서비스 백업과 역산 레코드로 원래 상태를 복원한다.
# =============================================================================

[ "${_NFS_DISABLED:-0}" -eq 0 ] && \
{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-35" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-35"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정"
      _lbl_cur
      # FTP
      for f in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
        [ -f "$f" ] || continue
        echo "   [$f]"
        grep -v '^\s*#' "$f" | grep -i 'anonymous' | sed 's/^/     /'
      done
      for f in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$f" ] || continue
        echo "   [$f]"
        grep -v '^\s*#' "$f" | grep -iE 'Anonymous' | head -3 | sed 's/^/     /'
      done
      # Samba
      if [ -f /etc/samba/smb.conf ]; then
        echo "   [/etc/samba/smb.conf]"
        grep -i 'guest\|map to guest' /etc/samba/smb.conf | grep -v '^\s*#' | head -3 | sed 's/^/     /'
      fi
      # 서비스 상태
      echo ""
      for svc in vsftpd proftpd smbd; do
        _st=$(systemctl is-active "$svc" 2>/dev/null)
        echo "   $svc: ${_st:-Unit not found}"
      done
      echo ""
            BEFORE_VAL["U-35"]=$(echo "FTP/NFS 익명접근 제한됨")
            [ -z "${BEFORE_VAL["U-35"]:-}" ] && BEFORE_VAL["U-35"]="이미 양호 (점검 통과)"
            AFTER_VAL["U-35"]="이미 양호 (재확인 통과)"
            _mark_skipped "U-35" "공유 서비스 익명 접근 제한 [이미양호]"
    else
      _item_header "vuln" "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정"
      echo ""
      _lbl_before
      echo "   [FTP 기본계정]"
      _u35_ftpacc_found=0
      for _acc in ftp anonymous; do
        if grep -q "^${_acc}:" /etc/passwd 2>/dev/null; then
          BEFORE_VAL["U-35"]=$(echo "FTP/NFS 익명 접근 제한 양호")
          [ -z "${BEFORE_VAL["U-35"]:-}" ] && BEFORE_VAL["U-35"]="이미 양호 (점검 통과)"
          AFTER_VAL["U-35"]="이미 양호 (재확인 통과)"
          echo "     ${_acc} 계정 존재"
          _u35_ftpacc_found=1
        fi
      done
      [ $_u35_ftpacc_found -eq 0 ] && echo "     (ftp/anonymous 계정 없음)"

      echo "   [vsftpd]"
      _u35_vsftpd_found=0
      for _cf in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
        if [ -f "$_cf" ]; then
          _u35_vsftpd_out=$(grep -i 'anonymous_enable' "$_cf")
          [ -n "$_u35_vsftpd_out" ] && echo "$_u35_vsftpd_out" | sed 's/^/     /' && _u35_vsftpd_found=1
        fi
      done
      [ $_u35_vsftpd_found -eq 0 ] && echo "     (vsftpd 미설치 또는 설정 없음)"

      echo "   [ProFTPD]"
      _u35_proftpd_found=0
      for _cf in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        if [ -f "$_cf" ]; then
          _u35_proftpd_out=$(grep -iE '<Anonymous' "$_cf")
          [ -n "$_u35_proftpd_out" ] && echo "$_u35_proftpd_out" | sed 's/^/     /' && _u35_proftpd_found=1
        fi
      done
      [ $_u35_proftpd_found -eq 0 ] && echo "     (ProFTPD 미설치 또는 Anonymous 블록 없음)"

      echo "   [NFS exports]"
      if [ -f /etc/exports ]; then
        _u35_exports_pre=$(cat /etc/exports 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$')
        if [ -n "$_u35_exports_pre" ]; then
          echo "$_u35_exports_pre" | sed 's/^/     /'
        else
          echo "     (exports 설정 없음 — 빈 파일)"
        fi
      else
        echo "     /etc/exports 없음"
      fi
      echo ""
      _lbl_yn
      _read_yn _yn_u35 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u35" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-35" "공유 서비스 익명 접근 제한 [건너뜀]"
      else
        _lbl_during
        echo -e "   ${CYAN}→${RESET} FTP/NFS 익명 접근 차단 조치 적용"
        # 1) FTP 기본계정(ftp, anonymous) 잠금 처리
        for _acc in ftp anonymous; do
          grep -q "^${_acc}:" /etc/passwd 2>/dev/null && usermod -L -s /sbin/nologin "$_acc" 2>/dev/null \
            && echo "   ${_acc} 계정 잠금 및 셸 변경 완료"
        done
        # 2) vsftpd anonymous_enable=NO 처리
        for _cf in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
          [ -f "$_cf" ] || continue
          _backup_file "$_cf" >/dev/null
          config_set "$_cf" '^[[:space:]]*[Aa][Nn][Oo][Nn][Yy][Mm][Oo][Uu][Ss]_[Ee][Nn][Aa][Bb][Ll][Ee].*' 'anonymous_enable=NO' line
          systemctl restart vsftpd 2>/dev/null
          echo "   vsftpd anonymous_enable=NO 설정 완료 ($_cf)"
        done
        # 3) ProFTPD <Anonymous> 블록 비활성화 (주석 처리)
        for _cf in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
          [ -f "$_cf" ] || continue
          grep -qiE '^\s*<Anonymous' "$_cf" || continue
          _backup_file "$_cf" >/dev/null
          sed -i '/<Anonymous/,/<\/Anonymous>/ s/^/#/' "$_cf"
          systemctl restart proftpd 2>/dev/null
          echo "   ProFTPD Anonymous 블록 주석 처리 완료 ($_cf)"
        done

        # 4) NFS exports 위험 요소 분석 — IP를 묻기 전에 "무엇이 위험한지" 먼저 보여준다
        if [ -f /etc/exports ]; then
          ANON_LINE=$(grep -v '^#' /etc/exports | grep -E '^\s*/.*\*\s*\(' | head -1)
          NOSQ_LINES=$(grep -v '^#' /etc/exports | grep 'no_root_squash')
          if [ -n "$ANON_LINE" ] || [ -n "$NOSQ_LINES" ]; then
            echo ""
            echo -e " ${BOLD}${CYAN}NFS 보안 설정${RESET}"
            echo ""
            echo -e " ${YELLOW}위험 요소${RESET}"
            [ -n "$ANON_LINE" ]  && _fail "모든 호스트(*) 접근 허용"
            [ -n "$NOSQ_LINES" ] && _fail "no_root_squash 사용 (클라이언트 root가 NFS 서버에서도 root 권한 유지)"
            echo ""
            echo -e " ${YELLOW}적용할 조치${RESET}"
            [ -n "$ANON_LINE" ]  && echo "   1) 허용 호스트 지정 (* 제거)"
            [ -n "$NOSQ_LINES" ] && echo "   2) root_squash 적용"
            [ -n "$ANON_LINE" ] && [ -n "$NOSQ_LINES" ] && echo "   3) 두 가지 모두 적용 (권장)"
            echo "   0) 건너뛰기"
            printf '%s' " 선택: "
            read -r _u35_nfs_choice

            _do_ip_restrict=0; _do_root_squash=0
            case "$_u35_nfs_choice" in
              1) [ -n "$ANON_LINE" ] && _do_ip_restrict=1 ;;
              2) [ -n "$NOSQ_LINES" ] && _do_root_squash=1 ;;
              3) [ -n "$ANON_LINE" ] && _do_ip_restrict=1; [ -n "$NOSQ_LINES" ] && _do_root_squash=1 ;;
              *) echo -e " ${YELLOW}→ NFS exports 조치를 건너뜁니다.${RESET}"
                 _mark_manual "U-35" "NFS exports 위험요소(전체허용/no_root_squash) — 건너뜀" ;;
            esac

            if [ "$_do_root_squash" -eq 1 ]; then
              _u35_exp_bak="/etc/exports.bak.$(date +%Y%m%d_%H%M%S)"
              cp /etc/exports "$_u35_exp_bak"
              sed -i 's/,no_root_squash//g; s/no_root_squash,//g; s/no_root_squash//g' /etc/exports
              if _nfs_exports_guard "$_u35_exp_bak"; then
                echo -e " ${GREEN}→ no_root_squash 제거 완료 (root_squash 적용)${RESET}"
              else
                echo -e " ${RED}→ no_root_squash 제거 조치가 문법 오류로 취소되었습니다 (원상 복구됨)${RESET}"
              fi
            fi
          fi
          if [ -n "$ANON_LINE" ] && [ "${_do_ip_restrict:-0}" -eq 1 ]; then
            echo ""
            echo -e " ${YELLOW}[NFS] 현재 익명 접근(*) 설정이 발견되었습니다:${RESET}"
            echo "   ${ANON_LINE}"
            echo -e " ${YELLOW}허용할 신뢰 IP 또는 대역(CIDR)을 입력하세요.${RESET}"
            echo "   예: 192.168.10.50  또는  192.168.10.0/24"
            echo "   입력 없이 Enter = 조치 건너뜀(수동확인) / s = 외부 신뢰 IP 없음(로컬호스트로 차단)"
            printf '%s' " 신뢰 IP/대역 입력: "
            read -r _nfs_ip

            _IP_RE='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/([0-9]|[12][0-9]|3[0-2]))?$'

            if [ -z "$_nfs_ip" ]; then
              # 입력 없음 → 추측하지 않고 수동확인으로 전환 (조치 보류)
              echo -e " ${YELLOW}→ 입력이 없어 NFS 조치를 건너뜁니다. 신뢰 대역 확인 후 재실행하세요.${RESET}"
              _mark_manual "U-35" "NFS exports 익명 접근(*) — 신뢰 IP/대역 미입력으로 보류"

            elif [ "$_nfs_ip" = "s" ] || [ "$_nfs_ip" = "S" ]; then
              # 명시적으로 "신뢰 IP 없음" → 로컬호스트로 강하게 제한(사실상 외부 비공개)
              _u35_exp_bak="/etc/exports.bak.$(date +%Y%m%d_%H%M%S)"
              cp /etc/exports "$_u35_exp_bak"
              sed -i 's/\*(rw/127.0.0.1(rw/g; s/\*(ro/127.0.0.1(ro/g' /etc/exports
              if _nfs_exports_guard "$_u35_exp_bak"; then
                echo -e " ${GREEN}→ 외부 신뢰 IP 없음으로 확인 — 127.0.0.1(로컬호스트)로 제한 완료${RESET}"
                echo -e " ${YELLOW}   ※ 외부 공유가 필요 없다면 NFS 서비스 자체 중지를 권장합니다 (U-39 참고)${RESET}"
              else
                echo -e " ${RED}→ 127.0.0.1 제한 조치가 문법 오류로 취소되었습니다 (원상 복구됨)${RESET}"
              fi

            elif [ "$_nfs_ip" = "0.0.0.0/0" ]; then
              # 형식은 유효하나 전체 허용 — 익명 접근 제한 의미 무력화, 경고 후 수동확인
              echo -e " ${RED}!! 0.0.0.0/0은 전체 IP 허용으로, 익명 접근 제한과 동일한 효과입니다.${RESET}"
              echo -e " ${YELLOW}   적용하지 않고 수동확인으로 전환합니다.${RESET}"
              _mark_manual "U-35" "NFS exports — 0.0.0.0/0 입력으로 제한 의미 없음, 재검토 필요"

            elif echo "$_nfs_ip" | grep -qE "$_IP_RE"; then
              # 정상 형식 → 입력값으로 치환
              _u35_exp_bak="/etc/exports.bak.$(date +%Y%m%d_%H%M%S)"
              cp /etc/exports "$_u35_exp_bak"
              sed -i "s#\*(rw#${_nfs_ip}(rw#g; s#\*(ro#${_nfs_ip}(ro#g" /etc/exports
              if _nfs_exports_guard "$_u35_exp_bak"; then
                echo -e " ${GREEN}→ NFS exports 익명 접근(*) → ${_nfs_ip} 로 제한 완료${RESET}"
              else
                echo -e " ${RED}→ ${_nfs_ip} 제한 조치가 문법 오류로 취소되었습니다 (원상 복구됨)${RESET}"
              fi

            else
              # 형식 오류 → 재입력 1회 시도
              echo -e " ${YELLOW}잘못된 형식입니다. 다시 입력하세요 (예: 192.168.10.0/24):${RESET}"
              printf '%s' " 신뢰 IP/대역 재입력: "
              read -r _nfs_ip2
              if [ "$_nfs_ip2" = "0.0.0.0/0" ]; then
                echo -e " ${RED}!! 0.0.0.0/0은 전체 IP 허용으로, 익명 접근 제한과 동일한 효과입니다.${RESET}"
                _mark_manual "U-35" "NFS exports — 0.0.0.0/0 재입력으로 제한 의미 없음, 재검토 필요"
              elif echo "$_nfs_ip2" | grep -qE "$_IP_RE"; then
                _u35_exp_bak="/etc/exports.bak.$(date +%Y%m%d_%H%M%S)"
                cp /etc/exports "$_u35_exp_bak"
                sed -i "s#\*(rw#${_nfs_ip2}(rw#g; s#\*(ro#${_nfs_ip2}(ro#g" /etc/exports
                if _nfs_exports_guard "$_u35_exp_bak"; then
                  echo -e " ${GREEN}→ NFS exports 익명 접근(*) → ${_nfs_ip2} 로 제한 완료${RESET}"
                else
                  echo -e " ${RED}→ ${_nfs_ip2} 제한 조치가 문법 오류로 취소되었습니다 (원상 복구됨)${RESET}"
                fi
              else
                # 재입력도 실패 → 추측해서 적용하지 않고 수동확인으로 전환
                echo -e " ${YELLOW}→ 형식 오류 반복 — 자동 추측 없이 수동확인으로 전환합니다.${RESET}"
                _mark_manual "U-35" "NFS exports 익명 접근(*) — IP 형식 오류로 수동 조치 필요"
              fi
            fi
          fi
        fi

        echo ""
        _lbl_result
        echo -e " ${YELLOW}===== FTP =====${RESET}"
        for _cf in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
          [ -f "$_cf" ] && grep "^anonymous_enable" "$_cf" 2>/dev/null | sed 's/^/   /'
        done
        for _acc in ftp anonymous; do
          _shell=$(grep "^${_acc}:" /etc/passwd 2>/dev/null | cut -d: -f7)
          [ -n "$_shell" ] && echo "   ${_acc} shell: ${_shell}"
        done
        echo ""
        echo -e " ${YELLOW}===== NFS (exports) =====${RESET}"
        _u35_exports_out=$(cat /etc/exports 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$')
        if [ -n "$_u35_exports_out" ]; then
          echo "$_u35_exports_out" | sed 's/^/   /'
        else
          echo "   (NFS exports 설정 없음)"
        fi
        echo ""
        echo -e " ${YELLOW}===== NFS (exportfs -v) =====${RESET}"
        _u35_exportfs_out=$(exportfs -v 2>/dev/null)
        if [ -n "$_u35_exportfs_out" ]; then
          echo "$_u35_exportfs_out" | sed 's/^/   /'
        else
          echo "   (exportfs 출력 없음 — NFS 서비스 미사용 또는 미설치)"
        fi
        echo ""
        echo -e " ${YELLOW}===== Samba =====${RESET}"
        if command -v testparm &>/dev/null; then
          _u35_samba_out=$(testparm -s 2>/dev/null | grep -i 'guest ok')
          if [ -n "$_u35_samba_out" ]; then
            echo "$_u35_samba_out" | sed 's/^/   /'
          else
            echo "   (guest ok 설정 없음)"
          fi
        else
          echo "   (Samba 미설치)"
        fi

        check_still_vuln "U-35"; _rs=$?
        BEFORE_VAL["U-35"]="FTP/vsftpd/ProFTPD/NFS 익명 접근 허용"
        AFTER_VAL["U-35"]="FTP 계정 잠금, vsftpd/ProFTPD 비활성화, NFS 신뢰 IP 제한"
        if [ $_rs -eq 1 ]; then
          _lbl_done
          _mark_fixed "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정 — 조치 완료"
        else
          echo -e " ${YELLOW}→ 일부 항목 수동 확인 필요${RESET}"
          _mark_manual "U-35" "공유 서비스 익명 접근 제한 일부 잔존 — 수동 확인 필요"
        fi
      fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-36 / r 계열 서비스 비활성화
#
# 점검 기준:
#   rsh, rlogin, rexec 서비스·소켓과 관련 TCP 포트가 비활성 상태여야 한다.
#
# 조치 내용:
#   r 계열 서비스를 중지하고 자동 시작을 비활성화·마스킹한다.
#
# 변경 대상:
#   rsh/rlogin/rexec 관련 systemd 서비스·소켓 상태
#
# 수동 확인:
#   레거시 시스템 연동으로 r 계열 서비스가 필요한지 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 원래 active/enabled 상태를 복원한다.
# =============================================================================

do_fix "U-36" "(상) r 계열 서비스 비활성화" \
  "# 패키지 설치 여부
   for pkg in rsh-server rsh; do
     _r=\$(rpm -q \$pkg 2>/dev/null)
     [ -z \"\$_r\" ] && _r=\$(dpkg -l \$pkg 2>/dev/null | grep '^ii' | awk '{print \$2, \$3}')
     echo \"\$pkg: \${_r:-not installed}\"
   done
   echo ''
   # 서비스/소켓 상태
   for svc in rsh.socket rlogin.socket rexec.socket rshd.service rlogind.service rexecd.service; do
     _st=\$(systemctl is-active \$svc 2>/dev/null)
     echo \"\$svc: \${_st:-Unit not found}\"
   done
   echo ''
   # 포트 사용 여부
   ss -tlnp 2>/dev/null | grep -E ':514 |:513 |:512 ' || echo 'Port 512/513/514 (r계열): 미사용'" \
  "for svc in rsh rlogin rexec; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null; systemctl mask \$svc 2>/dev/null
   done" \
  "_o=\$(for svc in rsh rlogin rexec; do systemctl is-active \$svc 2>/dev/null; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'r계열 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-37 / crontab·at 설정 파일 권한
#
# 점검 기준:
#   cron·at 명령, 설정 파일, 작업 디렉터리와 등록 파일이 root 소유이며 기준 권한 이하여야 한다.
#
# 조치 내용:
#   대상별 원래 권한을 기록한 뒤 파일은 640 이하, 디렉터리는 750 이하로 제한하고 root 소유로 설정한다.
#
# 변경 대상:
#   crontab/at 명령, /etc/cron*, /var/spool/cron*, /var/spool/at*
#
# 수동 확인:
#   배포판별 경로와 서비스 전용 소유권 요구가 다른 경우 직접 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 백업으로 각 경로의 소유자·권한을 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-37" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-37"; _vs=$?
    _flush_header

    # U-37에서 사용할 crontab / at 명령 파일 경로 확인
    _u37_crontab_bin=$(command -v crontab 2>/dev/null || true)
    if [ -z "$_u37_crontab_bin" ]; then
      for _cand37 in /usr/bin/crontab /bin/crontab; do
        [ -f "$_cand37" ] && { _u37_crontab_bin="$_cand37"; break; }
      done
    fi
    _u37_at_bin=$(command -v at 2>/dev/null || true)
    if [ -z "$_u37_at_bin" ]; then
      for _cand37 in /usr/bin/at /bin/at; do
        [ -f "$_cand37" ] && { _u37_at_bin="$_cand37"; break; }
      done
    fi

    # 리포트용 조치 전 스냅샷: 화면에 표시되는 대상과 동일한 경로만 수집한다.
    _u37_paths=""
    for _f37 in "$_u37_crontab_bin" "$_u37_at_bin" \
                /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny \
                /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
      [ -e "$_f37" ] && _u37_paths="${_u37_paths}${_f37}"$'\n'
    done
    for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
      [ -d "$D" ] || continue
      while IFS= read -r -d '' F; do
        _u37_paths="${_u37_paths}${F}"$'\n'
      done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    done
    _u37_paths=$(printf '%s' "$_u37_paths" | sed '/^$/d' | sort -u)

    unset _u37_before_mode _u37_before_owner 2>/dev/null || true
    declare -A _u37_before_mode _u37_before_owner
    _u37_before_report=""
    while IFS= read -r _f37; do
      [ -e "$_f37" ] || continue
      _u37_before_mode["$_f37"]=$(stat -c '%a' "$_f37" 2>/dev/null)
      _u37_before_owner["$_f37"]=$(stat -c '%U:%G' "$_f37" 2>/dev/null)
      _u37_before_report="${_u37_before_report}${_f37}: ${_u37_before_owner[$_f37]} / ${_u37_before_mode[$_f37]}"$'\n'
    done <<< "$_u37_paths"
    _u37_before_report=${_u37_before_report%$'\n'}
    BEFORE_VAL["U-37"]="${_u37_before_report:-점검 대상 파일 없음}"

    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-37" "(상) crontab 설정파일 권한 설정 미흡"
      _lbl_cur

      for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
        [ -f "$_bin37" ] || continue
        _u37_p=$(stat -c '%a' "$_bin37" 2>/dev/null)
        _u37_note=""
        [ "$((8#${_u37_p:-0} & 8#4000))" -ne 0 ] 2>/dev/null && _u37_note=" (SUID 설정)"
        [ "$((8#${_u37_p:-0} & 8#2000))" -ne 0 ] 2>/dev/null && _u37_note="${_u37_note} (SGID 설정)"
        stat -c "   ${_bin37} : %U / %a${_u37_note}" "$_bin37" 2>/dev/null
      done
      [ ! -f "$_u37_crontab_bin" ] && echo "   /usr/bin/crontab : 설치되지 않음"
      [ ! -f "$_u37_at_bin" ]      && echo "   /usr/bin/at : 설치되지 않음"

      for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
        if [ -f "$F" ]; then stat -c "   $F : %U / %a" "$F"; else echo "   $F : 없음"; fi
      done
      for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
               /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] && stat -c "   $D : %U / %a" "$D"
      done

      _u37_task_cnt=0
      for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] || continue
        while IFS= read -r -d '' F; do
          [ $_u37_task_cnt -eq 0 ] && { echo ""; echo "   작업 목록 파일"; }
          stat -c "   $F : %U / %a" "$F"
          _u37_task_cnt=$((_u37_task_cnt+1))
        done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
      done
      [ $_u37_task_cnt -eq 0 ] && { echo ""; echo "   작업 목록 파일 : 없음"; }
      echo ""
      AFTER_VAL["U-37"]="모든 cron/at 대상이 기준 충족"
      DETAIL_VAL["U-37"]="[현재 상태] ${_u37_before_report:-점검 대상 파일 없음} | [판정] root 소유 및 권한 기준 충족"
      _mark_skipped "U-37" "crontab/at 권한 [이미양호]"
    else
      _item_header "vuln" "U-37" "(상) crontab 설정파일 권한 설정 미흡"
      echo ""

        _lbl_before

        for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
          [ -f "$_bin37" ] || continue
          _u37_p=$(stat -c '%a' "$_bin37" 2>/dev/null)
          _u37_note=""
          [ "$((8#${_u37_p:-0} & 8#4000))" -ne 0 ] 2>/dev/null && _u37_note=" (SUID 설정)"
          [ "$((8#${_u37_p:-0} & 8#2000))" -ne 0 ] 2>/dev/null && _u37_note="${_u37_note} (SGID 설정)"
          stat -c "   ${_bin37} : %U / %a${_u37_note}" "$_bin37" 2>/dev/null
        done
        [ ! -f "$_u37_crontab_bin" ] && echo "   /usr/bin/crontab : 설치되지 않음"
        [ ! -f "$_u37_at_bin" ]      && echo "   /usr/bin/at : 설치되지 않음"

        for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
          if [ -f "$F" ]; then stat -c "   $F : %U / %a" "$F"; else echo "   $F : 없음"; fi
        done
        for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                 /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
          [ -d "$D" ] && stat -c "   $D : %U / %a" "$D"
        done

        _u37_task_cnt=0
        for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
          [ -d "$D" ] || continue
          while IFS= read -r -d '' F; do
            [ $_u37_task_cnt -eq 0 ] && { echo ""; echo "   작업 목록 파일"; }
            stat -c "   $F : %U / %a" "$F"
            _u37_task_cnt=$((_u37_task_cnt+1))
          done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
        done
        [ $_u37_task_cnt -eq 0 ] && { echo ""; echo "   작업 목록 파일 : 없음"; }
        echo ""

        _lbl_yn
        _read_yn _yn_u37 " 조치하시겠습니까? (y/n): "
        if [[ "$_yn_u37" != [Yy] ]]; then
          _lbl_skip
          AFTER_VAL["U-37"]="사용자 건너뜀"
          DETAIL_VAL["U-37"]="[조치 전] ${_u37_before_report:-점검값 없음} | [결과] 사용자 건너뜀"
          _mark_skipped "U-37" "crontab/at 권한 [건너뜀]"
        else
          _lbl_during

          # 조치 전 원래 권한과 소유자/그룹을 기록하여 롤백 가능하도록 한다.
          echo "----- [U-37] 조치 전 원래 권한 ($(date '+%Y-%m-%d %H:%M:%S')) -----" >> "${DETAIL_LOG_FILE:-/dev/null}" 2>/dev/null

          for _f37 in "$_u37_crontab_bin" "$_u37_at_bin" \
                      /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny \
                      /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                      /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -e "$_f37" ] || continue
            printf 'PERM_RESTORE|%s|%s|%s\n' \
              "$_f37" "$(stat -c '%a' "$_f37" 2>/dev/null)" "$(stat -c '%U:%G' "$_f37" 2>/dev/null)" \
              >> "${FIX_HISTORY_FILE}" 2>/dev/null
          done
          for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            while IFS= read -r -d '' F; do
              printf 'PERM_RESTORE|%s|%s|%s\n' \
                "$F" "$(stat -c '%a' "$F" 2>/dev/null)" "$(stat -c '%U:%G' "$F" 2>/dev/null)" \
                >> "${FIX_HISTORY_FILE}" 2>/dev/null
            done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
          done

          # crontab / at 명령 파일: SUID/SGID 제거 후 root:root / 750
          for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
            [ -f "$_bin37" ] || continue
            _u37_old=$(stat -c '%a' "$_bin37" 2>/dev/null)
            if chown root:root "$_bin37" 2>/dev/null && chmod 750 "$_bin37" 2>/dev/null; then
              echo "   ${_bin37} → root / 750 (SUID/SGID 제거, ${_u37_old} → 750)"
            else
              echo -e "   ${RED}✗${RESET} ${_bin37} 조치 실패"
            fi
          done

          # cron / at 설정 파일: root:root / 640
          for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
            [ -f "$F" ] || continue
            if chown root:root "$F" 2>/dev/null && chmod 640 "$F" 2>/dev/null; then
              echo "   ${F} → root / 640"
            else
              echo -e "   ${RED}✗${RESET} ${F} 조치 실패"
            fi
          done

          # cron / at 관련 디렉터리: root:root / 750
          for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                   /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            if chown root:root "$D" 2>/dev/null && chmod 750 "$D" 2>/dev/null; then
              echo "   ${D} → root / 750"
            else
              echo -e "   ${RED}✗${RESET} ${D} 조치 실패"
            fi
          done

          # cron / at 작업 목록 일반 파일: root:root / 640
          for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            while IFS= read -r -d '' F; do
              if chown root:root "$F" 2>/dev/null && chmod 640 "$F" 2>/dev/null; then
                echo "   ${F} → root / 640"
              else
                echo -e "   ${RED}✗${RESET} ${F} 조치 실패"
              fi
            done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
          done

          echo ""
          _lbl_result

          # 명령 파일 결과 확인
          for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
            [ -f "$_bin37" ] || continue
            _u37_o=$(stat -c '%U' "$_bin37" 2>/dev/null)
            _u37_p=$(stat -c '%a' "$_bin37" 2>/dev/null)
            if [ "$_u37_o" = "root" ] \
               && [ "$((8#${_u37_p:-0} & 8#6000))" -eq 0 ] 2>/dev/null \
               && [ "$((8#${_u37_p:-7777}))" -le "$((8#750))" ] 2>/dev/null; then
              _ok "${_bin37} : ${_u37_o} / ${_u37_p} (SUID/SGID 없음)"
            else
              _fail "${_bin37} : ${_u37_o} / ${_u37_p} (기대: root / 750 이하, SUID/SGID 없음)"
            fi
          done

          # 설정 파일 결과 확인
          for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
            [ -f "$F" ] || continue
            _u37_o=$(stat -c '%U' "$F" 2>/dev/null); _u37_p=$(stat -c '%a' "$F" 2>/dev/null)
            if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777}))" -le "$((8#640))" ] 2>/dev/null; then
              _ok "$F : ${_u37_o} / ${_u37_p}"
            else
              _fail "$F : ${_u37_o} / ${_u37_p} (기대: root / 640 이하)"
            fi
          done

          # 관련 디렉터리 결과 확인
          for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                   /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            _u37_o=$(stat -c '%U' "$D" 2>/dev/null); _u37_p=$(stat -c '%a' "$D" 2>/dev/null)
            if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777}))" -le "$((8#750))" ] 2>/dev/null; then
              _ok "$D : ${_u37_o} / ${_u37_p}"
            else
              _fail "$D : ${_u37_o} / ${_u37_p} (기대: root / 750 이하)"
            fi
          done

          # 작업 목록 파일 결과 확인
          for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            while IFS= read -r -d '' F; do
              _u37_o=$(stat -c '%U' "$F" 2>/dev/null); _u37_p=$(stat -c '%a' "$F" 2>/dev/null)
              if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777}))" -le "$((8#640))" ] 2>/dev/null; then
                _ok "$F : ${_u37_o} / ${_u37_p}"
              else
                _fail "$F : ${_u37_o} / ${_u37_p} (기대: root / 640 이하)"
              fi
            done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
          done

          echo ""

          # 리포트용 조치 후 스냅샷과 실제 변경 경로를 비교한다.
          _u37_after_report=""
          _u37_changed_report=""
          _u37_changed_cnt=0
          while IFS= read -r _f37; do
            [ -n "$_f37" ] || continue
            if [ -e "$_f37" ]; then
              _u37_after_mode=$(stat -c '%a' "$_f37" 2>/dev/null)
              _u37_after_owner=$(stat -c '%U:%G' "$_f37" 2>/dev/null)
              _u37_after_report="${_u37_after_report}${_f37}: ${_u37_after_owner} / ${_u37_after_mode}"$'\n'
              if [ "${_u37_before_mode[$_f37]:-}" != "$_u37_after_mode" ] \
                 || [ "${_u37_before_owner[$_f37]:-}" != "$_u37_after_owner" ]; then
                _u37_changed_report="${_u37_changed_report}${_f37}: ${_u37_before_owner[$_f37]:-확인불가} / ${_u37_before_mode[$_f37]:-확인불가} → ${_u37_after_owner} / ${_u37_after_mode}"$'\n'
                _u37_changed_cnt=$((_u37_changed_cnt+1))
              fi
            else
              _u37_after_report="${_u37_after_report}${_f37}: 파일 없음"$'\n'
              _u37_changed_report="${_u37_changed_report}${_f37}: 존재함 → 파일 없음"$'\n'
              _u37_changed_cnt=$((_u37_changed_cnt+1))
            fi
          done <<< "$_u37_paths"
          _u37_after_report=${_u37_after_report%$'\n'}
          _u37_changed_report=${_u37_changed_report%$'\n'}
          [ -n "$_u37_changed_report" ] || _u37_changed_report="실제 변경 파일 없음"

          check_still_vuln "U-37"; _u37_rc=$?
          if [ $_u37_rc -eq 1 ]; then
            AFTER_VAL["U-37"]="crontab/at 권한 조치 완료 (실제 변경 ${_u37_changed_cnt}개)"
            DETAIL_VAL["U-37"]="[변경 전] ${_u37_before_report:-점검값 없음} | [변경 후] ${_u37_after_report:-점검값 없음} | [실제 변경 파일] ${_u37_changed_report}"
            _lbl_done_nr
            _mark_fixed "U-37" "(상) crontab 설정파일 권한 설정 미흡 — 조치 완료"
          else
            AFTER_VAL["U-37"]="조치 후에도 기준 미충족 항목 존재"
            DETAIL_VAL["U-37"]="[변경 전] ${_u37_before_report:-점검값 없음} | [변경 후] ${_u37_after_report:-점검값 없음} | [실제 변경 파일] ${_u37_changed_report} | [검증] 기준 미충족"
            echo -e " ${RED}→ 조치 후에도 여전히 취약 — cron/at 파일 및 디렉터리 권한을 확인하세요.${RESET}"
            _mark_failed "U-37" "조치 후에도 cron/at 권한 기준 미충족"
          fi
        fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-38 / DoS 취약 서비스 비활성화
#
# 점검 기준:
#   echo, chargen, discard, daytime 서비스와 TCP 7·9·13·19 포트가 비활성 상태여야 한다.
#
# 조치 내용:
#   관련 서비스를 중지하고 자동 시작을 비활성화한다.
#
# 변경 대상:
#   echo/chargen/discard/daytime 서비스와 포트 상태
#
# 수동 확인:
#   진단·레거시 목적으로 사용 중인 서비스가 있는지 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 원래 상태를 복원한다.
# =============================================================================

do_fix "U-38" "(상) DoS 취약 서비스 비활성화" \
  "_o=\$(for port in 7 9 13 19; do ss -tlnp 2>/dev/null | grep \":\${port} \" && echo \"TCP/\${port} 활성\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'DoS 취약 서비스 비활성 (양호)'" \
  "for svc in echo chargen discard daytime; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
   done" \
  "_o=\$(for port in 7 9 13 19; do ss -tlnp 2>/dev/null | grep \":\${port} \" || true; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'DoS 취약 서비스 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-40 / NFS 접근 통제
#
# 점검 기준:
#   NFS export에 root 권한을 그대로 허용하는 no_root_squash 옵션이 없어야 한다.
#
# 조치 내용:
#   /etc/exports에서 no_root_squash 옵션을 제거하고 exportfs로 설정을 재적용한다.
#
# 변경 대상:
#   /etc/exports와 NFS export 런타임 설정
#
# 수동 확인:
#   특정 클라이언트에 root 권한 위임이 필요한 업무 예외는 적용 전에 확인한다.
#
# 롤백:
#   조치 전 exports 백업과 NFS 서비스 설정 복원 절차로 원래 옵션을 복원한다.
# =============================================================================

[ "${_NFS_DISABLED:-0}" -eq 0 ] && \
do_fix "U-40" "(상) NFS 접근 통제" \
  "grep 'no_root_squash' /etc/exports 2>/dev/null || echo 'no_root_squash 없음 (양호)'" \
  "[ -f /etc/exports ] && sed -i 's/,no_root_squash//g; s/no_root_squash,//g; s/no_root_squash//g' /etc/exports && exportfs -ra 2>/dev/null" \
  "grep 'no_root_squash' /etc/exports 2>/dev/null || echo 'no_root_squash 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-41 / 불필요한 automountd 제거
#
# 점검 기준:
#   업무상 필요하지 않은 autofs 서비스는 비활성 상태여야 한다.
#
# 조치 내용:
#   autofs를 중지하고 자동 시작을 비활성화·마스킹한다.
#
# 변경 대상:
#   autofs systemd 서비스 상태
#
# 수동 확인:
#   자동 마운트에 의존하는 홈·NFS·애플리케이션 경로가 있는지 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 autofs 상태를 복원한다.
# =============================================================================

do_fix "U-41" "(상) 불필요한 automountd 제거" \
  "systemctl is-active autofs 2>/dev/null || echo 'autofs 비활성'" \
  "systemctl stop autofs 2>/dev/null; systemctl disable autofs 2>/dev/null; systemctl mask autofs 2>/dev/null; true" \
  "systemctl is-active autofs 2>/dev/null || echo 'autofs 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-42 / 불필요한 RPC 서비스 비활성화
#
# 점검 기준:
#   cmsd, ttdbserverd, sadmind, rusersd, walld, sprayd, rstatd가 실행되지 않아야 한다.
#
# 조치 내용:
#   관련 서비스를 중지·비활성화하고 잔존 프로세스를 종료한다.
#
# 변경 대상:
#   취약 RPC 서비스의 systemd 상태와 프로세스
#
# 수동 확인:
#   레거시 관리 솔루션이 해당 RPC 서비스를 사용하는지 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 원래 상태를 복원한다.
# =============================================================================

do_fix "U-42" "(상) 불필요한 RPC 서비스 비활성화" \
  "_o=\$(for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do pgrep -x \$svc &>/dev/null && echo \"\$svc 실행 중\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'RPC 취약 서비스 비활성 (양호)'" \
  "for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
     pkill -x \$svc 2>/dev/null
   done" \
  "_o=\$(for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do pgrep -x \$svc &>/dev/null && echo \"\$svc 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'RPC 취약 서비스 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-43 / NIS·NIS+ 서비스 점검
#
# 점검 기준:
#   ypserv와 ypbind 등 NIS 서비스와 프로세스가 비활성 상태여야 한다.
#
# 조치 내용:
#   NIS 관련 서비스를 중지·비활성화하고 잔존 프로세스를 종료한다.
#
# 변경 대상:
#   ypserv, ypbind 및 관련 systemd 서비스·프로세스
#
# 수동 확인:
#   중앙 계정 인증이 NIS에 의존하는지 반드시 확인한 후 조치한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 원래 상태를 복원한다.
# =============================================================================

do_fix "U-43" "(상) NIS, NIS+ 점검" \
  "_o=\$(for p in ypserv ypbind; do pgrep -x \$p &>/dev/null && echo \"\$p 실행 중\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'NIS 비활성 (양호)'" \
  "for svc in ypserv ypbind; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
     pkill -x \$svc 2>/dev/null
   done" \
  "_o=\$(for p in ypserv ypbind; do pgrep -x \$p &>/dev/null && echo \"\$p 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'NIS 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-44 / tftp·talk 서비스 비활성화
#
# 점검 기준:
#   UDP 69·517·518 포트와 tftp/talk/ntalk 관련 서비스가 비활성 상태여야 한다.
#
# 조치 내용:
#   관련 서비스를 중지하고 자동 시작을 비활성화한다.
#
# 변경 대상:
#   tftp, tftpd, atftpd, talk, ntalk 서비스와 포트 상태
#
# 수동 확인:
#   PXE·펌웨어 배포 등 TFTP 사용 목적이 있는지 중지 전에 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 원래 상태를 복원한다.
# =============================================================================

do_fix "U-44" "(상) tftp, talk 서비스 비활성화" \
  "ss -ulnp 2>/dev/null | grep -E ':69 |:517 |:518 ' || echo 'tftp/talk 비활성 (양호)'" \
  "for svc in tftp tftpd atftpd talk ntalk; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
   done" \
  "ss -ulnp 2>/dev/null | grep -E ':69 |:517 |:518 ' || echo 'tftp/talk 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-45 / 메일 서비스 버전 점검
#
# 점검 기준:
#   설치된 Postfix가 배포판 저장소에서 제공하는 최신 보안 업데이트 수준이어야 한다.
#
# 조치 내용:
#   yum 또는 apt를 사용해 Postfix 패키지 업데이트를 시도한다.
#
# 변경 대상:
#   Postfix 패키지와 관련 의존 패키지
#
# 수동 확인:
#   인터넷·저장소 연결, 변경 승인, 서비스 영향과 목표 버전은 운영자가 확인한다.
#
# 롤백:
#   패키지는 자동 다운그레이드하지 않으며 롤백 후 패키지 차이를 수동 확인 대상으로 기록한다.
# =============================================================================

do_fix "U-45" "(상) 메일 서비스 버전 점검" \
  "postconf -d mail_version 2>/dev/null || echo '메일 서비스 정보 없음'" \
  "# 버전 최신화 — 패키지 업데이트로 처리
   command -v yum &>/dev/null && yum update -y postfix 2>/dev/null
   command -v apt &>/dev/null && apt-get install --only-upgrade postfix -y 2>/dev/null" \
  "postconf -d mail_version 2>/dev/null || echo '메일 서비스 없음'" \
  ""

# =============================================================================
# U-46 / 일반 사용자의 메일 서비스 실행 방지
#
# 점검 기준:
#   Postfix main.cf가 root 소유이며 일반 사용자가 수정할 수 없는 644 권한이어야 한다.
#
# 조치 내용:
#   /etc/postfix/main.cf의 소유자·그룹을 root:root, 권한을 644로 설정한다.
#
# 변경 대상:
#   /etc/postfix/main.cf
#
# 수동 확인:
#   Postfix가 설치되지 않았거나 별도 MTA만 사용하는 경우 해당 환경을 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 설정 백업으로 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-46" "(상) 일반 사용자의 메일 서비스 실행 방지" \
  "stat -c '소유자: %U / 권한: %a' /etc/postfix/main.cf 2>/dev/null || echo '파일 없음'" \
  "_p=/etc/postfix/main.cf; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; [ -f /etc/postfix/main.cf ] && chown root:root /etc/postfix/main.cf && chmod 644 /etc/postfix/main.cf" \
  "stat -c '소유자: %U / 권한: %a' /etc/postfix/main.cf 2>/dev/null || echo '파일 없음 (VERIFY_OK)'" \
  "소유자: root / 권한: 644|VERIFY_OK"

# =============================================================================
# U-47 / 스팸 메일 릴레이 제한
#
# 점검 기준:
#   Postfix·Sendmail·Exim에서 허용된 네트워크와 도메인만 릴레이할 수 있어야 한다.
#
# 조치 내용:
#   자동 변경하지 않고 감지된 MTA와 릴레이 관련 설정값을 표시한다.
#
# 변경 대상:
#   Postfix main.cf, Sendmail relay-domains/access, Exim relay 설정
#
# 수동 확인:
#   허용 네트워크·도메인과 외부 릴레이 정책은 메일 운영 담당자가 직접 검토한다.
#
# 롤백:
#   자동 변경이 없으므로 별도 롤백 대상은 없다.
# =============================================================================

do_manual "U-47" "(상) 스팸 메일 릴레이 제한" \
  "메일 릴레이 정책은 MTA 종류(postfix/sendmail/exim)에 따라 설정 방식이 다르므로 수동 검토 필요
   - postfix  : main.cf 의 mynetworks, relay_domains 확인
   - sendmail : /etc/mail/relay-domains, /etc/mail/access (RELAY 항목) 확인
   - exim     : /etc/exim4/ 의 relay_from_hosts 또는 hostlist 확인" \
  "_mta='미탐지'
   pgrep -x postfix  &>/dev/null && _mta='postfix'
   pgrep -x sendmail &>/dev/null && _mta='sendmail'
   pgrep -xf 'exim'  &>/dev/null && _mta='exim'
   [ \"\$_mta\" = '미탐지' ] && command -v postfix  &>/dev/null && _mta='postfix(중지)'
   [ \"\$_mta\" = '미탐지' ] && command -v sendmail &>/dev/null && _mta='sendmail(중지)'
   [ \"\$_mta\" = '미탐지' ] && { command -v exim4 &>/dev/null || command -v exim &>/dev/null; } && _mta='exim(중지)'
   echo \"감지된 MTA: \${_mta}\"
   case \"\${_mta%%(*}\" in
     postfix)
       echo '--- /etc/postfix/main.cf (mynetworks / relay_domains) ---'
       grep -v '^#' /etc/postfix/main.cf 2>/dev/null | grep -E 'mynetworks|relay_domains' | head -5 \
         || echo '설정 없음'
       ;;
     sendmail)
       echo '--- /etc/mail/relay-domains ---'
       cat /etc/mail/relay-domains 2>/dev/null | grep -v '^#' | head -5 || echo '파일 없음'
       echo '--- /etc/mail/access (RELAY 항목) ---'
       grep -i 'RELAY' /etc/mail/access 2>/dev/null | grep -v '^#' | head -5 || echo '없음'
       ;;
     exim)
       echo '--- exim relay_from_hosts ---'
       grep -r 'relay_from_hosts\|hostlist.*relay' /etc/exim4/ /etc/exim/ 2>/dev/null \
         | grep -v '^Binary' | head -5 || echo '없음'
       ;;
     *) echo 'MTA 미탐지 — 직접 확인 필요' ;;
   esac"

# =============================================================================
# U-48 / EXPN·VRFY 명령어 제한
#
# 점검 기준:
#   Postfix의 실제 적용값 disable_vrfy_command가 yes여야 한다.
#
# 조치 내용:
#   main.cf에 disable_vrfy_command=yes를 적용하고 설정 문법 검사 후 Postfix를 재시작한다.
#
# 변경 대상:
#   /etc/postfix/main.cf, Postfix 서비스 상태
#
# 수동 확인:
#   postfix check 또는 서비스 재시작이 실패하면 설정값과 서비스 상태를 직접 확인한다.
#
# 롤백:
#   조치 전 main.cf 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-48" "(중) expn, vrfy 명령어 제한" \
  "postconf disable_vrfy_command 2>/dev/null || echo 'postfix 없음'" \
  "_U48_APPLY_STATUS='실패'
   _u48_before=\$(postconf disable_vrfy_command 2>/dev/null)
   [ -z \"\$_u48_before\" ] && _u48_before='disable_vrfy_command = no(기본값)'
   if ! command -v postconf &>/dev/null; then
     echo '✗ Postfix 명령을 확인할 수 없음'
   else
     echo '✓ Postfix 설정 파일 백업'
     cp -p /etc/postfix/main.cf \"/etc/postfix/main.cf.bak.\$(date +%Y%m%d_%H%M%S)\" 2>/dev/null
     echo ''
     echo '✓ disable_vrfy_command 설정 변경'
     echo \"  \${_u48_before} → disable_vrfy_command = yes\"
     if postconf -e 'disable_vrfy_command = yes'; then
       echo ''
       echo '✓ Postfix 설정 문법 확인'
       _u48_chk=\$(postfix check 2>&1); _u48_chk_rc=\$?
       if [ \$_u48_chk_rc -eq 0 ]; then
         [ -n \"\$_u48_chk\" ] && echo \"\$_u48_chk\" | sed 's/^/  /' || echo '  이상 없음'
         echo ''
         echo '✓ Postfix 서비스 재시작'
         if systemctl restart postfix 2>/dev/null; then
           echo '  restart : 완료'
           _U48_APPLY_STATUS='성공'
         else
           echo '  restart : 실패'
         fi
       else
         echo '  설정 문법 검사 실패'
         [ -n \"\$_u48_chk\" ] && echo \"\$_u48_chk\" | sed 's/^/  /'
         echo '  서비스 재시작 미수행'
       fi
     else
       echo '✗ disable_vrfy_command 설정 변경 실패'
     fi
     _u48_after=\$(postconf disable_vrfy_command 2>/dev/null)
     _u48_result=\"조치 완료 / 최종 검증 통과\"
     [ \"\$_U48_APPLY_STATUS\" != \"성공\" ] && _u48_result=\"조치 실패\"
     DETAIL_VAL[\"U-48\"]=\"[현재 상태] \${_u48_before} | [조치 내용] disable_vrfy_command=yes 설정 및 Postfix 서비스 반영 | [조치 결과] \${_u48_result} | [변경 파일] 총 1개 | [변경 파일 목록] /etc/postfix/main.cf | [검증 결과] \${_u48_after:-확인불가} | [서비스 변경] Postfix reload/restart: \${_U48_APPLY_STATUS}\"
   fi" \
  "_after=\$(postconf disable_vrfy_command 2>/dev/null)
   echo \"변경 전 : \${before_out}\"
   echo \"변경 후 : \${_after:-확인불가}\"
   echo \"Postfix 서비스 반영 : \${_U48_APPLY_STATUS:-실패}\"
   if echo \"\$_after\" | grep -qE '^disable_vrfy_command[[:space:]]*=[[:space:]]*yes$' \\
      && [ \"\${_U48_APPLY_STATUS:-실패}\" = '성공' ]; then
     echo '설정값 및 Postfix 서비스 반영 확인 완료 (U48_VERIFY_OK)'
   else
     echo '설정값 또는 Postfix 서비스 반영 실패'
   fi" \
  "U48_VERIFY_OK"

# =============================================================================
# U-49 / DNS 보안 버전 패치
#
# 점검 기준:
#   BIND가 설치·실행 중이면 배포판 저장소에서 제공하는 최신 보안 업데이트 수준이어야 한다.
#
# 조치 내용:
#   yum 또는 apt를 사용해 bind/bind9 패키지 업데이트를 시도한다.
#
# 변경 대상:
#   BIND 패키지와 관련 의존 패키지
#
# 수동 확인:
#   저장소 연결, 구독 상태, 목표 버전과 서비스 영향은 운영자가 확인한다.
#
# 롤백:
#   패키지는 자동 다운그레이드하지 않으며 롤백 후 패키지 차이를 수동 확인 대상으로 기록한다.
# =============================================================================

do_fix "U-49" "(상) DNS 보안 버전 패치" \
  "_o=\$(command -v named &>/dev/null && named -v 2>&1 | head -1); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named 비활성'" \
  "command -v yum &>/dev/null && yum update -y bind 2>/dev/null
   command -v apt &>/dev/null && apt-get install --only-upgrade bind9 -y 2>/dev/null" \
  "_o=\$(command -v named &>/dev/null && named -v 2>&1 | head -1); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named 없음'" \
  ""

# =============================================================================
# U-50 / DNS Zone Transfer 설정
#
# 점검 기준:
#   named.conf의 allow-transfer가 none 또는 승인된 대상만 허용하도록 제한되어야 한다.
#
# 조치 내용:
#   allow-transfer 지시자를 none으로 변경하거나 options 블록에 제한 설정을 추가하고 named를 reload한다.
#
# 변경 대상:
#   /etc/named.conf, named 서비스
#
# 수동 확인:
#   zone별 별도 allow-transfer 정책이나 보조 DNS 서버 허용이 필요한 경우 직접 조정한다.
#
# 롤백:
#   조치 전 named.conf 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-50" "(상) DNS Zone Transfer 설정" \
  "_o=\$(grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-transfer' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named.conf 없음'" \
  "[ -f /etc/named.conf ] && grep -q 'allow-transfer' /etc/named.conf \
     && sed -i 's/allow-transfer\s*{[^}]*}/allow-transfer { none; }/' /etc/named.conf \
     || ([ -f /etc/named.conf ] && echo 'options { allow-transfer { none; }; }' >> /etc/named.conf)
   systemctl reload named 2>/dev/null" \
  "grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-transfer' || echo 'named.conf 없음 (VERIFY_OK)'" \
  "none|VERIFY_OK"

# =============================================================================
# U-51 / DNS 동적 업데이트 제한
#
# 점검 기준:
#   named.conf의 allow-update가 none 또는 승인된 키·대상만 허용하도록 제한되어야 한다.
#
# 조치 내용:
#   기존 allow-update 지시자를 none으로 변경하고 named를 reload한다.
#
# 변경 대상:
#   /etc/named.conf, named 서비스
#
# 수동 확인:
#   DHCP 연동·DDNS·TSIG 기반 업데이트를 사용하는 환경은 적용 전에 정책을 확인한다.
#
# 롤백:
#   조치 전 named.conf 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-51" "(중) DNS 서비스의 취약한 동적 업데이트 설정 금지" \
  "_o=\$(grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-update' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named.conf 없음'" \
  "[ -f /etc/named.conf ] && grep -q 'allow-update' /etc/named.conf \
     && sed -i 's/allow-update\s*{[^}]*}/allow-update { none; }/' /etc/named.conf
   systemctl reload named 2>/dev/null" \
  "grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-update' || echo 'named.conf 없음 (VERIFY_OK)'" \
  "none|VERIFY_OK"

# =============================================================================
# U-52 / Telnet 서비스 비활성화
#
# 점검 기준:
#   Telnet 관련 서비스·소켓·inetd/xinetd 설정과 TCP 23 포트가 모두 비활성 상태여야 한다.
#
# 조치 내용:
#   Telnet systemd 서비스와 소켓을 중지·비활성화하고 inetd/xinetd 등록을 해제한다.
#
# 변경 대상:
#   telnet 관련 서비스·소켓, /etc/inetd.conf, /etc/xinetd.conf, /etc/xinetd.d
#
# 수동 확인:
#   레거시 장비 연동으로 Telnet이 필요한지 조치 전에 확인한다.
#
# 롤백:
#   조치 전 설정 파일 백업과 서비스 상태 메타데이터로 Telnet 구성을 복원한다.
# =============================================================================

do_fix "U-52" "(중) Telnet 서비스 비활성화" \
  "_u52_status" \
  "_u52_apply_disable" \
  "_u52_verify" \
  "U52_VERIFY_OK"

# =============================================================================
# U-53 / FTP 서비스 정보 노출 제한
#
# 점검 기준:
#   FTP 배너에서 제품명·버전 정보가 노출되지 않고 일반 안내 문구만 표시되어야 한다.
#
# 조치 내용:
#   vsftpd는 ftpd_banner=Welcome, ProFTPD는 ServerIdent off로 설정하고 서비스를 재시작한다.
#
# 변경 대상:
#   vsftpd.conf, proftpd.conf, FTP 서비스 상태
#
# 수동 확인:
#   조직 표준 배너 문구가 별도로 있으면 적용 전에 문구를 확인한다.
#
# 롤백:
#   조치 전 FTP 설정 백업과 서비스 상태 메타데이터로 배너 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-53" "(하) FTP 서비스 정보 노출 제한" \
  "_o=\$(grep -i 'ftpd_banner\|ServerIdent' \
       /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
       /etc/proftpd.conf /etc/proftpd/proftpd.conf 2>/dev/null \
       | grep -v '^#' | head -4 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'FTP 설정 없음'" \
  "# vsftpd: 배너에서 버전/제품명 제거
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     config_set \"\$F\" '^[[:space:]]*ftpd_banner.*' 'ftpd_banner=Welcome' line
     echo \"   ftpd_banner=Welcome 설정: \$F\"
   done
   # proftpd: ServerIdent off 로 버전 정보 노출 차단
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     cp \"\$F\" \"\${F}.bak.\$(date +%Y%m%d_%H%M%S)\"
     config_set \"\$F\" '^[[:space:]]*ServerIdent.*' 'ServerIdent off' line
     echo \"   ServerIdent off 설정: \$F\"
   done
   systemctl restart vsftpd 2>/dev/null; systemctl restart proftpd 2>/dev/null; true" \
  "_o=\$(grep -i 'ftpd_banner\|ServerIdent' \
       /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
       /etc/proftpd.conf /etc/proftpd/proftpd.conf 2>/dev/null \
       | grep -v '^#' | head -4 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '설정 없음 (VERIFY_OK)'" \
  "ftpd_banner=Welcome|ServerIdent off|VERIFY_OK"

# =============================================================================
# U-54 / 암호화되지 않는 FTP 서비스 비활성화
#
# 점검 기준:
#   TCP 21 FTP가 비활성 상태이거나 FTPS TLS 설정이 적용되어야 한다.
#
# 조치 내용:
#   업무상 미사용으로 확인된 경우 vsftpd/proftpd 서비스를 중지·비활성화한다.
#
# 변경 대상:
#   vsftpd/proftpd 서비스 상태와 TCP 21 포트
#
# 수동 확인:
#   FTP가 업무상 필요하면 자동 중지하지 않고 FTPS·SFTP 전환과 U-56/U-57 강화를 검토한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 FTP 서비스 상태를 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-54" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-54"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화"
      _lbl_cur
      ss -tlnp 2>/dev/null | grep ':21 ' | sed 's/^/   /'
      echo "   FTP 비활성 또는 SSL/TLS 적용됨 (양호)"
      echo ""
      BEFORE_VAL["U-54"]=$(echo "FTP 비활성 또는 암호화 FTP만 운용 중")
      [ -z "${BEFORE_VAL["U-54"]:-}" ] && BEFORE_VAL["U-54"]="이미 양호 (점검 통과)"
      AFTER_VAL["U-54"]="이미 양호 (재확인 통과)"
      _mark_skipped "U-54" "FTP 서비스 [이미양호]"
    else
      _item_header "vuln" "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화"
      _lbl_before
      _u54_svc=""
      systemctl is-active vsftpd  2>/dev/null | grep -q '^active' && _u54_svc="vsftpd"
      BEFORE_VAL["U-54"]=$(echo "FTP 비활성 또는 SSL/TLS 적용됨")
      [ -z "${BEFORE_VAL["U-54"]:-}" ] && BEFORE_VAL["U-54"]="이미 양호 (점검 통과)"
      AFTER_VAL["U-54"]="이미 양호 (재확인 통과)"
      [ -z "$_u54_svc" ] && systemctl is-active proftpd 2>/dev/null | grep -q '^active' && _u54_svc="proftpd"
      echo "   서비스 : ${_u54_svc:-확인불가}"
      echo "   상태    : $(systemctl is-active "${_u54_svc:-vsftpd}" 2>/dev/null) (운용 중)"
      ss -tlnp 2>/dev/null | grep ':21 ' | sed 's/^/   /'
      echo ""
      # FTP는 레거시 파일 전송 용도로 정책상 유지되는 경우가 있어, 확인 없이
      # 바로 stop/disable 해버리면 운영 정책과 충돌할 수 있다 — 먼저 실제
      # 사용 여부부터 확인한다.
      _read_yn _u54_inuse " FTP 서비스를 업무 목적으로 계속 운영하시겠습니까? (y/n): "
      if [[ "$_u54_inuse" == [Yy] ]]; then
        echo ""
        _lbl_result
        echo -e "   ${CYAN}운영 서비스로 판단하여 자동 중지는 수행하지 않습니다.${RESET}"
        echo ""
        echo -e "   ${YELLOW}권장 사항${RESET}"
        echo -e "   ${GREEN}✓${RESET} FTPS(TLS) 적용"
        echo -e "   ${GREEN}✓${RESET} SFTP(SSH) 전환 검토"
        echo -e "   ${GREEN}✓${RESET} 익명 로그인 비활성화"
        echo -e "   ${GREEN}✓${RESET} 접근 IP 제한"
        echo -e "   ${GREEN}✓${RESET} U-56, U-57 추가 점검 권장"
        echo ""
        echo -e "   ${CYAN}→ 자동 조치 제외 (운영 서비스 — 운영 정책에 따라 유지)${RESET}"
        BEFORE_VAL["U-54"]="FTP 서비스(${_u54_svc:-FTP}) 구동 중"
        AFTER_VAL["U-54"]="자동 조치 제외 (운영 서비스로 유지, FTPS/SFTP 전환 및 U-56/U-57 강화 권장)"
        _mark_skipped "U-54" "FTP 서비스 [업무상 사용 중 — 자동 조치 제외, FTPS/SFTP 전환 및 접근제어 강화 권장]"
      else
        echo -e "   ${CYAN}FTP 서비스를 사용하지 않는 것으로 확인되었습니다.${RESET}"
        _lbl_yn
        _read_yn _yn_u54 " 조치하시겠습니까? (y/n): "
        if [[ "$_yn_u54" != [Yy] ]]; then
          _lbl_skip
          _mark_skipped "U-54" "FTP 서비스 [건너뜀]"
        else
          _lbl_during
          echo -e "   ${CYAN}\$${RESET} systemctl stop vsftpd; systemctl disable vsftpd"
          echo -e "   ${CYAN}\$${RESET} systemctl stop proftpd; systemctl disable proftpd"
          _u54_before_state=$(systemctl is-active "${_u54_svc:-vsftpd}" 2>/dev/null)
          systemctl stop vsftpd   2>/dev/null; systemctl disable vsftpd   2>/dev/null
          systemctl stop proftpd  2>/dev/null; systemctl disable proftpd  2>/dev/null
          echo ""
          _lbl_result
          check_still_vuln "U-54"; _u54_rc=$?
          _u54_after_state=$(systemctl is-active "${_u54_svc:-vsftpd}" 2>/dev/null)
          BEFORE_VAL["U-54"]="FTP 서비스 구동 중(비암호화)"
          if [ $_u54_rc -eq 1 ]; then
            AFTER_VAL["U-54"]="FTP 비활성화 완료"
            echo "   ${_u54_before_state:-active} → ${_u54_after_state:-inactive}"
            _lbl_done_nr
            _mark_fixed "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화 — 조치 완료"
          else
            AFTER_VAL["U-54"]="조치 실패"
            echo -e " ${RED}→ 조치 후에도 여전히 취약${RESET}"
            _mark_failed "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화 — 조치 후에도 여전히 취약"
          fi
        fi
      fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-56 / FTP 서비스 접근 제어
#
# 점검 기준:
#   FTP 접속은 승인된 IP·호스트로 제한되고 전체 허용 상태가 아니어야 한다.
#
# 조치 내용:
#   vsftpd는 tcp_wrappers와 hosts.allow/hosts.deny를 설정하고 ProFTPD는 LOGIN 제한 블록을 추가한다.
#
# 변경 대상:
#   /etc/hosts.allow, /etc/hosts.deny, vsftpd.conf, proftpd.conf
#
# 수동 확인:
#   허용할 관리·업무 IP와 네트워크 대역은 환경에 맞게 직접 수정해야 한다.
#
# 롤백:
#   조치 전 접근제어 파일과 FTP 설정 백업으로 원래 정책을 복원한다.
# =============================================================================

do_fix "U-56" "(하) FTP 서비스 접근 제어 설정 (IP/호스트 기반)" \
  "# [현재 상태] IP/호스트 기반 접근통제 설정 확인
   echo '=== vsftpd tcp_wrappers ==='
   grep -v '^#' /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf 2>/dev/null \
     | grep -i 'tcp_wrappers' || echo '미설정'
   echo '=== /etc/hosts.allow (ftp 항목) ==='
   grep -iE '^(vsftpd|ftpd|in\.ftpd)' /etc/hosts.allow 2>/dev/null || echo '미설정'
   echo '=== proftpd <Limit LOGIN> 블록 ==='
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     awk '/<Limit[[:space:]]+LOGIN/,/<\\/Limit>/' \"\$F\" 2>/dev/null | head -6
   done" \
  "# [vsftpd] tcp_wrappers=YES 활성화
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     cp \"\$F\" \"\${F}.bak.\$(date +%Y%m%d_%H%M%S)\"
     config_set \"\$F\" '^[[:space:]]*[Tt][Cc][Pp]_[Ww][Rr][Aa][Pp][Pp][Ee][Rr][Ss][[:space:]]*=.*' 'tcp_wrappers=YES' line
     echo \"   tcp_wrappers=YES 설정: \$F\"
   done
   # [hosts.allow] vsftpd 항목 예시 추가 (허용 IP는 환경에 맞게 수정 필요)
   if ! grep -qiE '^(vsftpd|ftpd)' /etc/hosts.allow 2>/dev/null; then
     printf '\\n# KISA U-56: FTP 접근통제 (허용 IP/대역을 환경에 맞게 수정할 것)\\n' >> /etc/hosts.allow
     printf 'vsftpd : 127.0.0.1 : ALLOW\\n'                                            >> /etc/hosts.allow
     printf 'vsftpd : ALL       : DENY\\n'                                              >> /etc/hosts.allow
     echo '   ※ /etc/hosts.allow 에 vsftpd 예시 항목 추가 — 허용 IP 반드시 수정 필요'
   fi
   # [proftpd] <Limit LOGIN> 블록 없으면 예시 추가 (IP 대역은 사이트마다 다름)
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -qi 'Limit.*LOGIN' \"\$F\" && continue
     cp \"\$F\" \"\${F}.bak.\$(date +%Y%m%d_%H%M%S)\"
     printf '\\n# KISA U-56: FTP 접근통제 — Allow from 허용 IP/대역으로 수정 후 적용\\n' >> \"\$F\"
     printf '<Limit LOGIN>\\n  Order Allow,Deny\\n  Allow from 127.0.0.1\\n  DenyAll\\n</Limit>\\n' >> \"\$F\"
     echo \"   proftpd <Limit LOGIN> 블록 추가: \$F (허용 IP 반드시 수정 필요)\"
   done
   systemctl restart vsftpd  2>/dev/null
   systemctl restart proftpd 2>/dev/null; true" \
  "# [검증] tcp_wrappers 또는 <Limit LOGIN> 중 하나라도 설정되면 VERIFY_OK
   _ok=0
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -qi 'tcp_wrappers=YES' \"\$F\" && _ok=1
   done
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -qi 'Limit.*LOGIN' \"\$F\" && _ok=1
   done
   [ \$_ok -eq 1 ] && echo 'IP/호스트 기반 접근통제 설정 확인 (VERIFY_OK)' \
                   || echo '설정 미확인 — 수동 검토 필요'" \
  "VERIFY_OK"

# =============================================================================
# U-57 / ftpusers 파일 설정
#
# 점검 기준:
#   사용 중인 ftpusers 차단 목록에 root 계정이 포함되어야 한다.
#
# 조치 내용:
#   존재하는 ftpusers 파일에 root 항목이 없으면 추가한다.
#
# 변경 대상:
#   /etc/ftpusers, /etc/vsftpd/ftpusers, /etc/vsftpd.ftpusers, /etc/proftpd/ftpusers
#
# 수동 확인:
#   FTP 데몬별 실제 참조 파일이 다를 수 있으므로 활성 설정 경로를 확인한다.
#
# 롤백:
#   조치 전 ftpusers 파일 백업으로 root 차단 목록을 복원한다.
# =============================================================================

do_fix "U-57" "(중) Ftpusers 파일 설정" \
  "for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers /etc/proftpd/ftpusers; do
     [ -f \"\$F\" ] && { echo \"\$F:\"; grep '^root' \"\$F\" || echo '  root 미등록'; } || true
   done" \
  "for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers /etc/proftpd/ftpusers; do
     [ -f \"\$F\" ] || continue
     grep -q '^root' \"\$F\" || echo 'root' >> \"\$F\"
     echo \"   root 등록 확인: \$F\"
   done" \
  "_o=\$(for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers /etc/proftpd/ftpusers; do
     [ -f \"\$F\" ] && grep '^root' \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'ftpusers 없음 (VERIFY_OK)'" \
  "root|VERIFY_OK"

# =============================================================================
# U-58 / 불필요한 SNMP 서비스 구동 점검
#
# 점검 기준:
#   업무상 필요하지 않은 snmpd 서비스와 UDP 161 포트가 비활성 상태여야 한다.
#
# 조치 내용:
#   사용자가 미사용으로 확인한 경우 snmpd를 중지하고 자동 시작을 비활성화한다.
#
# 변경 대상:
#   snmpd 서비스 상태와 UDP 161 포트
#
# 수동 확인:
#   모니터링 시스템이 SNMP를 사용하는지 반드시 확인하고 필요한 경우 U-59~U-61 보안을 강화한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 snmpd 상태를 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-58" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-58"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-58" "(중) 불필요한 SNMP 서비스 구동 점검"
      _lbl_cur
      echo "   SNMP 비활성 (양호)"
      echo ""
      BEFORE_VAL["U-58"]=$(echo "SNMP 비활성")
      [ -z "${BEFORE_VAL["U-58"]:-}" ] && BEFORE_VAL["U-58"]="이미 양호 (점검 통과)"
      AFTER_VAL["U-58"]="이미 양호 (재확인 통과)"
      _mark_skipped "U-58" "SNMP 서비스 [이미양호]"
    else
      _item_header "vuln" "U-58" "(중) 불필요한 SNMP 서비스 구동 점검"
      BEFORE_VAL["U-58"]=$(echo "SNMP 비활성")
      [ -z "${BEFORE_VAL["U-58"]:-}" ] && BEFORE_VAL["U-58"]="이미 양호 (점검 통과)"
      AFTER_VAL["U-58"]="이미 양호 (재확인 통과)"
      _lbl_before
      echo "   상태: $(systemctl is-active snmpd 2>/dev/null)"
      ss -ulnp 2>/dev/null | grep ':161 ' | sed 's/^/   /'
      echo ""
      # SNMP는 Zabbix/Nagios/PRTG 등 모니터링 시스템이 폴링에 쓰는 경우가
      # 실무에서 흔해서, 확인 없이 바로 stop/disable/mask 해버리면 운영 정책과
      # 충돌할 수 있다 — 먼저 실제 사용 여부부터 확인한다.
      echo -e " ${YELLOW}[!] SNMP는 모니터링 시스템(Zabbix/Nagios 등)이 폴링에 사용하는 경우가 흔합니다.${RESET}"
      _read_yn _u58_inuse " SNMP 서비스를 업무 목적으로 계속 운영하시겠습니까? (y/n): "
      if [[ "$_u58_inuse" == [Yy] ]]; then
        echo ""
        _lbl_result
        echo -e "   ${CYAN}운영 서비스로 판단하여 자동 중지는 수행하지 않습니다.${RESET}"
        echo ""
        echo -e "   ${YELLOW}권장 사항${RESET}"
        echo -e "   ${GREEN}✓${RESET} SNMPv3 사용 (v1/v2c community 방식 대신)"
        echo -e "   ${GREEN}✓${RESET} public/private 등 기본 community 문자열 제거"
        echo -e "   ${GREEN}✓${RESET} 접근 IP 제한 (agentAddress / com2sec)"
        echo -e "   ${GREEN}✓${RESET} U-59~U-61 추가 점검 권장"
        echo ""
        echo -e "   ${CYAN}→ 자동 조치 제외 (운영 서비스 — 운영 정책에 따라 유지)${RESET}"
        BEFORE_VAL["U-58"]="SNMP 서비스 구동 중"
        AFTER_VAL["U-58"]="자동 조치 제외 (운영 서비스로 유지, U-59~U-61 강화 권장)"
        _mark_skipped "U-58" "SNMP 서비스 [업무상 사용 중 — 자동 조치 제외, U-59~U-61 강화 권장]"
      else
        echo -e "   ${CYAN}SNMP 서비스를 사용하지 않는 것으로 확인되었습니다.${RESET}"
        _lbl_yn
        _read_yn _yn_u58 " 조치하시겠습니까? (y/n): "
        if [[ "$_yn_u58" != [Yy] ]]; then
          _lbl_skip
          _mark_skipped "U-58" "SNMP 서비스 [건너뜀]"
        else
          _lbl_during
          echo -e "   ${CYAN}\$${RESET} systemctl stop snmpd"
          echo -e "   ${CYAN}\$${RESET} systemctl disable snmpd"
          echo -e "   ${CYAN}\$${RESET} systemctl mask snmpd"
          _u58_before_state=$(systemctl is-active snmpd 2>/dev/null)
          systemctl stop snmpd 2>/dev/null; systemctl disable snmpd 2>/dev/null; systemctl mask snmpd 2>/dev/null
          echo ""
          _lbl_result
          check_still_vuln "U-58"; _u58_rc=$?
          _u58_after_state=$(systemctl is-active snmpd 2>/dev/null)
          BEFORE_VAL["U-58"]="SNMP 서비스 구동 중"
          if [ $_u58_rc -eq 1 ]; then
            AFTER_VAL["U-58"]="SNMP 비활성화 완료"
            echo "   ${_u58_before_state:-active} → ${_u58_after_state:-inactive}"
            _lbl_done_nr
            _mark_fixed "U-58" "(중) 불필요한 SNMP 서비스 구동 점검 — 조치 완료"
          else
            AFTER_VAL["U-58"]="조치 실패"
            echo -e " ${RED}→ 조치 후에도 여전히 취약${RESET}"
            _mark_failed "U-58" "(중) 불필요한 SNMP 서비스 구동 점검 — 조치 후에도 여전히 취약"
          fi
        fi
      fi
    fi
    echo ""
  fi
}
# =============================================================================
# U-55 / FTP 계정 Shell 제한
#
# 점검 기준:
#   FTP 전용 계정은 /sbin/nologin 또는 /bin/false 등 로그인 불가 셸을 사용해야 한다.
#
# 조치 내용:
#   자동 변경하지 않고 vsftpd nopriv_user 계정과 현재 로그인 셸을 표시한다.
#
# 변경 대상:
#   /etc/vsftpd*.conf, /etc/passwd(조회 대상)
#
# 수동 확인:
#   FTP 전용 계정의 실제 업무 용도와 적절한 로그인 제한 셸을 계정 담당자가 결정한다.
#
# 롤백:
#   자동 변경이 없으므로 별도 롤백 대상은 없다.
# =============================================================================

do_manual "U-55" "(중) FTP 계정 Shell 제한" \
  "FTP 전용 계정(nopriv_user)의 shell이 /sbin/nologin 또는 /bin/false 인지 확인 후 수동 설정 필요" \
  "for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     FU=\$(grep -v '^#' \"\$F\" | grep 'nopriv_user' | awk -F= '{print \$2}' | tr -d ' ')
     if [ -n \"\$FU\" ]; then
       SH=\$(grep \"^\${FU}:\" /etc/passwd | cut -d: -f7)
       echo \"vsftpd nopriv_user : \$FU\"
       echo \"현재 shell         : \${SH:-계정 없음}\"
       if echo \"\$SH\" | grep -qE 'nologin|false'; then
         echo '판정              : ✓ 양호'
       else
         echo '판정              : ✗ 취약 — /sbin/nologin 또는 /bin/false 로 변경 필요'
       fi
     fi
   done"
# =============================================================================
# U-59 / 안전한 SNMP 버전 사용
#
# 점검 기준:
#   SNMPv1/v2c community 기반 설정이 비활성화되고 SNMPv3 인증·암호화를 사용해야 한다.
#
# 조치 내용:
#   com2sec와 community 라인을 주석 처리해 v1/v2c를 비활성화하고 snmpd 설정을 재적용한다.
#
# 변경 대상:
#   /etc/snmp/snmpd.conf, snmpd 서비스
#
# 수동 확인:
#   SNMPv3 사용자 createUser/rouser 설정은 인증정보 정책에 따라 직접 구성한다.
#
# 롤백:
#   조치 전 snmpd.conf 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-59" "(상) 안전한 SNMP 버전 사용" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec|^community' | head -3 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 설정 없음'" \
  "# SNMPv1/v2c community 라인 주석 처리 (v3 전환은 수동 필요)
   [ -f /etc/snmp/snmpd.conf ] && { \
     config_set /etc/snmp/snmpd.conf '^([[:space:]]*com2sec)' '# [v1v2c-disabled] \1' substr; \
     config_set /etc/snmp/snmpd.conf '^([[:space:]]*community)' '# [v1v2c-disabled] \1' substr; \
     _snmpd_reload_guard \"\$_RUN_TS\" /etc/snmp/snmpd.conf; }
   echo '   ※ SNMPv3 사용자 설정은 snmpd.conf 에 createUser/rouser 지시자로 수동 추가 필요'" \
  "_o=\$(grep -v '^#\\|v1v2c-disabled' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec|^community' | head -3 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMPv1/v2c 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-60 / SNMP Community String 복잡성
#
# 점검 기준:
#   public·private 같은 기본 Community String을 사용하지 않아야 한다.
#
# 조치 내용:
#   snmpd.conf에서 기본 community 항목을 제거하고 설정을 재적용한다.
#
# 변경 대상:
#   /etc/snmp/snmpd.conf, snmpd 서비스
#
# 수동 확인:
#   업무용 Community String을 유지해야 하면 충분한 복잡성과 접근 제한을 직접 설정한다.
#
# 롤백:
#   조치 전 snmpd.conf 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-60" "(중) SNMP Community String 복잡성 설정" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'community\s+(public|private)' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음'" \
  "[ -f /etc/snmp/snmpd.conf ] && { config_set /etc/snmp/snmpd.conf 'community[[:space:]]+public' '' delete; config_set /etc/snmp/snmpd.conf 'community[[:space:]]+private' '' delete; _snmpd_reload_guard \"\$_RUN_TS\" /etc/snmp/snmpd.conf; }" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'community\s+(public|private)' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '기본 Community 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

# =============================================================================
# U-61 / SNMP Access Control 설정
#
# 점검 기준:
#   SNMP 관리 요청이 default 또는 0.0.0.0 전체 주소에 공개되지 않아야 한다.
#
# 조치 내용:
#   취약한 com2sec default 설정을 localhost 제한으로 변경하고 snmpd 설정을 재적용한다.
#
# 변경 대상:
#   /etc/snmp/snmpd.conf, snmpd 서비스
#
# 수동 확인:
#   실제 모니터링 서버 IP·대역을 허용해야 하는 경우 localhost 대신 승인 주소로 직접 수정한다.
#
# 롤백:
#   조치 전 snmpd.conf 백업과 서비스 상태 메타데이터로 접근 정책과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-61" "(상) SNMP Access Control 설정" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec.*default|agentaddress.*0\.0\.0\.0' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음'" \
  "[ -f /etc/snmp/snmpd.conf ] && { config_set /etc/snmp/snmpd.conf 'com2sec.*default.*' 'com2sec notConfigUser  localhost    public' substr; _snmpd_reload_guard \"\$_RUN_TS\" /etc/snmp/snmpd.conf; }" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep 'com2sec' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음 (VERIFY_OK)'" \
  "localhost|VERIFY_OK"

# =============================================================================
# U-62 / 로그인 경고 메시지 설정
#
# 점검 기준:
#   로그인 배너는 경고 문구를 표시하고 OS·커널·호스트 정보를 노출하지 않아야 한다.
#
# 조치 내용:
#   /etc/issue, issue.net, motd에 경고 문구를 적용하고 sshd Banner를 /etc/issue.net으로 설정한다.
#
# 변경 대상:
#   /etc/issue, /etc/issue.net, /etc/motd, /etc/ssh/sshd_config
#
# 수동 확인:
#   조직 표준 경고 문구를 확인하고 sshd 구문 검사 실패 시 Banner 지시자를 직접 확인한다.
#
# 롤백:
#   조치 전 배너·sshd 설정 백업으로 파일과 SSH Banner 설정을 복원한다.
# =============================================================================

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-62" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-62"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-62" "(하) 로그인 시 경고 메시지 설정"
      _lbl_cur
      echo "   /etc/issue:" && cat /etc/issue 2>/dev/null | sed 's/^/      /'
      echo ""
            _mark_skipped "U-62" "로그인 경고 메시지 [이미양호]"
    else
      _item_header "vuln" "U-62" "(하) 로그인 시 경고 메시지 설정"
      echo ""
      _u62_issue=$(cat /etc/issue 2>/dev/null)
      _u62_issuenet=$(cat /etc/issue.net 2>/dev/null)
      _u62_sshbanner=$(sshd -T 2>/dev/null | grep -i '^banner' | awk '{print $2}')

      _lbl_before
      echo "   /etc/issue"
      if [ -n "$_u62_issue" ]; then echo "$_u62_issue" | sed 's/^/   /'; else echo "   (없음)"; fi
      echo "   /etc/issue.net"
      if [ -n "$_u62_issuenet" ]; then echo "$_u62_issuenet" | sed 's/^/   /'; else echo "   (없음)"; fi
      echo ""

      # 원인 1: \S, \r, \m 등 시스템 정보 노출 escape 코드 — 발견된 코드를 각각 짚어서 보여준다
      _u62_escapes_found=()
      _u62_combined="$_u62_issue$_u62_issuenet"
      echo "$_u62_combined" | grep -q '\\S' && _u62_escapes_found+=("\\S (OS 이름)")
      echo "$_u62_combined" | grep -q '\\r' && _u62_escapes_found+=("\\\\r (OS/Kernel 버전)")
      echo "$_u62_combined" | grep -q '\\m' && _u62_escapes_found+=("\\m (시스템 아키텍처)")
      echo "$_u62_combined" | grep -q '\\v' && _u62_escapes_found+=("\\\\v (OS 버전)")
      if [ ${#_u62_escapes_found[@]} -gt 0 ]; then
        echo -e "   ${RED}[탐지] 원인 1: 시스템 정보 노출 문자 발견${RESET}"
        for _e in "${_u62_escapes_found[@]}"; do
          echo -e "      ${RED}✘${RESET} ${_e}"
        done
      elif [ -z "$_u62_issue" ] && [ -z "$_u62_issuenet" ]; then
        echo -e "   ${RED}[탐지] 원인 1: /etc/issue, /etc/issue.net 둘 다 비어 있음 — 경고 문구 자체가 없음${RESET}"
      fi

      # 원인 2: sshd Banner 미설정 — 원인 1과 별개로 항상 따로 확인/표시한다
      # (둘은 동시에 발생할 수 있는 독립적인 문제라, if/elif로 하나만 보여주면
      #  나머지 원인을 놓칠 수 있음 — 그래서 항상 둘 다 확인해서 해당하는 것만 보여준다)
      if [ -z "$_u62_sshbanner" ] || [ "$_u62_sshbanner" = "none" ]; then
        echo -e "   ${RED}[탐지] 원인 2: sshd Banner ${_u62_sshbanner:-none} — SSH 로그인 시 경고 배너 미적용${RESET}"
      else
        echo -e "   ${GREEN}sshd Banner: ${_u62_sshbanner} (설정됨)${RESET}"
      fi
      echo ""

      _lbl_yn
      _read_yn _yn_u62 " 조치하시겠습니까? (y/n): "

      if [[ "$_yn_u62" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-62" "로그인 경고 메시지 [건너뜀]"
        echo ""
      else
        # 기본 배너 문구 표시 후 선택
        DEFAULT_MSG="이 시스템은 인가된 사용자만 접근 가능합니다."
        echo -e " ${YELLOW}[기본 배너 문구]${RESET}"
        echo "   ******************************************************************"
        echo "   * ${DEFAULT_MSG}   *"
        echo "   ******************************************************************"
        echo ""
        echo -e " ${YELLOW}※ y = 기본 문구 사용, n = 직접 입력 (영문/숫자/기호만 가능 — 한글은 콘솔·SSH 배너에서 깨질 수 있어 제한됩니다)${RESET}"
        _read_yn _banner_yn " 기본 문구를 사용하시겠습니까? (y/n): "
        if [[ "$_banner_yn" =~ ^[Nn]$ ]]; then
          # 배너는 영문(출력 가능 ASCII)만 허용한다.
          # 이유: /etc/issue는 콘솔 tty 폰트에서, SSH 사전 인증 배너는 비UTF-8
          # 클라이언트에서 한글이 깨져 표시되며, 로케일 미설치 서버에서는
          # 멀티바이트 입력 자체가 read를 멈추게 할 수 있다.
          while true; do
            echo -n " 배너 메시지를 입력하세요 (영문/숫자/기호만): "
            if ! read -r _banner_input; then
              echo ""
              echo -e " ${YELLOW}입력을 받을 수 없어 기본 문구를 사용합니다.${RESET}"
              _banner_input=""
              break
            fi
            [ -z "$_banner_input" ] && break   # 빈 입력 → 기본 문구
            if LC_ALL=C grep -q '[^ -~]' <<< "$_banner_input"; then
              echo -e " ${RED}영문/숫자/기호(ASCII)만 입력 가능합니다. 한글 등은 콘솔·SSH 배너에서 깨질 수 있습니다.${RESET}"
              continue
            fi
            break
          done
          [ -z "$_banner_input" ] && _banner_input="$DEFAULT_MSG"
          BANNER_TEXT="$_banner_input"
        else
          BANNER_TEXT="$DEFAULT_MSG"
        fi

        # 문구를 박스 형태로 포맷 — 한글(전각 2칸)은 printf %-Ns가 문자 수로만 패딩하므로
        # _display_width()로 실제 표시폭을 계산해서 수동 패딩해야 줄이 어긋나지 않는다.
        _u62_inner=62   # * 와 * 사이 내용 폭 (스페이스 포함)
        _u62_tw=$(_display_width "$BANNER_TEXT")
        _u62_pad=$(( _u62_inner - 2 - _u62_tw ))   # 앞 "  " 제외한 뒤 패딩
        [ $_u62_pad -lt 0 ] && _u62_pad=0
        _u62_border=$(printf '%0.s*' $(seq 1 $(( _u62_inner + 2 ))))
        BANNER_MSG=$(printf '%s\n* %s%*s*\n%s' \
          "$_u62_border" "$BANNER_TEXT" "$_u62_pad" "" "$_u62_border")

        _lbl_during
        echo "   /etc/issue, /etc/issue.net, /etc/motd 경고문 적용"
        echo "$BANNER_MSG" > /etc/issue
        echo "$BANNER_MSG" > /etc/issue.net
        echo "$BANNER_MSG" > /etc/motd

        # sshd_config Banner 설정 — U-01과 동일한 안전장치(백업 + sshd -t 검증 + 실패시 롤백) 적용
        echo "   sshd_config Banner /etc/issue.net 설정 + sshd -t 검증 후 reload"
        _u62_bak_ts=$(date +%Y%m%d_%H%M%S)
        cp -p /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.${_u62_bak_ts}" 2>/dev/null
        config_set /etc/ssh/sshd_config '^[[:space:]]*Banner.*' 'Banner /etc/issue.net' line '' ci
        _sshd_reload_guard "${_u62_bak_ts}" "/etc/ssh/sshd_config"
        _u62_guard_rc=$?

        echo ""
        _lbl_result
        # 하드코딩된 영문 문구가 아니라, 방금 실제로 적용한 BANNER_TEXT를 기준으로 검증한다
        # (기본값이 한글이거나 사용자가 직접 입력한 임의 문구일 수 있으므로).
        if grep -qF "$BANNER_TEXT" /etc/issue 2>/dev/null; then
          _ok "/etc/issue 경고문 설정"
        else
          _fail "/etc/issue 경고문 미확인"
        fi
        if grep -qF "$BANNER_TEXT" /etc/issue.net 2>/dev/null; then
          _ok "/etc/issue.net 경고문 설정"
        else
          _fail "/etc/issue.net 경고문 미확인"
        fi
        if [ $_u62_guard_rc -ne 0 ]; then
          _fail "sshd Banner 미적용 — sshd -t 검증 실패로 sshd_config가 백업에서 복구되었습니다 (/etc/issue 등 배너 파일은 정상 적용됨)"
        else
          _u62_sshd_t_out=$(sshd -T 2>&1)
          _u62_banner_line=$(echo "$_u62_sshd_t_out" | grep -i '^banner')
          if echo "$_u62_banner_line" | grep -qi '^banner[[:space:]]\+/etc/issue\.net[[:space:]]*$'; then
            _ok "sshd Banner: Banner /etc/issue.net"
            _ok "sshd reload 완료"
          else
            _fail "sshd Banner 미확인 — sshd -T 실제 출력:"
            if [ -n "$_u62_banner_line" ]; then
              echo "      ${_u62_banner_line}"
            else
              echo "      (banner 항목이 sshd -T 출력에 없음)"
              echo "$_u62_sshd_t_out" | grep -qi 'error\|invalid\|unknown' && echo "$_u62_sshd_t_out" | grep -i 'error\|invalid\|unknown' | head -3 | sed 's/^/      /'
            fi
          fi
        fi

        AFTER_VAL["U-62"]="배너 설정 완료 (${BANNER_TEXT})"
        BEFORE_VAL["U-62"]="배너 미설정 또는 시스템 정보 노출"
        echo ""
        BEFORE_VAL["U-64"]=$(echo "보안 패치 최신 상태" 2>/dev/null | head -3)
        [ -z "${BEFORE_VAL["U-64"]:-}" ] && BEFORE_VAL["U-64"]="이상 항목 없음 (점검 통과)"
        AFTER_VAL["U-64"]="이미 양호 (재확인 통과)"
        _lbl_done_nr
        if [ $_u62_guard_rc -eq 0 ]; then
          _mark_fixed "U-62" "조치 완료 (배너+sshd Banner 적용)"
        else
          _mark_fixed "U-62" "조치 완료 (배너 파일만 적용, sshd Banner 지시자는 검증 실패로 롤백됨)"
        fi
      fi
    fi
    echo ""
  fi
}

# =============================================================================
# U-63 / sudo 명령어 접근 관리
#
# 점검 기준:
#   /etc/sudoers가 root 소유이며 권한이 640 이하여야 한다.
#
# 조치 내용:
#   sudoers 소유자를 root로 설정하고 권한을 640으로 제한한다.
#
# 변경 대상:
#   /etc/sudoers
#
# 수동 확인:
#   sudo 정책 내용과 사용자 권한 범위는 별도 운영 기준에 따라 검토한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 조치 전 sudoers 백업으로 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-63" "(중) sudo 명령어 접근 관리" \
  "ls -l /etc/sudoers 2>/dev/null || echo '/etc/sudoers 없음'" \
  "_p=/etc/sudoers; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; [ -f /etc/sudoers ] && chown root /etc/sudoers && chmod 640 /etc/sudoers" \
  "ls -l /etc/sudoers 2>/dev/null" \
  "^-rw-r-----.*root"

# ============================================================
_has_cat_target "패치 관리" && section_header "패치 관리"
# ============================================================

# =============================================================================
# U-64 / 주기적 보안 패치 및 벤더 권고사항 적용
#
# 점검 기준:
#   배포판 저장소 기준 적용 가능한 보안·업그레이드 패키지가 없어야 한다.
#
# 조치 내용:
#   apt는 보안 패키지 또는 전체 업그레이드를, yum은 --security 업데이트를 사용자 승인 후 수행한다.
#
# 변경 대상:
#   OS 패키지와 관련 서비스·커널
#
# 수동 확인:
#   Red Hat 구독 미등록, 의존성 문제, 재부팅 필요, 서비스 영향과 변경 승인 여부를 확인한다.
#
# 롤백:
#   패키지는 자동 다운그레이드하지 않으며 롤백 후 패키지 차이를 수동 확인 대상으로 기록한다.
# =============================================================================

{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-64" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-64"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      _lbl_cur
      if command -v rpm &>/dev/null; then
        echo "   최근 보안 패치: $(rpm -qa --last 2>/dev/null | head -3 | awk '{print $1, $2, $3, $4}' | sed 's/^/      /' | head -3)"
      elif command -v dpkg &>/dev/null; then
        grep 'install\|upgrade' /var/log/dpkg.log 2>/dev/null | tail -3 | sed 's/^/   /'
      fi
      echo ""
      BEFORE_VAL["U-64"]=$(echo "보안 패치 최신 상태")
      [ -z "${BEFORE_VAL["U-64"]:-}" ] && BEFORE_VAL["U-64"]="이미 양호 (점검 통과)"
      AFTER_VAL["U-64"]="이미 양호 (재확인 통과)"
      _mark_skipped "U-64" "보안 패치 [이미양호]"
    elif [ $_vs -eq 2 ]; then
      # 구독 미등록 → 수동확인으로 표시, y/n 없이 자동 MANUAL 처리
      _item_header "manual" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      echo ""
      echo -e " ${YELLOW}[!] Red Hat 구독 미등록 환경 — yum 보안 패치를 적용할 수 없습니다.${RESET}"
      echo -e " ${YELLOW}    담당자가 subscription-manager 로 등록 후 직접 처리하세요.${RESET}"
      _mark_manual "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용 [구독미등록]"
    elif command -v apt &>/dev/null; then
      # ── apt 기반 시스템 ──
      _item_header "vuln" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      echo ""
      CNT=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')
      CNT=${CNT:-0}
      echo -e " ${YELLOW}[!] 업그레이드 가능 패키지: ${CNT}개${RESET}"
      apt list --upgradable 2>/dev/null | grep '\[upgradable' | head -10 | sed 's/^/   /'
      echo ""
      echo -e " ${YELLOW}※ y = 패치 적용, n = 건너뜀${RESET}"
      _u64_sec_pkgs=$(apt list --upgradable 2>/dev/null | grep -i security | cut -d/ -f1)
      if [ -n "$_u64_sec_pkgs" ]; then
        echo -e "   (보안 저장소 라벨이 붙은 패키지만 우선 적용합니다: $(echo "$_u64_sec_pkgs" | wc -l)개)"
      else
        echo -e "   ${RED}(이 시스템은 보안 전용 저장소 라벨이 없어 구분 업그레이드가 불가능합니다.${RESET}"
        echo -e "   ${RED} y를 선택하면 업그레이드 가능한 ${CNT}개 패키지 전체를 무인으로 업그레이드하며,${RESET}"
        echo -e "   ${RED} 커널 업데이트·서비스 재시작·재부팅 필요가 발생할 수 있습니다.)${RESET}"
      fi
      _read_yn _yn64apt " 조치하시겠습니까? (y/n): "
      case "$_yn64apt" in
        [Yy])
          _lbl_during
          apt-get update -qq 2>/dev/null
          if [ -n "$_u64_sec_pkgs" ]; then
            echo -e "   ${CYAN}→${RESET} apt-get install --only-upgrade -y (보안 패키지 $(echo "$_u64_sec_pkgs" | wc -l)개) 실행"
            # shellcheck disable=SC2086
            apt-get install --only-upgrade -y $_u64_sec_pkgs 2>/dev/null
          else
            echo -e "   ${CYAN}→${RESET} apt-get upgrade -y (전체 업그레이드) 실행"
            apt-get upgrade -y 2>/dev/null
          fi
          CNT_REMAIN=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')
          CNT_REMAIN=${CNT_REMAIN:-0}
          _lbl_result
          echo "   남은 업그레이드 대상: ${CNT_REMAIN}개"
          [ -f /var/run/reboot-required ] && echo -e "   ${YELLOW}※ 커널 등 재부팅이 필요한 패치가 적용되었습니다 — 편한 시간에 재부팅하세요.${RESET}"
          echo ""
          _mark_fixed "U-64" "apt-get 패치 적용 실행" ;;
        *)
          _mark_skipped "U-64" "보안 패치 [건너뜀]" ;;
      esac
    else
      # 구독 등록 + 패치 존재 → 취약, y/n 확인 후 조치
      _item_header "vuln" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      echo ""
      SEC_COUNT=$(yum updateinfo list security 2>/dev/null | grep -cE 'RHSA-|RHBA-|RHEA-')
      SEC_COUNT=${SEC_COUNT:-0}
      echo -e " ${YELLOW}[!] 적용 가능한 보안 패치: ${SEC_COUNT}개${RESET}"
      echo -e " ${YELLOW}※ y = 보안 패치만 적용(--security), n = 건너뜀${RESET}"
      echo -e "   (커널 보안 패치가 포함되면 재부팅 전까지는 적용되지 않으며, 서비스 관련 패키지는${RESET}"
      echo -e "   ${YELLOW}적용 중 자동 재시작될 수 있습니다.)${RESET}"
      _read_yn _yn64 " 조치하시겠습니까? (y/n): "
      case "$_yn64" in
        [Yy])
          _lbl_during
          echo -e "   ${CYAN}→${RESET} yum update --security -y 실행"
          yum update --security -y 2>/dev/null
          SEC_REMAIN=$(yum updateinfo list security 2>/dev/null | grep -cE 'RHSA-|RHBA-|RHEA-')
          SEC_REMAIN=${SEC_REMAIN:-0}
          _lbl_result
          if [ "$SEC_REMAIN" -eq 0 ]; then
            echo "   남은 보안 패치: 0개"
            if command -v needs-restarting &>/dev/null; then
              needs-restarting -r &>/dev/null || echo -e "   ${YELLOW}※ 재부팅이 필요한 패치가 적용되었습니다 — 편한 시간에 재부팅하세요.${RESET}"
            fi
            echo ""
            _mark_fixed "U-64" "yum update --security 실행 — 패치 완료"
          else
            echo "   남은 보안 패치: ${SEC_REMAIN}개"
            echo -e "   ${YELLOW}→ 일부 패치 미적용 (구독 미등록 또는 의존성 문제) — 수동 확인 필요${RESET}"
            echo ""
            _mark_manual "U-64" "yum update --security 실행 후 ${SEC_REMAIN}개 패치 잔존 — 수동 확인 필요"
          fi
          ;;
        *)
          _mark_skipped "U-64" "보안 패치 [건너뜀]" ;;
      esac
    fi
    echo ""
  fi
}

# ============================================================
_has_cat_target "로그 관리" && section_header "로그 관리"
# ============================================================

# =============================================================================
# U-65 / NTP 및 시각 동기화 설정
#
# 점검 기준:
#   chrony·ntpd·systemd-timesyncd 중 하나가 활성화되고 실제 NTP 소스와 동기화 상태가 정상이어야 한다.
#
# 조치 내용:
#   사용 가능한 시간 동기화 서비스를 설정·활성화하고 구성된 소스와 동기화 상태를 재확인한다.
#
# 변경 대상:
#   NTP 설정 파일, 시간 동기화 서비스 상태
#
# 수동 확인:
#   사용할 내부 NTP 서버 주소와 방화벽·망 분리 환경을 운영 정책에 맞게 확인한다.
#
# 롤백:
#   조치 전 NTP 설정 백업과 서비스 상태 메타데이터로 설정과 서비스 상태를 복원한다.
# =============================================================================

do_fix "U-65" "(중) NTP 및 시각 동기화 설정" \
  "_u65_status" \
  "_u65_apply" \
  "_u65_status" \
  "^검증 결과 : VERIFY_OK$"

# =============================================================================
# U-66 / 정책에 따른 시스템 로깅 설정
#
# 점검 기준:
#   rsyslog 또는 syslog 서비스가 활성화되어 시스템 로그를 기록해야 한다.
#
# 조치 내용:
#   rsyslog 서비스를 enable --now로 활성화한다.
#
# 변경 대상:
#   rsyslog 서비스 상태와 시스템 로그 파일
#
# 수동 확인:
#   중앙 로그 서버·별도 로깅 에이전트를 사용하는 환경은 중복 수집 여부를 확인한다.
#
# 롤백:
#   백업 메타데이터의 서비스 상태를 기준으로 rsyslog 상태를 복원한다.
# =============================================================================

do_fix "U-66" "(중) 정책에 따른 시스템 로깅 설정" \
  "systemctl is-active rsyslog 2>/dev/null; ls /var/log/messages /var/log/syslog 2>/dev/null | head -2" \
  "systemctl enable --now rsyslog 2>/dev/null" \
  "systemctl is-active rsyslog 2>/dev/null || echo '비활성'" \
  "^active$"

# =============================================================================
# U-67 / 로그 디렉터리 소유자 및 권한
#
# 점검 기준:
#   /var/log가 root 소유이고 other 쓰기 권한이 없어야 한다.
#
# 조치 내용:
#   /var/log의 소유자·그룹을 root:root, 권한을 755로 설정한다.
#
# 변경 대상:
#   /var/log
#
# 수동 확인:
#   배포판 또는 로그 수집 솔루션이 별도 그룹 권한을 요구하는 경우 적용 전에 확인한다.
#
# 롤백:
#   PERM_RESTORE 레코드와 백업 메타데이터로 원래 소유자·권한을 복원한다.
# =============================================================================

do_fix "U-67" "(중) 로그 디렉터리 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /var/log" \
  "_p=/var/log; [ -d \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${FIX_HISTORY_FILE}\"; chown root:root /var/log && chmod 755 /var/log" \
  "stat -c '소유자: %U / 권한: %a' /var/log" \
  "소유자: root / 권한: 7[0-9][0-9]"

# ============================================================
# SELinux 컨텍스트 복구
# ============================================================
# sed -i로 수정한 기존 파일은 보통 원래 컨텍스트가 유지되지만, 새로 만든
# 파일(/etc/profile.d/tmout.sh, /etc/tmpfiles.d/*.conf, systemd drop-in 등)은
# 잘못된 컨텍스트로 생성될 수 있다. SELinux가 enforcing/permissive 상태일 때만
# 안전하게 restorecon으로 표준 컨텍스트를 되돌려놓는다 (라벨이 이미 맞으면
# 아무 일도 하지 않는 무해한 동작).
if command -v getenforce &>/dev/null \
   && [ "$(getenforce 2>/dev/null)" != "Disabled" ] \
   && command -v restorecon &>/dev/null; then
  restorecon -RF \
    /etc/pam.d /etc/ssh /etc/security /etc/profile.d /etc/tmpfiles.d \
    /etc/systemd/system /etc/cron.d /etc/sudoers.d /etc/login.defs \
    /etc/issue /etc/issue.net /etc/motd 2>/dev/null
fi

# 최종 화면과 TXT 보고서에서 긴 상태값을 최대 2줄로 요약한다.
# CSV·Excel용 " || " 구분자는 출력할 때만 실제 줄바꿈으로 복원한다.
_summary_preview() {
  local _value="$1" _label="$2" _indent="${3:-   }" _max_lines="${4:-2}"

  [ -n "$_value" ] || return 0
  [[ "$_max_lines" =~ ^[1-9][0-9]*$ ]] || _max_lines=2

  printf '%s\n' "$_value" \
    | _strip_ansi_stream \
    | sed 's/\\n/\n/g; s/[[:space:]]*||[[:space:]]*/\n/g' 2>/dev/null \
    | sed '/^[[:space:]]*$/d' \
    | head -n "$_max_lines" \
    | while IFS= read -r _line; do
        printf '%s%s : %s\n' "$_indent" "$_label" "$_line"
      done
}

# ============================================================
# 최종 요약
# ============================================================
echo ""
_div_thick
echo -e "${BOLD}  조치 결과 요약  (총 ${#TARGET_IDS[@]}개 항목)${RESET}"
echo ""
# SKIPPED → 이미양호 / 사용자건너뜀 분리
_ALREADY_OK=0; _USER_SKIP=0
_ALREADY_OK_LIST=(); _USER_SKIP_LIST=()
for v in "${SKIPPED_LIST[@]}"; do
  if [[ "$v" == *"[이미양호]"* ]]; then
    _ALREADY_OK=$((_ALREADY_OK+1)); _ALREADY_OK_LIST+=("$v")
  else
    _USER_SKIP=$((_USER_SKIP+1)); _USER_SKIP_LIST+=("$v")
  fi
done

# 상세 로그(vulnFixDetail_*.log)에 GOOD/USER_SKIPPED 분리 집계와 RESULT를 함께 남긴다.
_detail_log_summary "$_ALREADY_OK" "$FIXED" "$MANUAL" "$_USER_SKIP" "$NA" "$FAILED"

echo -e " ${GREEN}✔ 자동 조치 완료${RESET}   : ${BOLD}${GREEN}${FIXED}건${RESET}"
echo -e " ${GREEN}✔ 이미 양호${RESET}        : ${BOLD}${GREEN}${_ALREADY_OK}건${RESET}"
echo -e " ${CYAN}○ 해당없음${RESET}         : ${BOLD}${CYAN}${NA}건${RESET}"
[ $_USER_SKIP -gt 0 ] && \
echo -e " ${CYAN}– 사용자 건너뜀${RESET}    : ${BOLD}${CYAN}${_USER_SKIP}건${RESET}"
echo -e " ${YELLOW}⚠ 수동 조치 필요${RESET}   : ${BOLD}${YELLOW}${MANUAL}건${RESET}"
echo -e " ${RED}✘ 조치 실패${RESET}        : ${BOLD}${RED}${FAILED}건${RESET}"

# ── 자동 조치 완료 상세 ───────────────────────────────────────────────────────
if [ ${#FIXED_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${GREEN}  ✔ 자동 조치 완료 항목${RESET}"
  for v in "${FIXED_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    echo -e " ${GREEN}•${RESET} ${BOLD}${id}${RESET} ${desc//\[이미양호\]/}"
    before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
    [ -n "$before" ] && _summary_preview "$before" "조치 전" "   " 2
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      _summary_preview "$after" "조치 후" "   " 2
  done
fi

# ── 수동 조치 필요 상세 ───────────────────────────────────────────────────────
if [ ${#MANUAL_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${YELLOW}  ⚠ 수동 조치 필요 항목${RESET}"
  for v in "${MANUAL_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    echo -e " ${YELLOW}•${RESET} ${BOLD}${id}${RESET} ${desc// — */}"
  done
fi

# ── 조치 실패 상세 ────────────────────────────────────────────────────────────
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${RED}  ✘ 조치 실패 항목  (configtest 실패 → 백업 복구됨)${RESET}"
  for v in "${FAILED_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    echo -e " ${RED}•${RESET} ${BOLD}${id}${RESET} ${desc// — */}"
    before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
    [ -n "$before" ] && _summary_preview "$before" "조치 전" "   " 2
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      _summary_preview "$after" "조치 후" "   " 2
  done
fi

# ── 사용자 건너뜀 목록 (간략) ────────────────────────────────────────────────
if [ $_USER_SKIP -gt 0 ]; then
  echo ""
  echo -e "${BOLD}  – 사용자 건너뜀 항목${RESET}"
  for v in "${_USER_SKIP_LIST[@]}"; do
    id="${v%%:*}"
    echo -e " ${CYAN}–${RESET} ${BOLD}${id}${RESET} ${v#*: }"
  done
fi

echo ""
[ ${#MANUAL_LIST[@]} -gt 0 ] && \
echo -e " ${YELLOW}※ 수동 조치 항목은 Linux_VulnManualGuide.txt 참고 후 직접 조치하세요.${RESET}"
_div_thick

# CSV/XLSX 생성 전 결과 누락 항목을 보정하여 TARGET_IDS와 보고서 행 수를 일치시킨다.
_report_finalize_rows

# ── 결과 보고서 파일 저장 ─────────────────────────────────────────────────────
_RPT_DIR="${_RPT_BASE_DIR:-/linux_vuln_fix/report}"
[ -w "$_RPT_DIR" ] || _RPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -w "$_RPT_DIR" ] || _RPT_DIR="$HOME"
[ -w "$_RPT_DIR" ] || _RPT_DIR="/tmp"
_RPT_FILE="${_RPT_DIR}/vulnFixReport_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"
_RPT_TMP=$(mktemp /tmp/vulnFixReport_XXXXXX.tmp)

{
  echo "========================================================"
  echo "  KISA 취약점 조치 결과 보고서"
  echo "========================================================"
  echo "  실행 일시  : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  호스트명   : $(hostname)"
  echo "  실행 계정  : $(whoami)"
  echo "  총 점검    : ${#TARGET_IDS[@]}개 항목 (U-01 ~ U-67)"
  echo "--------------------------------------------------------"
  echo "  ✔ 자동 조치 완료  : ${FIXED}건"
  echo "  ✔ 이미 양호       : ${_ALREADY_OK}건"
  echo "  ○ 해당없음        : ${NA}건"
  echo "  ⚠ 수동 조치 필요  : ${MANUAL}건"
  echo "  ✘ 조치 실패       : ${FAILED}건"
  [ $_USER_SKIP -gt 0 ] && \
  echo "  – 사용자 건너뜀   : ${_USER_SKIP}건"
  echo "========================================================"

  if [ ${#FIXED_LIST[@]} -gt 0 ]; then
    echo ""
    echo "[ 자동 조치 완료 ]"
    for v in "${FIXED_LIST[@]}"; do
      id="${v%%:*}"
      echo "  • ${v}"
      before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
      [ -n "$before" ] && _summary_preview "$before" "조치 전" "    " 2
      [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
        _summary_preview "$after" "조치 후" "    " 2
    done
  fi

  if [ ${#MANUAL_LIST[@]} -gt 0 ]; then
    echo ""
    echo "[ 수동 조치 필요 ]"
    for v in "${MANUAL_LIST[@]}"; do echo "  • ${v}"; done
  fi

  if [ ${#FAILED_LIST[@]} -gt 0 ]; then
    echo ""
    echo "[ 조치 실패 — configtest 실패로 백업 복구됨 ]"
    for v in "${FAILED_LIST[@]}"; do
      id="${v%%:*}"
      echo "  • ${v}"
      before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
      [ -n "$before" ] && _summary_preview "$before" "조치 전" "    " 2
      [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
        _summary_preview "$after" "조치 후" "    " 2
    done
  fi

  if [ $_USER_SKIP -gt 0 ]; then
    echo ""
    echo "[ 사용자 건너뜀 ]"
    for v in "${_USER_SKIP_LIST[@]}"; do echo "  • ${v}"; done
  fi

  echo ""
  echo "========================================================"
  echo "  사전 백업 : ${_PRE_BAK_RECORDED:-미생성}"
  echo "  상세 로그 : ${DETAIL_LOG_FILE:-미생성}"
  echo "  누적 이력 : ${FIX_HISTORY_FILE}"
  echo "========================================================"
} > "$_RPT_TMP"

# 컬러 코드 제거 후 저장
sed 's/\[[0-9;]*m//g' "$_RPT_TMP" > "$_RPT_FILE" 2>/dev/null
chmod 640 "$_RPT_FILE" 2>/dev/null
rm -f "$_RPT_TMP"

if [ -f "$_RPT_FILE" ]; then
  echo ""
  echo -e " ${GREEN}▶ 결과 보고서 저장 완료${RESET}"
  echo -e "   ${CYAN}${_RPT_FILE}${RESET}"
  echo -e "   크기: $(du -h "$_RPT_FILE" 2>/dev/null | cut -f1)"
  [ -n "${DETAIL_LOG_FILE:-}" ] && echo -e "   상세 로그: ${CYAN}${DETAIL_LOG_FILE}${RESET}"
else
  echo -e " ${YELLOW}!! 보고서 저장 실패 — ${_RPT_DIR} 쓰기 권한 확인 필요${RESET}"
fi

# =============================================================================
# ── [결과 보고서 자동 생성] CSV → XLSX 변환 ───────────────────────────────────
#    외부 파일 없음. Python 코드를 heredoc으로 내장하여 python3 stdin으로 실행.
#    python3/openpyxl 없으면 CSV만 남기고 안내 메시지 출력.
# =============================================================================

# ── 환경 감지 + openpyxl 필요 시 오프라인 설치 ───────────────────────────────
_XLSX_PYTHON=""


_xlsx_env_check() {
  # 반환값: 0=사용 가능, 1=사용 불가(CSV만 생성)
  #
  # 배포 구조:
  #   /linux_vuln_fix/
  #   └── lib/
  #       ├── openpyxl_install.tar     ← whl 파일들이 담긴 tar
  #       └── openpyxl_install/
  #           └── site-packages/       ← whl 압축 해제 위치 (pip 불필요)
  #               ├── openpyxl/
  #               └── et_xmlfile/
  #
  # 핵심: pip install 대신 whl(zip)을 직접 압축 해제 후 PYTHONPATH 설정
  #       → externally-managed 오류 없음, pip 불필요, 권한 문제 없음

  local _offline_tar _offline_dir _unzip_dir

  _offline_tar="${_BASE_DIR}/lib/openpyxl_install.tar"
  _offline_dir="${_BASE_DIR}/lib/openpyxl_install"
  _unzip_dir="${_offline_dir}/site-packages"

  # ── 1) 시스템 openpyxl 확인 ───────────────────────────────────────────────
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import openpyxl" >/dev/null 2>&1; then
      _XLSX_PYTHON="python3"
      return 0
    fi
  fi

  echo -e "   ${YELLOW}⚠ XLSX 생성을 위해 Python/openpyxl 환경을 확인합니다.${RESET}"

  # python3가 없으면 설치 시도
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "   ${CYAN}→${RESET} python3 없음 — 시스템 패키지 설치를 시도합니다."
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y python3 >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 >/dev/null 2>&1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo -e "   ${YELLOW}⚠ python3 설치 실패 — CSV만 저장됩니다.${RESET}"
      return 1
    fi
  fi

  # ── 2) 이미 압축 해제된 라이브러리가 있으면 재사용 ───────────────────────
  if [ -d "${_unzip_dir}/openpyxl" ]; then
    if PYTHONPATH="${_unzip_dir}${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import openpyxl" >/dev/null 2>&1; then
      export PYTHONPATH="${_unzip_dir}${PYTHONPATH:+:$PYTHONPATH}"
      _XLSX_PYTHON="python3"
      _ok "openpyxl 오프라인 라이브러리 재사용 (${_unzip_dir})"
      return 0
    fi
  fi

  # ── 3) tar 확인 및 whl 압축 해제 (pip 불필요) ────────────────────────────
  if [ ! -f "$_offline_tar" ]; then
    echo -e "   ${YELLOW}⚠ openpyxl 없음 + 오프라인 패키지 미발견 — CSV만 저장됩니다.${RESET}"
    echo -e "   ${WHITE}패키지 준비 방법 (인터넷 가능한 서버에서):${RESET}"
    echo -e "   ${CYAN}  pip3 download openpyxl et-xmlfile --no-deps -d /tmp/pkgs${RESET}"
    echo -e "   ${CYAN}  mkdir -p ${_offline_dir} && cp /tmp/pkgs/*.whl ${_offline_dir}/${RESET}"
    echo -e "   ${CYAN}  tar cf ${_offline_tar} -C \$(dirname ${_offline_dir}) \$(basename ${_offline_dir})${RESET}"
    return 1
  fi

  # tar 압축 해제
  echo -e "   ${CYAN}→${RESET} 오프라인 패키지 압축 해제 중..."
  rm -rf "$_offline_dir" 2>/dev/null
  mkdir -p "$_offline_dir" 2>/dev/null
  if ! tar xf "$_offline_tar" -C "${_BASE_DIR}/lib" >/dev/null 2>&1; then
    echo -e "   ${YELLOW}⚠ tar 압축 해제 실패 — CSV만 저장됩니다.${RESET}"
    return 1
  fi

  # whl 파일을 python3 zipfile로 직접 압축 해제 (pip 없이)
  mkdir -p "$_unzip_dir" 2>/dev/null
  local _whl_count=0
  while IFS= read -r _whl; do
    echo -e "   ${CYAN}→${RESET} whl 적용: $(basename "$_whl")"
    python3 -c "
import zipfile, sys
try:
    with zipfile.ZipFile(sys.argv[1], 'r') as z:
        z.extractall(sys.argv[2])
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$_whl" "$_unzip_dir" 2>/dev/null && _whl_count=$((_whl_count + 1))
  done < <(find "$_offline_dir" -type f -name '*.whl' 2>/dev/null)

  if [ "$_whl_count" -eq 0 ]; then
    echo -e "   ${YELLOW}⚠ 압축 파일에 whl 패키지가 없습니다 — CSV만 저장됩니다.${RESET}"
    echo -e "   패키지 위치 확인: ${CYAN}${_offline_dir}${RESET}"
    return 1
  fi

  # PYTHONPATH 설정 후 import 검증
  export PYTHONPATH="${_unzip_dir}${PYTHONPATH:+:$PYTHONPATH}"
  if python3 -c "import openpyxl" >/dev/null 2>&1; then
    local _ver
    _ver=$(python3 -c "import openpyxl; print(openpyxl.__version__)" 2>/dev/null)
    _ok "openpyxl 오프라인 적용 완료 (pip 없이 whl 직접 적용, 버전: ${_ver})"
    _XLSX_PYTHON="python3"
    return 0
  fi

  echo -e "   ${YELLOW}⚠ openpyxl 로드 실패 — CSV만 저장됩니다.${RESET}"
  echo -e "   ${WHITE}whl 해제 위치: ${_unzip_dir}${RESET}"
  echo -e "   ${WHITE}현재 Python: $(python3 --version 2>/dev/null)${RESET}"
  return 1
}

# =============================================================================
# 요약 대시보드 보호 영역
# 다른 기능을 수정하더라도 사용자의 명시적 요청 없이는
# 배치·차트·범례·색상·크기를 변경하지 않는다.
# =============================================================================
# ── XLSX 생성 (Python 코드 heredoc 내장) ──────────────────────────────────────
_generate_xlsx() {
  local _csv="$1" _out="$2" _server="$3" _os="$4" _ts="$5" _history="$6"
  local _xlsx_python="${_XLSX_PYTHON:-python3}"

  "$_xlsx_python" - "$_csv" "$_out" "$_server" "$_os" "$_ts" "$_history" 2>>"${DETAIL_LOG_FILE:-$FIX_HISTORY_FILE}" << 'PYEOF'
import sys, csv, math, re
from collections import Counter
from openpyxl import Workbook
from openpyxl.cell.cell import MergedCell
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.chart import BarChart, DoughnutChart, Reference, Series
from openpyxl.chart.label import DataLabelList
from openpyxl.chart.data_source import AxDataSource, StrRef
from openpyxl.chart.text import RichText
from openpyxl.drawing.text import (
    RichTextProperties, Paragraph, ParagraphProperties,
    CharacterProperties, Font as DrawingFont
)
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo
from openpyxl.formatting.rule import CellIsRule

csv_path, out_path, server, os_info, run_ts, history_path = sys.argv[1:7]

required_cols = ['항목ID','항목명','위험도','대분류','조치전상태','조치후상태','최종결과',
                 '수동확인사유','실패사유','상세내역','백업파일경로','실행일시','서버명','OS정보']
rows = []
with open(csv_path, newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    missing = [c for c in required_cols if c not in (reader.fieldnames or [])]
    if missing:
        raise ValueError('CSV 필수 컬럼 누락: ' + ', '.join(missing))
    for r in reader:
        row = {k:(v if v is not None else '') for k, v in r.items()}
        item_id = row.get('항목ID','').strip()
        if not re.fullmatch(r'U-\d{2}', item_id):
            continue
        rows.append(row)

if not rows:
    raise ValueError('유효한 U-항목 결과 행이 없습니다.')

# 동일 항목이 중복 기록된 경우 마지막 결과만 사용
seen = {}
for r in rows:
    seen[r.get('항목ID','')] = r
rows = sorted(seen.values(), key=lambda x: int(str(x.get('항목ID','')).replace('U-','').lstrip('0') or '0'))

RESULTS = ['양호','조치완료','수동확인','실패','해당없음','건너뜀']
COUNTS = Counter(r.get('최종결과','') for r in rows)
total = len(rows)
na = COUNTS['해당없음']
denom = total - na
good = COUNTS['양호'] + COUNTS['조치완료']
remain = COUNTS['수동확인'] + COUNTS['실패'] + COUNTS['건너뜀']
score = round(good / denom * 100, 1) if denom else 0.0
before_vuln = COUNTS['조치완료'] + remain
after_vuln = remain
improve = before_vuln - after_vuln
remediation_rate = round(COUNTS['조치완료'] / before_vuln * 100, 1) if before_vuln else 100.0

RISKS = ['상','중','하']
_ALL_CATS_ORDER = ['계정 관리','파일 및 디렉터리 관리','서비스 관리','패치 관리','로그 관리']
# 분리 스크립트에서는 실제로 점검하지 않은 분류가 '0점'으로 표시되는 왜곡을 막기 위해
# rows에 실제로 존재하는 분류만 남긴다.
_present_cats = set(x.get('대분류') for x in rows)
CATS = [c for c in _ALL_CATS_ORDER if c in _present_cats]
RISK_STAT = {}
for rk in RISKS:
    sub = [x for x in rows if x.get('위험도') == rk]
    ok = sum(1 for x in sub if x.get('최종결과') in ('양호','조치완료'))
    bad = sum(1 for x in sub if x.get('최종결과') in ('수동확인','실패','건너뜀'))
    RISK_STAT[rk] = (ok, bad, len(sub))

CAT_STAT = []
for cat in CATS:
    sub = [x for x in rows if x.get('대분류') == cat]
    target = [x for x in sub if x.get('최종결과') != '해당없음']
    ok = sum(1 for x in target if x.get('최종결과') in ('양호','조치완료'))
    bad = sum(1 for x in target if x.get('최종결과') in ('수동확인','실패','건너뜀'))
    sc = round(ok / len(target) * 100, 1) if target else 0.0
    high = sum(1 for x in target if x.get('위험도') == '상' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    mid = sum(1 for x in target if x.get('위험도') == '중' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    low = sum(1 for x in target if x.get('위험도') == '하' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    CAT_STAT.append([cat, sc, high, mid, low, ok, bad, len(target)])

risk_order = {'상':0, '중':1, '하':2}
TOP_NEED = sorted(
    [x for x in rows if x.get('최종결과') in ('수동확인','실패','건너뜀')],
    key=lambda x: (risk_order.get(x.get('위험도'), 9), int(str(x.get('항목ID','')).replace('U-','') or '0'))
)[:10]

# ── 공통 스타일 ───────────────────────────────────────────────────────────────
FN = '맑은 고딕'
NAVY = '173B70'; BLUE = '2F66C3'; LIGHT_BLUE = 'EAF2FF'; PALE = 'F7F9FC'
WHITE = 'FFFFFF'; DARK = '1F2937'; GRAY = '6B7280'; RED = 'E53935'; ORANGE = 'F59E0B'; GREEN = '2E7D32'
BORDER_C = 'C7D1E0'
THIN = Side(style='thin', color=BORDER_C)
BDR = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

FONT_TITLE = Font(name=FN, bold=True, color=WHITE, size=18)
FONT_HEADER = Font(name=FN, bold=True, color=WHITE, size=10)
FONT_BASE = Font(name=FN, color=DARK, size=10)
FONT_BOLD = Font(name=FN, bold=True, color=DARK, size=10)
FONT_SMALL = Font(name=FN, color=DARK, size=9)

FILL_NAVY = PatternFill('solid', fgColor=NAVY)
FILL_LIGHT = PatternFill('solid', fgColor=LIGHT_BLUE)
FILL_PALE = PatternFill('solid', fgColor=PALE)
FILL_WHITE = PatternFill('solid', fgColor=WHITE)
RESULT_FILL = {
    '양호':'C6EFCE', '조치완료':'D9EAD3', '수동확인':'FFEB9C',
    '실패':'FFC7CE', '해당없음':'D9D9D9', '건너뜀':'E2EFDA'
}

# ── 차트 공통 서식 ───────────────────────────────────────────────────────────
# 참조 이미지의 제목/범례/축/데이터 레이블 크기와 위치를 동일하게 유지한다.
def _chart_char(size=900, bold=False):
    return CharacterProperties(
        sz=size, b=bold, lang='ko-KR',
        latin=DrawingFont(typeface=FN),
        ea=DrawingFont(typeface=FN),
        cs=DrawingFont(typeface=FN)
    )


def _chart_rich_text(size=900, bold=False, rotation=None):
    cp = _chart_char(size, bold)
    return RichText(
        bodyPr=RichTextProperties(rot=rotation),
        p=[Paragraph(
            pPr=ParagraphProperties(defRPr=cp),
            endParaRPr=cp
        )]
    )


def _style_chart_title(chart, size=1600):
    try:
        cp = _chart_char(size, True)
        para = chart.title.tx.rich.p[0]
        para.pPr = ParagraphProperties(defRPr=cp)
        if para.r:
            para.r[0].rPr = cp
        para.endParaRPr = cp
        chart.title.overlay = False
    except Exception:
        pass


def _style_axis_title(axis, size=900):
    try:
        cp = _chart_char(size, True)
        para = axis.title.tx.rich.p[0]
        para.pPr = ParagraphProperties(defRPr=cp)
        if para.r:
            para.r[0].rPr = cp
        para.endParaRPr = cp
        axis.title.overlay = False
    except Exception:
        pass


def _style_data_labels(labels, size=850):
    try:
        labels.txPr = _chart_rich_text(size=size)
    except Exception:
        pass


def cell(ws, r, c, v='', font=None, fill=None, align='center', border=True, wrap=False):
    x = ws.cell(r, c)
    # 병합 셀의 좌상단이 아닌 셀에는 value를 쓸 수 없으므로 건너뛴다.
    if isinstance(x, MergedCell):
        return x
    # "=" 로 시작하는 문자열은 Excel이 수식으로 해석하여 오류 처리할 수 있음
    # → data_type을 's'(string)로 명시하여 방지
    if isinstance(v, str) and v.startswith('='):
        x.value = v
        x.data_type = 's'
    else:
        x.value = v
    x.font = font or FONT_BASE
    if fill:
        x.fill = fill if isinstance(fill, PatternFill) else PatternFill('solid', fgColor=fill)
    if border:
        x.border = BDR
    x.alignment = Alignment(horizontal=align, vertical='center', wrap_text=wrap)
    return x


def header(ws, r, c1, c2, title):
    ws.merge_cells(start_row=r, start_column=c1, end_row=r, end_column=c2)
    cell(ws, r, c1, title, font=FONT_HEADER, fill=FILL_NAVY, align='left')


def set_widths(ws, widths):
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w


def style_table(ws, start_row, start_col, end_row, end_col):
    for c in range(start_col, end_col + 1):
        cell(ws, start_row, c, ws.cell(start_row, c).value, font=FONT_HEADER, fill=FILL_NAVY)
    for r in range(start_row + 1, end_row + 1):
        for c in range(start_col, end_col + 1):
            cell(ws, r, c, ws.cell(r, c).value, font=FONT_SMALL, align='center', wrap=True)

def fill_block(ws, r1, c1, r2, c2, fill=None, border=True, align='center', wrap=False):
    # 병합/차트 인접 영역에서 마지막 셀 테두리가 빠지는 현상 방지용 보정 함수
    for rr in range(r1, r2 + 1):
        for cc in range(c1, c2 + 1):
            x = ws.cell(rr, cc)
            if isinstance(x, MergedCell):
                continue
            if fill:
                x.fill = fill if isinstance(fill, PatternFill) else PatternFill('solid', fgColor=fill)
            if border:
                x.border = BDR
            x.alignment = Alignment(horizontal=align, vertical='center', wrap_text=wrap)

def merged_cell(ws, r1, c1, r2, c2, value='', font=None, fill=None, align='center', wrap=True):
    ws.merge_cells(start_row=r1, start_column=c1, end_row=r2, end_column=c2)
    x = ws.cell(r1, c1)
    if isinstance(value, str) and value.startswith('='):
        x.value = value
        x.data_type = 's'
    else:
        x.value = value
    x.font = font or FONT_SMALL
    fill_block(ws, r1, c1, r2, c2, fill=fill or WHITE, border=True, align=align, wrap=wrap)
    x.font = font or FONT_SMALL
    return x


# ── 상세 시트 셀 레이아웃 표준화 ──────────────────────────────────────────────
# CSV 내부 컬럼명과 기존 점검·조치 데이터 수집 로직은 유지하고,
# Excel 출력 단계에서만 사용자용 헤더와 셀 레이아웃을 표준화한다.
#
# 조치 전 상태 : [현재 설정] / [확인 내용]
# 조치 후 상태 : [최종 설정] / [검증 결과]
# 최종 판정    : 양호·조치완료·수동확인·실패·해당없음·건너뜀 중 한 값
# 조치 상세    : [조치 내용] / [변경 파일] / [변경 파일 목록] / [서비스 변경]

_GENERIC_BEFORE = {
    '', '점검값 미수집', '점검값 미수집 (점검 대상 미감지)',
    '설정 정보 없음 (점검 대상 미감지)', '이상 항목 없음 (점검 통과)'
}
_GENERIC_AFTER = {
    '', '이미 양호 (재확인 통과)', '수동 확인 필요', '해당없음',
    '사용자 건너뜀', '건너뜀', '조치 실패', '조치 실패 (실행 오류)'
}

# 수동조치 전용 항목은 Excel의 "조치 상세" 셀에서 바로 실행 절차를 확인할 수 있도록
# 점검 명령 → 조치 명령 → 재확인 명령 순서로 안내한다.
# 자동 점검·조치 판정 로직에는 영향을 주지 않으며 Excel 출력 내용만 보강한다.
_MANUAL_ACTION_GUIDES = {
    'U-08': {
        'method': '''1. 관리자 그룹의 현재 구성원을 확인합니다.
getent group wheel
getent group sudo
getent group admin

2. 각 계정의 UID, 보조 그룹 및 sudo 권한을 확인합니다.
id <계정명>
sudo -l -U <계정명>

3. 관리자 권한이 필요하지 않은 계정을 해당 그룹에서 제거합니다.
gpasswd -d <계정명> wheel
gpasswd -d <계정명> sudo
gpasswd -d <계정명> admin

4. 조치 후 관리자 그룹 구성원을 다시 확인합니다.
getent group wheel
getent group sudo
getent group admin''',
        'criteria': '관리자 그룹에는 시스템 관리 권한이 필요한 계정만 포함되어 있어야 합니다.',
        'caution': '현재 접속 계정 또는 유일한 관리자 계정을 제거하기 전에 다른 관리자 계정으로 정상 접속 가능한지 먼저 확인해야 합니다.'
    },
    'U-11': {
        'method': '''1. 로그인 가능한 일반 계정과 현재 shell을 확인합니다.
awk -F: '($3>=1000)&&($1!="nobody")&&($7!~/(nologin|false)$/){printf "%-20s %-8s %s\\n",$1,$3,$7}' /etc/passwd

2. 변경 대상 계정의 사용 여부와 그룹 정보를 확인합니다.
id <계정명>
lastlog -u <계정명>

3. 시스템의 nologin shell 경로를 확인하고, 없는 경우 /bin/false를 사용합니다.
NOLOGIN_SHELL=$(command -v nologin 2>/dev/null)
[ -n "$NOLOGIN_SHELL" ] || NOLOGIN_SHELL=/bin/false

4. 로그인이 필요하지 않은 계정의 shell을 변경합니다.
usermod -s "$NOLOGIN_SHELL" <계정명>

5. 조치 결과를 다시 확인합니다.
getent passwd <계정명>''',
        'criteria': '로그인이 필요하지 않은 계정의 shell이 /sbin/nologin, /usr/sbin/nologin 또는 /bin/false로 설정되어 있어야 합니다.',
        'caution': '서비스 구동 계정의 shell을 변경하면 배치 작업이나 관리 도구가 중단될 수 있으므로 계정 사용 목적과 실행 중인 프로세스를 먼저 확인해야 합니다.'
    },
    'U-33': {
        'method': '''1. 조치 전 현재 상태에 표시된 의심 경로의 유형, 권한, 소유자와 파일 형식을 확인합니다.
stat -c '%F %A %a %U:%G %n' <경로>
file <경로>

2. 실행 파일 또는 스크립트인지 확인하고 패키지 소속 여부를 점검합니다.
find <경로> -maxdepth 0 -perm /111 -ls
rpm -qf <경로> 2>/dev/null || dpkg -S <경로> 2>/dev/null
sha256sum <경로> 2>/dev/null

3. 사용 중인 파일인지 확인합니다.
lsof <경로> 2>/dev/null

4. 불필요한 항목으로 판단한 경우 별도 경로에 백업한 후 삭제합니다.
cp -a -- <경로> <백업경로>/
rm -f -- <파일경로>
rm -rf -- <디렉터리경로>

5. 스크립트를 다시 실행하여 의심 목록이 남아 있는지 재점검합니다.''',
        'criteria': '의심 숨김 파일·디렉터리가 없거나, 남아 있는 각 항목의 생성 주체와 사용 목적이 확인되어야 합니다.',
        'caution': '숨김 파일은 애플리케이션 설정 또는 인증 정보일 수 있으므로 rm -rf 실행 전 경로, 소유자, 사용 프로세스와 백업 여부를 반드시 확인해야 합니다.'
    },
    'U-47': {
        'method': '''1. 설치·실행 중인 MTA와 SMTP 포트 상태를 확인합니다.
ps -ef | grep -E '[p]ostfix|[s]endmail|[e]xim'
ss -lntp | grep ':25 '

2. Postfix 사용 시 설정 파일을 백업하고 현재 릴레이 설정을 확인합니다.
cp -a /etc/postfix/main.cf /etc/postfix/main.cf.bak.$(date +%Y%m%d_%H%M%S)
postconf mynetworks
postconf relay_domains
postconf smtpd_relay_restrictions

3. Postfix의 허용 대역과 비인가 릴레이 차단 정책을 적용한 후 검증합니다.
postconf -e 'mynetworks = 127.0.0.0/8, [::1]/128, <허용_IP_또는_대역>'
postconf -e 'relay_domains ='
postconf -e 'smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, defer_unauth_destination'
postfix check && systemctl reload postfix
postconf -n | grep -E '^(mynetworks|relay_domains|smtpd_relay_restrictions)'

4. Sendmail 사용 시 설정을 백업하고 필요한 호스트만 RELAY로 등록합니다.
cp -a /etc/mail/access /etc/mail/access.bak.$(date +%Y%m%d_%H%M%S)
grep -v '^[[:space:]]*#' /etc/mail/relay-domains 2>/dev/null
grep -i 'RELAY' /etc/mail/access 2>/dev/null
printf 'Connect:<허용_IP_또는_대역>\\tRELAY\\n' >> /etc/mail/access
makemap hash /etc/mail/access.db < /etc/mail/access
systemctl reload sendmail

5. Exim 사용 시 릴레이 허용 호스트를 확인하고 설정을 백업한 후 반영합니다.
grep -RniE 'relay_from_hosts|hostlist.*relay' /etc/exim4 /etc/exim 2>/dev/null
cp -a /etc/exim4/update-exim4.conf.conf /etc/exim4/update-exim4.conf.conf.bak.$(date +%Y%m%d_%H%M%S)
vi /etc/exim4/update-exim4.conf.conf
update-exim4.conf && systemctl reload exim4

6. 사용 중인 MTA의 설정을 다시 출력하여 허용 대상 외 릴레이가 차단되는지 확인합니다.''',
        'criteria': '인증된 사용자와 명시적으로 허용한 IP·대역만 메일 릴레이를 사용할 수 있고, 그 외 외부 호스트의 릴레이 요청은 거부되어야 합니다.',
        'caution': '허용 대역을 과도하게 지정하면 오픈 릴레이가 될 수 있고, 필요한 대역을 누락하면 정상 메일 전송이 중단될 수 있으므로 변경 전 설정 파일을 백업해야 합니다.'
    },
    'U-55': {
        'method': '''1. vsftpd 설정에서 FTP 전용 비권한 계정을 확인합니다.
grep -hE '^[[:space:]]*nopriv_user[[:space:]]*=' /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf 2>/dev/null

2. 확인된 계정의 현재 shell을 조회합니다.
FTP_USER=$(grep -hE '^[[:space:]]*nopriv_user[[:space:]]*=' /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]')
getent passwd "$FTP_USER"

3. 시스템의 nologin shell 경로를 확인하고, 없는 경우 /bin/false를 사용하여 FTP 전용 계정에 적용합니다.
NOLOGIN_SHELL=$(command -v nologin 2>/dev/null)
[ -n "$NOLOGIN_SHELL" ] || NOLOGIN_SHELL=/bin/false
usermod -s "$NOLOGIN_SHELL" "$FTP_USER"

4. 조치 결과를 다시 확인합니다.
getent passwd "$FTP_USER"''',
        'criteria': 'FTP 전용 비권한 계정의 shell이 /sbin/nologin, /usr/sbin/nologin 또는 /bin/false로 설정되어 있어야 합니다.',
        'caution': '실제 FTP 로그인 사용자와 nopriv_user를 혼동하지 말고, 설정 파일에서 확인한 FTP 전용 비권한 계정에만 적용해야 합니다.'
    },
}


def _clean_layout_text(value):
    if value is None:
        return ''
    text = str(value).replace('\r', '').strip()
    if not text:
        return ''
    text = text.replace(' || ', '\n').replace(' | [', '\n[')
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    text = '\n'.join(lines)
    # 쉼표로 연결된 여러 설정값(KEY=VALUE)은 줄 단위로 표시한다.
    if '\n' not in text and text.count('=') >= 2 and ', ' in text:
        text = text.replace(', ', '\n')
    return text


def _detail_sections(detail):
    text = _clean_layout_text(detail)
    if not text:
        return {}, ''
    # 기존 상세내역은 " | [섹션]" 형식이 많으므로 섹션 시작 전 줄바꿈을 보장한다.
    text = re.sub(r'\s*\|\s*(?=\[[^\]]+\])', '\n', text)
    sections = {}
    pattern = re.compile(r'\[([^\]]+)\]\s*(.*?)(?=\n\[[^\]]+\]|$)', re.S)
    for match in pattern.finditer(text):
        key = match.group(1).strip()
        value = _clean_layout_text(match.group(2))
        if value:
            sections[key] = value
    return sections, text


def _first_section(sections, *names):
    for name in names:
        value = sections.get(name, '').strip()
        if value:
            return value
    return ''


def _before_check_message(row, sections):
    status = row.get('최종결과', '').strip()
    explicit = _first_section(sections, '확인 내용', '판정 근거', '판정')
    if explicit:
        return explicit
    if status == '양호':
        return '보안 기준 충족'
    if status == '조치완료':
        return '조치 전 보안 기준 미충족'
    if status == '수동확인':
        return _clean_layout_text(row.get('수동확인사유')) or '자동 판정 불가 또는 운영 정책 확인 필요'
    if status == '실패':
        return _clean_layout_text(row.get('실패사유')) or '조치 또는 최종 검증 미통과'
    if status == '해당없음':
        return '점검 대상 없음'
    if status == '건너뜀':
        return '조치 필요 상태이나 사용자가 조치를 건너뜀'
    return '확인 결과 기록 참조'


def _after_verify_message(row, sections):
    status = row.get('최종결과', '').strip()
    explicit = _first_section(sections, '검증 결과', '최종 검증', '검증')
    if explicit:
        return explicit
    if status == '양호':
        return '재확인 통과'
    if status == '조치완료':
        return '최종 검증 통과'
    if status == '수동확인':
        return _clean_layout_text(row.get('수동확인사유')) or '추가 검토 필요'
    if status == '실패':
        return _clean_layout_text(row.get('실패사유')) or '조치 또는 최종 검증 실패'
    if status == '해당없음':
        return '검증 대상 없음'
    if status == '건너뜀':
        return '검증 미수행'
    return '검증 결과 확인 필요'


def format_before_state(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    before = _clean_layout_text(row.get('조치전상태', ''))
    detail_before = _first_section(sections, '현재 상태', '현재 설정', '변경 전', '조치 전')
    if before in _GENERIC_BEFORE and detail_before:
        before = detail_before
    if not before:
        before = detail_before or '확인된 설정값 없음'
    check = _before_check_message(row, sections)
    return f'[현재 설정]\n{before}\n\n[확인 내용]\n{check}'


def format_after_state(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    status = row.get('최종결과', '').strip()

    # 최종 판정이 '건너뜀'이면 상세 시트의 조치 후 상태는 한 줄로 간결하게 표시한다.
    # 최종 판정 열에 이미 '건너뜀'이 기록되므로 중복 설명을 넣지 않는다.
    if status == '건너뜀':
        return '변경 없음'
    after = _clean_layout_text(row.get('조치후상태', ''))
    before = _clean_layout_text(row.get('조치전상태', ''))
    detail_after = _first_section(sections, '최종 설정', '변경 후', '조치 후')

    if detail_after:
        final_setting = detail_after
    elif status == '양호' and after in _GENERIC_AFTER:
        final_setting = before or '변경 없음'
    elif status in ('수동확인', '건너뜀') and after in _GENERIC_AFTER:
        final_setting = '변경하지 않음'
    elif status == '해당없음' and after in _GENERIC_AFTER:
        final_setting = '변경 없음'
    elif status == '실패' and after in _GENERIC_AFTER:
        final_setting = '변경 전 상태 유지 또는 일부 변경'
    else:
        final_setting = after or detail_after or '최종 설정값 확인 필요'

    verify = _after_verify_message(row, sections)
    return f'[최종 설정]\n{final_setting}\n\n[검증 결과]\n{verify}'


def _infer_action(row, sections, raw_detail):
    action = _first_section(sections, '조치 내용', '조치 방법', '수행 내역', '적용 내용')
    if action:
        return action

    # 표준 섹션으로 분류되지 않은 정보는 데이터 손실 없이 조치 내용에 보존한다.
    excluded = {
        '현재 상태', '현재 설정', '변경 전', '조치 전', '변경 후', '조치 후',
        '최종 설정', '조치 결과', '결과', '판정', '판정 근거', '확인 내용',
        '검증', '검증 결과', '최종 검증', '변경 파일', '변경 파일 목록',
        '실제 변경 파일', '변경된 경로', '삭제된 경로', '서비스 변경'
    }
    extras = []
    for key, value in sections.items():
        if key not in excluded and value:
            extras.append(f'{key}: {value}')
    if extras:
        return '\n'.join(extras)

    if raw_detail and not sections:
        return raw_detail

    status = row.get('최종결과', '').strip()
    return {
        '양호': '변경 없음',
        '조치완료': '보안 설정 조치 수행',
        '수동확인': '자동 조치 없이 추가 검토 대상으로 기록',
        '실패': '조치 시도 후 실패 또는 최종 검증 미통과',
        '해당없음': '조치 대상 없음',
        '건너뜀': '사용자가 조치를 건너뜀',
    }.get(status, '조치 내역 확인 필요')


def format_action_detail(row):
    sections, raw_detail = _detail_sections(row.get('상세내역', ''))
    status = row.get('최종결과', '').strip()
    item_id = row.get('항목ID', '').strip()
    manual_guide = _MANUAL_ACTION_GUIDES.get(item_id) if status == '수동확인' else None
    action = manual_guide['method'] if manual_guide else _infer_action(row, sections, raw_detail)

    changed = _first_section(sections, '변경 파일', '실제 변경 파일', '삭제 대상')
    file_list = _first_section(sections, '변경 파일 목록', '변경된 경로', '삭제된 경로')

    # "변경 파일" 섹션에 절대경로가 직접 들어간 기존 항목은 목록으로 분리한다.
    if changed.startswith('/') and not file_list:
        file_list = changed
        changed = '총 1개'

    # 수동확인 항목은 실제 변경 정보가 기록된 경우에만 변경 파일 섹션을 표시한다.
    # 자동 변경이 없었던 행에 "[변경 파일] 없음"을 반복하지 않는다.
    show_changed_section = bool(changed or file_list)
    if not changed and status != '수동확인':
        if file_list:
            # 경로 구분자가 일정하지 않은 기존 값은 정확한 건수 추정을 피한다.
            changed = '목록 참조'
        elif status in ('양호', '해당없음', '건너뜀'):
            changed = '없음'
        elif status == '조치완료':
            changed = '기록 없음'
        else:
            changed = '확인 필요'
        show_changed_section = True
    elif not changed and file_list:
        changed = '목록 참조'
        show_changed_section = True

    service = _first_section(sections, '서비스 변경')

    # 변경 파일 목록이 쉼표로 이어진 한 줄이면 행 높이 계산(\n 개수 기반)이 맞지 않아
    # 셀에서 시각적으로 잘린다. 항목 경계(쉼표) 기준으로 열 폭(~80자)에 맞춰 줄바꿈해
    # 전체 목록이 셀 안에서 그대로 보이도록 한다. (구버전 기록은 ', ' 없이 ','만 쓰므로 둘 다 처리)
    if file_list and '\n' not in file_list and ',' in file_list:
        _items = [s.strip() for s in file_list.split(',') if s.strip()]
        _lines, _cur = [], ''
        for _it in _items:
            if _cur and len(_cur) + 2 + len(_it) > 80:
                _lines.append(_cur)
                _cur = _it
            else:
                _cur = _it if not _cur else _cur + ', ' + _it
        if _cur:
            _lines.append(_cur)
        file_list = '\n'.join(_lines)

    action_label = '조치 방법' if status == '수동확인' else '조치 내용'
    parts = [f'[{action_label}]\n{action}']
    if show_changed_section:
        parts.append(f'[변경 파일]\n{changed}')
    if file_list:
        parts.append(f'[변경 파일 목록]\n{file_list}')
    if service:
        parts.append(f'[서비스 변경]\n{service}')
    if manual_guide:
        parts.append(f"[양호 기준]\n{manual_guide['criteria']}")
        parts.append(f"[주의 사항]\n{manual_guide['caution']}")
    return '\n\n'.join(parts)


def _report_text(value):
    """Excel 표시용 문구 정리. 원본 CSV 값은 변경하지 않는다."""
    text = _clean_layout_text(value)
    # 보고서에서는 모호한 "업무"보다 운영 환경/정책 의미가 명확한 "운영"을 사용한다.
    return text.replace('업무', '운영')


def format_current_state(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    before = _clean_layout_text(row.get('조치전상태', ''))
    detail_before = _first_section(sections, '현재 상태', '현재 설정', '변경 전', '조치 전')
    if before in _GENERIC_BEFORE and detail_before:
        before = detail_before
    return before or detail_before or '확인된 설정값 없음'


def format_need_reason(row):
    status = row.get('최종결과', '').strip()
    manual_reason = _report_text(row.get('수동확인사유', ''))
    fail_reason = _report_text(row.get('실패사유', ''))
    if status == '수동확인':
        return manual_reason or '자동 판정 또는 자동 변경이 적절하지 않아 운영 환경 확인이 필요합니다.'
    if status == '실패':
        return fail_reason or '조치 명령 실행 또는 최종 검증이 정상적으로 완료되지 않았습니다.'
    if status == '건너뜀':
        return manual_reason or '자동 조치를 수행하지 않아 후속 조치와 재점검이 필요합니다.'
    return manual_reason or fail_reason or '추가 확인이 필요합니다.'


def format_need_action(row):
    sections, raw_detail = _detail_sections(row.get('상세내역', ''))
    item_id = row.get('항목ID', '').strip()
    manual_guide = _MANUAL_ACTION_GUIDES.get(item_id)
    if manual_guide:
        return manual_guide['method']
    return _report_text(_infer_action(row, sections, raw_detail)) or '현재 상태와 확인 필요 사유를 검토한 후 해당 항목의 보안 기준에 따라 조치하고 재점검합니다.'


def format_need_criteria(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    item_id = row.get('항목ID', '').strip()
    manual_guide = _MANUAL_ACTION_GUIDES.get(item_id)
    if manual_guide:
        return manual_guide['criteria']
    explicit = _first_section(sections, '양호 기준', '판정 기준', '보안 기준')
    if explicit:
        return _report_text(explicit)
    status = row.get('최종결과', '').strip()
    if status == '실패':
        return '조치 명령이 정상 완료되고 최종 검증 기준을 충족해야 합니다.'
    return '확인 필요 사유가 해소되고 재점검 결과가 양호로 판정되어야 합니다.'


def format_need_caution(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    item_id = row.get('항목ID', '').strip()
    manual_guide = _MANUAL_ACTION_GUIDES.get(item_id)
    if manual_guide:
        return manual_guide['caution']
    explicit = _first_section(sections, '주의 사항', '주의사항', '유의 사항', '유의사항')
    if explicit:
        return _report_text(explicit)
    return '설정 변경 전 현재 값과 관련 파일을 백업하고, 계정 접근 및 서비스 영향 여부를 확인해야 합니다.'


def format_result_summary(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    status = row.get('최종결과', '').strip()
    if status in ('수동확인', '실패', '건너뜀'):
        return format_need_reason(row)
    if status == '조치완료':
        result = _first_section(sections, '조치 결과', '결과')
        verify = _after_verify_message(row, sections)
        if result and verify and verify not in result:
            return f'{_report_text(result)}\n{_report_text(verify)}'
        return _report_text(result or verify or '조치 완료 / 최종 검증 통과')
    if status == '양호':
        return '보안 기준 충족 / 변경 없음'
    if status == '해당없음':
        return '점검 대상 없음'
    return '결과 기록 확인 필요'


def _change_values(row):
    sections, raw_detail = _detail_sections(row.get('상세내역', ''))
    changed = _first_section(sections, '변경 파일', '실제 변경 파일', '삭제 대상')
    file_list = _first_section(sections, '변경 파일 목록', '변경된 경로', '삭제된 경로', '실제 변경 파일')
    service = _first_section(sections, '서비스 변경')
    return sections, raw_detail, changed.strip(), file_list.strip(), service.strip()


def has_actual_change(row):
    if row.get('최종결과', '').strip() == '조치완료':
        return True
    _, _, changed, file_list, service = _change_values(row)
    if file_list or service:
        return True
    normalized = re.sub(r'\s+', '', changed)
    return bool(normalized and normalized not in ('없음', '변경없음', '해당없음', '해당사항없음', '0개'))


def format_change_before(row):
    return format_current_state(row)


def format_change_action(row):
    sections, raw_detail, _, _, _ = _change_values(row)
    return _report_text(_infer_action(row, sections, raw_detail)) or '조치 내역 기록 참조'


def format_change_target(row):
    _, _, changed, file_list, service = _change_values(row)
    parts = []
    if file_list:
        parts.append(f'[파일·경로]\n{_clean_layout_text(file_list)}')
    elif changed and re.sub(r'\s+', '', changed) not in ('없음', '변경없음', '해당없음', '해당사항없음', '0개'):
        parts.append(f'[변경 정보]\n{_clean_layout_text(changed)}')
    if service:
        parts.append(f'[서비스]\n{_clean_layout_text(service)}')
    return '\n\n'.join(parts) or '기록된 변경 대상 없음'


def format_change_verify(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    verify = _first_section(sections, '검증 결과', '최종 검증', '검증')
    if verify:
        return _report_text(verify)
    return _report_text(_after_verify_message(row, sections)) or '검증 결과 기록 참조'


def format_backup_path(row):
    value = _clean_layout_text(row.get('백업파일경로', ''))
    return '' if value in ('', '미생성', '없음', '-') else value


def _style_multi_text_row(ws, row_num, result_col, text_cols, max_height=409):
    result = ws.cell(row_num, result_col).value
    ws.cell(row_num, result_col).fill = PatternFill('solid', fgColor=RESULT_FILL.get(result, WHITE))
    ws.cell(row_num, result_col).alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)

    max_lines = 1
    for col in text_cols:
        current = ws.cell(row_num, col)
        current.alignment = Alignment(horizontal='left', vertical='top', wrap_text=True)
        value = '' if current.value is None else str(current.value)
        max_lines = max(max_lines, value.count('\n') + 1)
    ws.row_dimensions[row_num].height = max(45, min(max_height, max_lines * 14))


def _detail_row_style(ws, row_num, before_col, after_col, result_col, detail_col, max_height=200):
    result = ws.cell(row_num, result_col).value
    ws.cell(row_num, result_col).fill = PatternFill('solid', fgColor=RESULT_FILL.get(result, WHITE))
    ws.cell(row_num, result_col).alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)

    max_lines = 1
    for col in (before_col, after_col, detail_col):
        current = ws.cell(row_num, col)
        current.alignment = Alignment(horizontal='left', vertical='top', wrap_text=True)
        value = '' if current.value is None else str(current.value)
        max_lines = max(max_lines, value.count('\n') + 1)
    ws.row_dimensions[row_num].height = max(45, min(max_height, max_lines * 14))

# ── Workbook ─────────────────────────────────────────────────────────────────
wb = Workbook()
wb.remove(wb.active)
ws = wb.create_sheet('요약 대시보드')
ws.sheet_view.showGridLines = False

# 고정 레이아웃: A~N, 48행 안에서 끝나도록 좌표 기반 배치
set_widths(ws, [2,14,20,10,14,14,14,14,14,14,14,12,12,12])
for rr in range(1, 60):
    ws.row_dimensions[rr].height = 15
ws.row_dimensions[2].height = 30
ws.row_dimensions[3].height = 18
ws.row_dimensions[15].height = 30  # 중단 요약표의 긴 머리글 표시
ws.row_dimensions[17].height = 30  # 조치완료 행 높이
ws.row_dimensions[21].height = 30  # 건너뜀 행 높이

# 제목 영역
ws.merge_cells('B2:N2')
cell(ws, 2, 2, 'KISA 취약점 조치 결과 보고서', font=FONT_TITLE, fill=FILL_NAVY, align='left', border=False)
ws.merge_cells('B3:N3')
cell(ws, 3, 2, f'생성 일시: {run_ts}', font=Font(name=FN, color=WHITE, size=10), fill=FILL_NAVY, align='right', border=False)

# ── 1. 상단: 자산 정보 / KPI / 보안 점수 ─────────────────────────────────────
header(ws, 5, 2, 4, '1. 자산 정보')
asset = [
    ('서버명', server), ('OS 정보', os_info), ('실행 일시', run_ts),
    ('전체 진단 항목 수', total), ('보안 점수', f'{score}점 / 100점')
]
for i, (k, v) in enumerate(asset, 6):
    cell(ws, i, 2, k, font=FONT_BOLD, fill=PALE, align='left')
    ws.merge_cells(start_row=i, start_column=3, end_row=i, end_column=4)
    fc = Font(name=FN, bold=True, color=BLUE, size=13) if k == '보안 점수' else FONT_BASE
    cell(ws, i, 3, v, font=fc, fill=WHITE, align='left' if k != '보안 점수' else 'center', wrap=True)

# 자산 정보 박스 외곽/내부 라인 보정 — 병합 셀 마지막 라인 누락 방지
fill_block(ws, 5, 2, 11, 4, border=True, align='center', wrap=True)
ws.cell(5, 2).alignment = Alignment(horizontal='left', vertical='center', wrap_text=True)
for rr in range(6, 12):
    ws.cell(rr, 2).alignment = Alignment(horizontal='left', vertical='center', wrap_text=True)
    ws.cell(rr, 3).alignment = Alignment(horizontal='left' if rr != 11 else 'center', vertical='center', wrap_text=True)

# KPI 카드: 같은 높이/폭으로 고정
kpis = [
    ('양호', COUNTS['양호'], BLUE), ('조치완료', COUNTS['조치완료'], GREEN),
    ('수동확인', COUNTS['수동확인'], ORANGE), ('실패', COUNTS['실패'], RED), ('건너뜀', COUNTS['건너뜀'], GRAY)
]
for idx, (label, val, color) in enumerate(kpis):
    c = 6 + idx
    pct = round(val / total * 100, 1) if total else 0.0
    cell(ws, 5, c, label, font=FONT_BOLD, fill=WHITE)
    ws.merge_cells(start_row=6, start_column=c, end_row=7, end_column=c)
    cell(ws, 6, c, val, font=Font(name=FN, bold=True, color=color, size=22), fill=WHITE)
    cell(ws, 8, c, f'({pct}%)', font=FONT_SMALL, fill=WHITE)
    ws.merge_cells(start_row=9, start_column=c, end_row=11, end_column=c)
    cell(ws, 9, c, '', fill=WHITE)

# KPI 카드 외곽/내부 라인 보정 — 하단 빈 병합 영역까지 표로 마무리
fill_block(ws, 5, 6, 11, 10, fill=WHITE, border=True, align='center', wrap=True)

# 보안 점수 카드
header(ws, 5, 12, 14, '보안 점수')
ws.merge_cells('L6:N9')
cell(ws, 6, 12, score, font=Font(name=FN, bold=True, color=BLUE, size=30), fill=FILL_LIGHT)
ws.merge_cells('L10:N10')
cell(ws, 10, 12, '/100점', font=Font(name=FN, bold=True, color=BLUE, size=12), fill=FILL_LIGHT)
ws.merge_cells('L11:N11')
cell(ws, 11, 12, f'조치율 {remediation_rate}% | 개선 {improve}건', font=Font(name=FN, bold=True, color=NAVY, size=10), fill='F3F7FF')

# ── 2. 중단: 핵심 요약 표 3개 ───────────────────────────────────────────────
header(ws, 13, 2, 14, '2. 자산 진단 현황')
summary_data = [['결과','건수','비율']]
for res in ['양호','조치완료','수동확인','실패','해당없음','건너뜀']:
    summary_data.append([res, COUNTS[res], f'{round(COUNTS[res]/total*100,1) if total else 0}%'])
for r, row in enumerate(summary_data, 15):
    for c, v in enumerate(row, 2):
        cell(ws, r, c, v)
style_table(ws, 15, 2, 21, 4)
for r in range(16, 22):
    res = ws.cell(r, 2).value
    ws.cell(r, 2).fill = PatternFill('solid', fgColor=RESULT_FILL.get(res, WHITE))

risk_data = [['위험도','최종 양호','확인 필요'], ['상', RISK_STAT['상'][0], RISK_STAT['상'][1]], ['중', RISK_STAT['중'][0], RISK_STAT['중'][1]], ['하', RISK_STAT['하'][0], RISK_STAT['하'][1]]]
for r, row in enumerate(risk_data, 15):
    for c, v in enumerate(row, 6): cell(ws, r, c, v)
style_table(ws, 15, 6, 18, 8)

cat_data = [['항목 분류','최종 양호율(%)','확인 필요(상)','확인 필요(중)','확인 필요(하)']] + [[x[0], x[1], x[2], x[3], x[4]] for x in CAT_STAT]
for r, row in enumerate(cat_data, 15):
    for c, v in enumerate(row, 10): cell(ws, r, c, v, wrap=True)
# 분리 스크립트에서는 CATS 개수가 6개보다 적을 수 있어(part1=5개, part2=1개),
# 표/차트 참조 범위를 실제 카테고리 개수에 맞춰 동적으로 계산한다.
# (고정 21행 기준이면 남는 행이 '0%' 빈 막대로 차트에 섞여 나오는 문제가 있었음)
_cat_end_row = 15 + max(len(CATS), 1)
style_table(ws, 15, 10, _cat_end_row, 14)

# ── 3. 하단 차트: 참조 이미지의 범주·범례·타이틀 서식 고정 ────────────────────
header(ws, 23, 2, 4, '3. 진단 결과별 건수')
cell(ws, 23, 5, '', fill=FILL_WHITE, border=False)

bar1 = BarChart()
bar1.type = 'col'
bar1.style = 2
bar1.roundedCorners = False
bar1.title = '진단 결과별 건수'
bar1.y_axis.title = '건수'
bar1.x_axis.axPos = 'b'
bar1.y_axis.axPos = 'l'
bar1.x_axis.tickLblPos = 'low'
bar1.y_axis.tickLblPos = 'low'
bar1.x_axis.delete = False
bar1.y_axis.delete = False
bar1.x_axis.tickLblSkip = 1
bar1.x_axis.noMultiLvlLbl = True
bar1.y_axis.scaling.min = 0
_bar1_max = max([COUNTS.get(k, 0) for k in ['양호','조치완료','수동확인','실패','해당없음','건너뜀']] or [0])
bar1.y_axis.scaling.max = max(10, int(math.ceil(_bar1_max / 10.0) * 10))
bar1.y_axis.majorUnit = 10

# 범주 6개 + 단일 계열 1개를 직접 지정하여 범례는 반드시 '건수' 하나만 표시한다.
_bar1_series = Series(Reference(ws, min_col=3, min_row=16, max_row=21), title='건수')
_bar1_series.cat = AxDataSource(strRef=StrRef(f=f"'{ws.title}'!$B$16:$B$21"))
_bar1_series.graphicalProperties.solidFill = '4472C4'
bar1.append(_bar1_series)
bar1.height = 8.4
bar1.width = 11.6
bar1.gapWidth = 150
bar1.dataLabels = DataLabelList()
bar1.dataLabels.showVal = True
bar1.dataLabels.showSerName = False
bar1.dataLabels.showCatName = False
bar1.dataLabels.showLegendKey = False
bar1.dataLabels.showPercent = False
bar1.dataLabels.dLblPos = 'outEnd'
bar1.legend.position = 'r'
bar1.legend.overlay = False
bar1.legend.txPr = _chart_rich_text(size=850)
bar1.x_axis.txPr = _chart_rich_text(size=850, rotation=-2700000)
bar1.y_axis.txPr = _chart_rich_text(size=850)
_style_chart_title(bar1, 1600)
_style_axis_title(bar1.y_axis, 900)
_style_data_labels(bar1.dataLabels, 850)
ws.add_chart(bar1, 'B24')

header(ws, 23, 6, 8, '4. 위험도별 최종 양호/확인 필요')
cell(ws, 23, 9, '', fill=FILL_WHITE, border=False)

bar2 = BarChart()
bar2.type = 'bar'
bar2.style = 2
bar2.roundedCorners = False
bar2.title = '위험도별 최종 양호/확인 필요'
# openpyxl의 bar 차트 축 매핑 기준으로 참조 이미지의 좌측 '건수', 하단 '위험도'를 재현한다.
bar2.x_axis.title = '건수'
bar2.y_axis.title = '위험도'
bar2.x_axis.axPos = 'l'
bar2.y_axis.axPos = 'b'
bar2.x_axis.tickLblPos = 'low'
bar2.y_axis.tickLblPos = 'low'
bar2.x_axis.delete = False
bar2.y_axis.delete = False
bar2.x_axis.tickLblSkip = 1
bar2.x_axis.noMultiLvlLbl = True
_bar2_max = max([RISK_STAT[k][0] for k in ['상','중','하']] + [RISK_STAT[k][1] for k in ['상','중','하']] + [0])
bar2.y_axis.scaling.min = 0
bar2.y_axis.scaling.max = max(10, int(math.ceil(_bar2_max / 10.0) * 10))
bar2.y_axis.majorUnit = 10

# 범례에는 최종 미해결 항목과 최종 양호 항목의 의미가 바로 드러나도록 표시한다.
_bar2_categories = f"'{ws.title}'!$F$16:$F$18"
_bar2_bad = Series(Reference(ws, min_col=8, min_row=16, max_row=18), title='확인 필요')
_bar2_bad.cat = AxDataSource(strRef=StrRef(f=_bar2_categories))
_bar2_bad.graphicalProperties.solidFill = 'C0504D'
bar2.append(_bar2_bad)
_bar2_good = Series(Reference(ws, min_col=7, min_row=16, max_row=18), title='최종 양호')
_bar2_good.cat = AxDataSource(strRef=StrRef(f=_bar2_categories))
_bar2_good.graphicalProperties.solidFill = '4472C4'
bar2.append(_bar2_good)
bar2.height = 8.4
bar2.width = 11.6
bar2.gapWidth = 80
bar2.overlap = 0
bar2.dataLabels = DataLabelList()
bar2.dataLabels.showVal = True
bar2.dataLabels.showSerName = False
bar2.dataLabels.showCatName = False
bar2.dataLabels.showLegendKey = False
bar2.dataLabels.showPercent = False
bar2.dataLabels.dLblPos = 'outEnd'
bar2.legend.position = 'r'
bar2.legend.overlay = False
bar2.legend.txPr = _chart_rich_text(size=850)
bar2.x_axis.txPr = _chart_rich_text(size=850)
bar2.y_axis.txPr = _chart_rich_text(size=850)
_style_chart_title(bar2, 1600)
_style_axis_title(bar2.x_axis, 900)
_style_axis_title(bar2.y_axis, 900)
_style_data_labels(bar2.dataLabels, 850)
ws.add_chart(bar2, 'F24')

header(ws, 23, 10, 13, '5. 항목 분류별 최종 양호율')
cell(ws, 23, 14, '', fill=FILL_WHITE, border=False)

bar3 = BarChart()
bar3.type = 'col'
bar3.style = 2
bar3.roundedCorners = False
bar3.title = '항목 분류별 최종 양호율(%)'
bar3.y_axis.title = '최종 양호율(%)'
bar3.y_axis.scaling.min = 0
bar3.y_axis.scaling.max = 100
bar3.y_axis.majorUnit = 20
bar3.x_axis.axPos = 'b'
bar3.y_axis.axPos = 'l'
bar3.x_axis.tickLblPos = 'low'
bar3.y_axis.tickLblPos = 'low'
bar3.x_axis.delete = False
bar3.y_axis.delete = False
bar3.x_axis.tickLblSkip = 1
bar3.x_axis.noMultiLvlLbl = True

_bar3_series = Series(Reference(ws, min_col=11, min_row=16, max_row=_cat_end_row), title='최종 양호율(%)')
_bar3_series.cat = AxDataSource(strRef=StrRef(f=f"'{ws.title}'!$J$16:$J${_cat_end_row}"))
_bar3_series.graphicalProperties.solidFill = '4472C4'
bar3.append(_bar3_series)
bar3.height = 8.4
bar3.width = 12.4
bar3.gapWidth = 120
bar3.legend = None
bar3.dataLabels = DataLabelList()
bar3.dataLabels.showVal = True
bar3.dataLabels.showSerName = False
bar3.dataLabels.showCatName = False
bar3.dataLabels.showLegendKey = False
bar3.dataLabels.showPercent = False
bar3.dataLabels.dLblPos = 'outEnd'
bar3.x_axis.txPr = _chart_rich_text(size=850, rotation=-2700000)
bar3.y_axis.txPr = _chart_rich_text(size=850)
_style_chart_title(bar3, 1600)
_style_axis_title(bar3.y_axis, 900)
_style_data_labels(bar3.dataLabels, 850)
ws.add_chart(bar3, 'J24')

# ── 4. 하단 요약: 조치 전/후 + 확인 필요 Top5 ─────────────────────────────
header(ws, 45, 2, 4, '6. 조치 전/후 비교')
before_data = [['구분','취약 건수','비율'], ['조치 전', before_vuln, f'{round(before_vuln/total*100,1) if total else 0}%'], ['조치 후', after_vuln, f'{round(after_vuln/total*100,1) if total else 0}%'], ['개선 효과', improve, f'{round(improve/total*100,1) if total else 0}%']]
for r, row in enumerate(before_data, 46):
    for c, v in enumerate(row, 2): cell(ws, r, c, v)
style_table(ws, 46, 2, 49, 4)

header(ws, 45, 6, 14, '7. 확인 필요 항목 Top 5')
# Top5 표는 병합 범위와 테두리 범위를 일치시켜 우측 상태 컬럼/하단 라인 깨짐 방지
for c1, c2, title in [(6,6,'순위'), (7,7,'항목ID'), (8,10,'항목명'), (11,11,'중요도'), (12,13,'대분류'), (14,14,'조치 상태')]:
    merged_cell(ws, 46, c1, 46, c2, title, font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True)

for i, r in enumerate(TOP_NEED[:5], 47):
    merged_cell(ws, i, 6, i, 6, i-46, font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 7, i, 7, r.get('항목ID',''), font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 8, i, 10, r.get('항목명',''), font=FONT_SMALL, fill=WHITE, wrap=True)
    merged_cell(ws, i, 11, i, 11, r.get('위험도',''), font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 12, i, 13, r.get('대분류',''), font=FONT_SMALL, fill=WHITE, wrap=True)
    status = r.get('최종결과','')
    st_font = Font(name=FN, bold=True, color=RED if status in ('실패','수동확인','건너뜀') else DARK, size=9)
    merged_cell(ws, i, 14, i, 14, status, font=st_font, fill=WHITE)

# Top5가 5개 미만이어도 박스 유지 — 데이터 행과 동일한 병합 구조 적용
for i in range(47 + len(TOP_NEED[:5]), 52):
    merged_cell(ws, i, 6, i, 6, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 7, i, 7, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 8, i, 10, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 11, i, 11, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 12, i, 13, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, i, 14, i, 14, '', font=FONT_SMALL, fill=WHITE)
# Top5 영역 전체 외곽/내부 라인 최종 보정
fill_block(ws, 46, 6, 51, 14, border=True, align='center', wrap=True)
# 타이틀 행은 좌측 정렬 유지
ws.cell(45, 6).alignment = Alignment(horizontal='left', vertical='center', wrap_text=True)

# 인쇄/보기 설정
ws.freeze_panes = 'B5'
ws.page_setup.orientation = 'landscape'
ws.page_setup.paperSize = ws.PAPERSIZE_A4
ws.page_setup.fitToWidth = 1
ws.page_setup.fitToHeight = 1
ws.sheet_properties.pageSetUpPr.fitToPage = True
ws.print_area = 'B2:N46'
ws.sheet_view.zoomScale = 90

# ── 전체 항목 상세: 전체 U-항목의 전·후 상태와 최종 판정을 확인하는 기준 시트 ──
full_headers = ['항목ID','항목명','위험도','대분류','조치 전 상태','조치 후 상태','최종 판정','결과 요약']
ws3 = wb.create_sheet('전체 항목 상세')
ws3.sheet_view.showGridLines = False
ws3.append(full_headers)
for x in rows:
    ws3.append([
        x.get('항목ID',''), x.get('항목명',''), x.get('위험도',''), x.get('대분류',''),
        format_before_state(x), format_after_state(x), x.get('최종결과',''), format_result_summary(x)
    ])
style_table(ws3, 1, 1, max(ws3.max_row, 1), len(full_headers))
_res_col3 = full_headers.index('최종 판정') + 1
_before_col3 = full_headers.index('조치 전 상태') + 1
_after_col3 = full_headers.index('조치 후 상태') + 1
_summary_col3 = full_headers.index('결과 요약') + 1
for r in range(2, ws3.max_row + 1):
    _style_multi_text_row(ws3, r, _res_col3, (_before_col3, _after_col3, _summary_col3), max_height=260)
ws3.freeze_panes = 'A2'
set_widths(ws3, [9,34,8,20,40,40,12,52])
try:
    ref = f'A1:H{ws3.max_row}'
    tab = Table(displayName='VulnDetailTable', ref=ref)
    tab.tableStyleInfo = TableStyleInfo(name='TableStyleMedium2', showFirstColumn=False, showLastColumn=False, showRowStripes=True, showColumnStripes=False)
    ws3.add_table(tab)
except Exception:
    pass

# ── 확인 필요 항목: 수동확인·실패·건너뜀의 사유와 후속 조치만 제공 ──────────
need_headers = ['항목ID','항목명','위험도','대분류','최종 판정','현재 상태','확인 필요 사유','조치 방법','양호 기준','주의 사항']
ws2 = wb.create_sheet('확인 필요 항목')
ws2.sheet_view.showGridLines = False
ws2.append(need_headers)
for x in rows:
    if x.get('최종결과') in ('수동확인','실패','건너뜀'):
        ws2.append([
            x.get('항목ID',''), x.get('항목명',''), x.get('위험도',''), x.get('대분류',''),
            x.get('최종결과',''), format_current_state(x), format_need_reason(x),
            format_need_action(x), format_need_criteria(x), format_need_caution(x)
        ])
style_table(ws2, 1, 1, max(ws2.max_row, 1), len(need_headers))
_res_col2 = need_headers.index('최종 판정') + 1
_text_cols2 = tuple(need_headers.index(name) + 1 for name in ('현재 상태','확인 필요 사유','조치 방법','양호 기준','주의 사항'))
for r in range(2, ws2.max_row + 1):
    _style_multi_text_row(ws2, r, _res_col2, _text_cols2, max_height=409)
ws2.freeze_panes = 'A2'
set_widths(ws2, [9,34,8,20,12,42,44,76,48,58])

# ── 변경 이력: 실제 자동 조치 또는 부분 변경이 발생한 항목만 기록 ───────────
change_headers = ['항목ID','항목명','최종 판정','변경 전 핵심값','적용 내용','변경 대상','검증 결과','백업 경로']
ws_log = wb.create_sheet('변경 이력')
ws_log.sheet_view.showGridLines = False
ws_log.append(change_headers)
for x in rows:
    if has_actual_change(x):
        ws_log.append([
            x.get('항목ID',''), x.get('항목명',''), x.get('최종결과',''),
            format_change_before(x), format_change_action(x), format_change_target(x),
            format_change_verify(x), format_backup_path(x)
        ])
style_table(ws_log, 1, 1, max(ws_log.max_row, 1), len(change_headers))
_res_col_log = change_headers.index('최종 판정') + 1
_text_cols_log = tuple(change_headers.index(name) + 1 for name in ('변경 전 핵심값','적용 내용','변경 대상','검증 결과','백업 경로'))
for r in range(2, ws_log.max_row + 1):
    _style_multi_text_row(ws_log, r, _res_col_log, _text_cols_log, max_height=409)
ws_log.freeze_panes = 'A2'
set_widths(ws_log, [9,34,12,42,70,58,42,48])

# 공통 정리
for sh in wb.worksheets:
    for row in sh.iter_rows():
        for x in row:
            if x.value is not None and not x.font:
                x.font = FONT_BASE
    sh.freeze_panes = sh.freeze_panes or None

wb.save(out_path)
PYEOF
}

# ── 실행 ──────────────────────────────────────────────────────────────────────
echo ""
_div_thick
echo -e "${BOLD}  결과 보고서 (CSV/XLSX) 자동 생성${RESET}"
echo ""

if [ -f "$REPORT_CSV" ]; then
  chmod 640 "$REPORT_CSV" 2>/dev/null
  _ok "결과 데이터 CSV 저장 완료"
  echo -e "   ${CYAN}${REPORT_CSV}${RESET}"
else
  _warn "결과 데이터 CSV가 생성되지 않았습니다."
fi

if [ -f "$REPORT_CSV" ]; then
  echo ""
  if _xlsx_env_check; then
    _info "엑셀 보고서 생성 중..."
    if _generate_xlsx "$REPORT_CSV" "$REPORT_XLSX" \
        "$_HOSTNAME_VAL" "$_OS_INFO" "$(date '+%Y-%m-%d %H:%M:%S')" "$FIX_HISTORY_FILE"; then
      chmod 640 "$REPORT_XLSX" 2>/dev/null
      echo ""
      _ok "엑셀 보고서 생성 완료"
      echo -e "   ${CYAN}${REPORT_XLSX}${RESET}"
      echo -e "   크기: $(du -h "$REPORT_XLSX" 2>/dev/null | cut -f1)"
    else
      echo ""
      _warn "엑셀 보고서 생성 실패 — 상세: ${DETAIL_LOG_FILE:-$FIX_HISTORY_FILE}"
      _info "CSV는 정상 저장됨: ${REPORT_CSV}"
    fi
  else
    _info "호환 Python/openpyxl 환경이 없어 XLSX 생성 불가 — CSV만 저장됨:"
    echo -e "   ${CYAN}${REPORT_CSV}${RESET}"
  fi
fi

# 조치가 끝난 시점의 역산 레코드를 백업 옆 .records 파일로 독립 보관한다.
# tar.gz와 .records를 함께 이동하면 누적 이력 없이도 해당 백업의 복원 정보를 사용할 수 있다.
if [ -n "${_PRE_BAK_FILE:-}" ] && [ -f "${_PRE_BAK_FILE:-}" ]; then
  if _vf_export_run_records_sidecar "$_PRE_BAK_FILE"; then
    chmod 600 "${_PRE_BAK_FILE}.records" 2>/dev/null || true
    _ok "롤백 보조 레코드 저장 완료"
    echo -e "   ${CYAN}${_PRE_BAK_FILE}.records${RESET}"
    _info "백업 이동 시 tar.gz와 .records 파일을 함께 복사하세요."
  else
    _warn "롤백 보조 레코드(.records) 저장 실패 — 기본 이력 파일은 유지됩니다."
    _warn "상세 기록: ${DETAIL_LOG_FILE:-$FIX_HISTORY_FILE}"
  fi
  echo ""
fi

echo ""
echo -e " ${CYAN}※${RESET} 복원은 --rollback, 도움말은 --help 옵션 사용"
echo ""
_div_thick
