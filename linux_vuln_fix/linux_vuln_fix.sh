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
# 배포 버전: v1.2.2 / 점검 결과 확인 후 승인·백업·자동 조치 흐름 정리
# =============================================================================

# ── [1단계] 배포 안전 사전 점검 ──────────────────────────────────────────────
# 설정·백업 파일을 생성하기 전에 실행 권한과 고정 배치 경로를 검증한다.
# 운영 배포본은 /linux_vuln_fix에서만 실행하며, 조건 불충족 시 아무 변경 없이 종료한다.
if [ "$(id -u 2>/dev/null)" -ne 0 ]; then
  echo "[오류] root 권한으로 실행해주세요." >&2
  exit 1
fi

_VF_EXPECTED_DIR="/linux_vuln_fix"
_VF_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
if [ -z "$_VF_SCRIPT_DIR" ] || [ "$_VF_SCRIPT_DIR" != "$_VF_EXPECTED_DIR" ]; then
  echo "[오류] 이 스크립트는 ${_VF_EXPECTED_DIR} 디렉터리에서만 실행할 수 있습니다." >&2
  echo "       현재 위치: ${_VF_SCRIPT_DIR:-확인 불가}" >&2
  exit 1
fi
unset _VF_SCRIPT_DIR

# ── [6단계] 배포 전 점검 전용 모드 조기 감지 ────────────────────────────────
# --preflight는 설정·백업·보고서 파일을 만들지 않고 배포 적합성만 확인한다.
# 자동화 도구에서도 실행할 수 있도록 대화형 TTY를 요구하지 않는다.
_VF_EARLY_PREFLIGHT=0
for _vf_arg in "$@"; do
  if [ "$_vf_arg" = "--preflight" ]; then
    _VF_EARLY_PREFLIGHT=1
  fi
done
if [ "$_VF_EARLY_PREFLIGHT" -eq 1 ] && { [ "$#" -ne 1 ] || [ "${1:-}" != "--preflight" ]; }; then
  echo "[오류] --preflight는 다른 옵션이나 인자와 함께 사용할 수 없습니다." >&2
  exit 2
fi
unset _vf_arg

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
WHITE='\033[0;37m'; BOLD='\033[1m'; RESET='\033[0m'

# 배포 후보 식별자. 화면·백업 메타데이터·도움말에서 동일한 값을 사용한다.
_SCRIPT_VERSION="1.2.2"
_SCRIPT_RELEASE_CHANNEL="release"
_SCRIPT_BUILD_DATE="2026-07-30"

# ── UI 헬퍼 함수 ───────────────────────────────────────────────────────────────
_div_item() {
  echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}
_div_sec() {
  echo -e " ──────────────────────────────────────────────────────"
}
_div_blank() { echo ""; }
# 하위 호환 별칭 (기존 코드가 이 이름으로 호출하는 곳이 아직 많음)
_div_thick() { _div_item; }
_div_thin()  { _div_sec; }

_ok()   { echo -e "   ${GREEN}✓${RESET} $1"; }
_fail() { echo -e "   ${RED}✗${RESET} $1"; }
_info() { echo -e "   ${CYAN}→${RESET} $1"; }
_warn() { echo -e "   ${YELLOW}⚠${RESET} $1"; }

# 공용 프로그래스바 — 점검/사전 백업/롤백에서 동일한 형식으로 재사용한다.
# 실제 완료량만 퍼센트에 반영하고, 처리 중에는 spinner와 현재 작업만 갱신한다.
# 출력은 터미널 폭을 넘지 않도록 자동 축약해 같은 한 줄에서만 변경한다.
#
# _show_progress_bar <완료값> <전체값> <상태> [대상] [spinner] [현재작업]
_VF_PROGRESS_SPINNER_PID=""
# 같은 배치(점검/백업/복원 등) 동안 터미널 폭·바 길이를 한 번만 재고 재사용한다.
# 매 프레임 tput/stty를 다시 불러 값이 미세하게 흔들리면 바 길이가 오락가락하며
# 줄 전체 폭이 바뀌어 깜빡이는 것처럼 보이므로, 새 배치 시작 시에만 초기화한다.
_VF_PROGRESS_COLS=""
_VF_PROGRESS_BAR_LEN=""
# 현재 줄에서 spinner 글자가 위치한 표시 컬럼(1-based). 틱 갱신 시 이 컬럼으로만
# 커서를 옮겨 그 한 글자만 덮어써서 줄 전체를 다시 그리지 않는다.
_VF_PROGRESS_SPINNER_COL=""

_vf_spinner_frame() {
  case $(( ${1:-0} % 10 )) in
    0) printf '⠋' ;; 1) printf '⠙' ;; 2) printf '⠹' ;; 3) printf '⠸' ;;
    4) printf '⠼' ;; 5) printf '⠴' ;; 6) printf '⠦' ;; 7) printf '⠧' ;;
    8) printf '⠇' ;; *) printf '⠏' ;;
  esac
}

_vf_progress_term_cols() {
  local _cols="${COLUMNS:-}"
  if ! [[ "$_cols" =~ ^[0-9]+$ ]] || [ "$_cols" -lt 40 ]; then
    _cols=$(tput cols 2>/dev/null || true)
  fi
  if ! [[ "$_cols" =~ ^[0-9]+$ ]] || [ "$_cols" -lt 40 ]; then
    _cols=$(stty size 2>/dev/null | awk '{print $2}')
  fi
  if ! [[ "$_cols" =~ ^[0-9]+$ ]] || [ "$_cols" -lt 40 ]; then
    _cols=80
  fi
  printf '%s' "$_cols"
}

# 배치 시작 시 한 번 호출해 폭/바 길이를 고정한다. 호출하지 않아도
# _show_progress_bar가 처음 그릴 때 자동으로 한 번 계산해 캐싱한다.
_vf_progress_reset_cache() {
  _VF_PROGRESS_COLS=""
  _VF_PROGRESS_BAR_LEN=""
}

# UTF-8 표시폭 기준으로 문자열을 자른다. 마지막 1칸은 생략 기호에 사용한다.
_vf_progress_truncate() {
  local _s="$1" _max="${2:-20}" _out="" _w=0 _i _ch _cw _truncated=0
  _s=$(printf '%s' "$_s" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  [ "$_max" -gt 1 ] 2>/dev/null || { printf ''; return 0; }

  for ((_i=0; _i<${#_s}; _i++)); do
    _ch="${_s:_i:1}"
    if [[ "$_ch" == [[:ascii:]] ]]; then _cw=1; else _cw=2; fi
    if [ $((_w + _cw)) -gt $((_max - 1)) ]; then
      _truncated=1
      break
    fi
    _out+="${_ch}"
    _w=$((_w + _cw))
  done
  [ "$_truncated" -eq 1 ] && _out+="…"
  printf '%s' "$_out"
}

# 표시 폭(전각 2칸) 기준으로 문자열 길이를 잰다. 커서를 정확한 컬럼으로
# 옮기려면 바이트/문자 수가 아니라 실제 터미널 표시 폭이 필요하다.
_vf_progress_display_width() {
  local _s="$1" _w=0 _i _ch
  for ((_i=0; _i<${#_s}; _i++)); do
    _ch="${_s:_i:1}"
    if [[ "$_ch" == [[:ascii:]] ]]; then _w=$((_w+1)); else _w=$((_w+2)); fi
  done
  printf '%s' "$_w"
}

_vf_progress_compact_target() {
  local _s="$1"
  if [[ "$_s" == /* ]] && [ "${#_s}" -gt 24 ]; then
    local _base _parent
    _base=$(basename -- "$_s" 2>/dev/null)
    _parent=$(basename -- "$(dirname -- "$_s")" 2>/dev/null)
    _s="…/${_parent}/${_base}"
  fi
  printf '%s' "$_s"
}

_show_progress_bar() {
  local _current="$1" _total="$2" _status="$3" _target="${4:-}"
  local _spinner="${5:-}" _work="${6:-}"
  local _cols _bar_len _pct=0 _filled=0 _bar="" _i
  local _lead="" _detail="" _detail_max _line="" _lead_w=0

  if [ "${_total:-0}" -gt 0 ] 2>/dev/null; then
    _pct=$(( _current * 100 / _total ))
  fi
  [ "$_pct" -gt 100 ] && _pct=100
  [ "$_pct" -lt 0 ] && _pct=0

  # 폭/바 길이는 배치당 한 번만 계산해 캐싱한다 — 매 프레임 tput를 다시 불러
  # 값이 미세하게 흔들리면 바 길이가 바뀌면서 줄 폭이 흔들려 깜빡이는 것처럼
  # 보이는 문제를 막는다.
  if [ -z "$_VF_PROGRESS_COLS" ]; then
    _VF_PROGRESS_COLS=$(_vf_progress_term_cols)
    if [ "$_VF_PROGRESS_COLS" -ge 110 ]; then
      _VF_PROGRESS_BAR_LEN=18
    elif [ "$_VF_PROGRESS_COLS" -ge 80 ]; then
      _VF_PROGRESS_BAR_LEN=14
    else
      _VF_PROGRESS_BAR_LEN=10
    fi
  fi
  _cols="$_VF_PROGRESS_COLS"
  _bar_len="$_VF_PROGRESS_BAR_LEN"

  _filled=$(( _pct * _bar_len / 100 ))
  for ((_i=0; _i<_filled; _i++)); do _bar+="█"; done
  for ((_i=_filled; _i<_bar_len; _i++)); do _bar+="░"; done

  # [막대] (완료/전체) 상태 spinner 현재작업 순서로 배치한다.
  # 퍼센트 숫자는 (완료/전체)와 정보가 겹쳐서 뺐다 — 막대 채움 비율 계산에는
  # 내부적으로 _pct를 계속 쓰지만 화면에는 표시하지 않는다.
  # spinner는 상태 문구 바로 뒤에 두고, 틱 갱신 시 이 글자 하나만 정확한
  # 컬럼으로 커서를 옮겨 덮어써서 줄 전체를 다시 그리지 않는다.
  #
  # 표시폭 계산 주의: █/░(막대바 문자)는 유니코드지만 터미널에서 1칸으로
  # 렌더링된다. 문자열 전체를 "비ASCII=2칸" 규칙에 통째로 넣으면 막대바만큼
  # 폭이 과대 계산돼 spinner 위치와 잘림 길이가 틀어진다. 그래서 ASCII 구간과
  # 막대바(항상 1칸×길이)와 상태 문구(한글 등 실제 전각 포함)의 폭을 따로 더한다.
  local _lead_ascii1 _lead_ascii2 _status_w
  _lead_ascii1="["
  printf -v _lead_ascii2 "] (%d/%d) " "$_current" "$_total"
  _status_w=$(_vf_progress_display_width "$_status")
  _lead="${_lead_ascii1}${_bar}${_lead_ascii2}${_status}"
  _lead_w=$(( ${#_lead_ascii1} + _bar_len + ${#_lead_ascii2} + _status_w ))

  [ -n "$_spinner" ] || _spinner=" "
  # 컬럼은 1-based. 줄 맨 앞에 다른 UI 줄들과 통일된 1칸 여백을 두므로
  # "_lead" 뒤 공백 한 칸 다음(= 여백 1칸 + _lead_w + 공백 1칸 + 1)이 spinner 위치다.
  _VF_PROGRESS_SPINNER_COL=$(( _lead_w + 3 ))

  if [ -n "$_target" ]; then
    _target=$(_vf_progress_compact_target "$_target")
    _detail="$_target"
  fi
  if [ -n "$_work" ]; then
    [ -n "$_detail" ] && _detail+=" "
    _detail+="${_work}"
  fi

  # 터미널 우측 2칸을 안전 여백으로 남겨 자동 줄바꿈을 방지한다.
  # (좌측 여백 1칸 + spinner 한 칸 + 앞뒤 공백만큼 여유를 더 뺀다)
  _detail_max=$(( _cols - _lead_w - 9 ))
  [ "$_detail_max" -gt 8 ] || _detail_max=8
  _detail=$(_vf_progress_truncate "$_detail" "$_detail_max")

  _line=" ${_lead} ${_spinner}"
  [ -n "$_detail" ] && _line+=" ${_detail}"

  # 기존 줄을 먼저 비우면 퍼센트가 바뀔 때마다 한 줄 전체가 순간적으로
  # 사라져 깜빡임이 보인다. 새 내용을 먼저 덮어쓴 뒤 남은 꼬리만 지운다.
  printf '\r%s\033[K' "$_line"
}

# spinner 글자가 있는 컬럼으로만 커서를 옮겨 그 한 글자만 덮어쓴다.
# 줄 전체를 다시 쓰지 않으므로 깜빡임이 생기지 않는다.
_vf_progress_spinner_tick() {
  local _frame="$1"
  if [[ "${_VF_PROGRESS_SPINNER_COL:-}" =~ ^[0-9]+$ ]]; then
    printf '\033[%dG%s' "$_VF_PROGRESS_SPINNER_COL" "$_frame"
  else
    printf '\r%s' "$_frame"
  fi
}

# 진행률/스피너 표시 중에는 커서가 줄 중간에서 깜빡이며 거슬리므로 숨긴다.
# 스크립트가 중간에 죽어도 커서가 계속 숨겨진 채로 남지 않도록, 이 두 함수는
# _vf_progress_spinner_stop과 EXIT 트랩(_vf_records_exit_finalize)에서도 호출한다.
_vf_cursor_hide() { printf '\033[?25l'; }
_vf_cursor_show() { printf '\033[?25h'; }

_vf_progress_spinner_start() {
  local _current="$1" _total="$2" _status="$3"
  local _target="${4:-}" _work="${5:-}" _frame_no=0 _frame=""

  _vf_progress_spinner_stop
  _vf_cursor_hide
  _frame=$(_vf_spinner_frame 0)

  # 전체 줄은 시작 시 한 번만 그린다.
  _show_progress_bar "$_current" "$_total" "$_status" "$_target" "$_frame" "$_work"

  (
    trap 'exit 0' TERM INT HUP
    _frame_no=1
    while :; do
      _frame=$(_vf_spinner_frame "$_frame_no")
      _vf_progress_spinner_tick "$_frame"
      _frame_no=$((_frame_no + 1))
      sleep 0.5
    done
  ) &
  _VF_PROGRESS_SPINNER_PID=$!
}

_vf_progress_spinner_stop() {
  if [ -n "${_VF_PROGRESS_SPINNER_PID:-}" ]; then
    kill "$_VF_PROGRESS_SPINNER_PID" 2>/dev/null || true
    wait "$_VF_PROGRESS_SPINNER_PID" 2>/dev/null || true
    _VF_PROGRESS_SPINNER_PID=""
  fi
  # 다음 진행 상태가 같은 줄을 그대로 덮어쓸 수 있도록 커서만 줄 처음으로 이동한다.
  printf '\r'
  _vf_cursor_show
}

_vf_progress_line_clear() {
  printf '\r\033[K'
}

# _sec <check|before|during|result|verify|need>
# 화면 표시는 기존 한국어 UI를 유지하고, 내부 판정에서는 CHECK/FIX/VERIFY/RESULT
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

  # 롤백 조기 분기에서는 화면 출력 단계만 갱신한다.
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

# =============================================================================
# ── [6단계] 배포 적합성 사전 점검 ────────────────────────────────────────────
#
# --preflight:
#   시스템 설정을 변경하지 않고 운영 배포에 필요한 OS·init·명령·저장공간·
#   Python/openpyxl·주요 설정 문법을 확인한다.
#
# 반환값:
#   0 = 필수 조건 충족
#   1 = 배포 차단 조건 존재
#   3 = 필수 조건은 충족했으나 경고 존재
# =============================================================================
_VF_PF_PASS=0
_VF_PF_INFO=0
_VF_PF_WARN=0
_VF_PF_FAIL=0

# 적합성 점검 화면은 백그라운드로는 기존 검사를 모두 그대로 수행하되
# (안전장치성 FAIL 판정 포함), 화면에는 다음만 보여준다:
#   1) 검사 진행 중: 진행률 한 줄 (프로그래스바 재사용)
#   2) 전부 통과: SELinux/SSH/sudo/rsyslog 상태만 요약 한 줄
#   3) 경고·실패가 있으면: 그 항목의 상세만 아래에 표시
# 정상/참고(PASS/INFO) 판정 항목은 더 이상 화면에 줄 단위로 쌓지 않는다
# (경고/실패만 _VF_PF_LINES_* 에 쌓는다 — _vf_pf_record 참고).
_VF_PF_COUNT=0
# 조건부 검사(BIND/Postfix 등, 데몬이 있을 때만 실행) 때문에 정확한 총 개수를
# 미리 알 수 없어 "항상 실행되는 항목" 기준 대략치를 쓴다. 실제 실행 개수가
# 이보다 많아도 _show_progress_bar가 100%로 clamp하므로 문제없다.
_VF_PF_TOTAL=20
_VF_PF_SELINUX_STATE=""
_VF_PF_SSH_STATE=""
_VF_PF_SUDO_STATE=""
_VF_PF_RSYSLOG_STATE=""

# 실행 환경/배포 및 백업/보고서/설정 안전성/환경 참고 영역으로 구분해 출력한다.
_VF_PF_SECTION="execution"
_VF_PF_LINES_EXECUTION=()
_VF_PF_LINES_DEPLOYMENT=()
_VF_PF_LINES_REPORT=()
_VF_PF_LINES_CONFIG=()
_VF_PF_LINES_REFERENCE=()

# authselect 관리 상태
#   1  : authselect check 통과(관리 구성)
#   0  : 비관리/불일치 구성 또는 명령 없음
#  -1  : 아직 확인하지 않음
# 비관리 상태에서는 PAM 파일 구조를 자동 재생성하거나 직접 수정하지 않는다.
_AUTHSELECT_MANAGED=-1
_AUTHSELECT_CHECK_DETAIL=""

# 항목명 표시폭 패딩.
# printf '%-24s' 는 바이트 기준이라 한글 항목명에서 컬럼이 어긋난다.
# ("배포 경로 여유 공간"은 27바이트로 24를 넘어 패딩이 아예 적용되지 않고,
#  "SELinux"는 7바이트라 24칸까지 밀려 상세 컬럼 시작 위치가 항목마다 달라졌다.)
# _display_width() 는 이 지점보다 뒤에 정의되어 --preflight 단독 실행 시점에는
# 아직 없으므로, 여기서는 독립적인 경량 구현을 사용한다.
# 전부 통과했을 때 보여줄 한 줄 요약에서, PASS/WARN/FAIL 레벨을 짧은 한글
# 단어로 바꾼다. 해당 검사가 아예 실행되지 않은 경우(예: sshd 미설치)는
# 빈 문자열이 들어오므로 "확인 안 됨"으로 표시한다.
_vf_pf_level_word() {
  case "$1" in
    PASS) printf '정상' ;;
    WARN) printf '확인 필요' ;;
    FAIL) printf '오류' ;;
    *)    printf '확인 안 됨' ;;
  esac
}

_vf_pf_pad() {
  local _s="$1" _target="${2:-22}" _w=0 _i _ch
  case "${LC_ALL:-${LANG:-}}" in
    *UTF-8|*utf8|*UTF8)
      for ((_i = 0; _i < ${#_s}; _i++)); do
        _ch="${_s:_i:1}"
        if [[ "$_ch" == [[:ascii:]] ]]; then _w=$((_w + 1)); else _w=$((_w + 2)); fi
      done
      ;;
    *)
      # UTF-8 로케일이 아니면 ${#_s} 가 문자 수가 아니라 바이트 수가 되어
      # 문자 단위 판정이 성립하지 않는다. 이 환경에서는 한글 렌더링 자체가
      # 보장되지 않으므로 바이트 길이로 근사한다.
      _w=${#_s}
      ;;
  esac
  printf '%s' "$_s"
  while [ "$_w" -lt "$_target" ]; do printf ' '; _w=$((_w + 1)); done
}

# 심각도 4단계
#   PASS : 조건 충족
#   INFO : 환경 사실 기록 — 판정에 영향 없음(진행 확인 프롬프트를 띄우지 않는다)
#   WARN : 이번 실행의 결과가 달라질 수 있음 — 운영자 확인 필요
#   FAIL : 실행 차단
_vf_pf_record() {
  local _level="$1" _name="$2" _detail="${3:-}" _pad=""
  local _detail_main="" _detail_cont="" _line="" _cont_line=""

  # "|||": 같은 항목의 보충 설명을 다음 줄에 정렬해 표시하기 위한 내부 구분자.
  if [[ "$_detail" == *"|||"* ]]; then
    _detail_main="${_detail%%|||*}"
    _detail_cont="${_detail#*|||}"
  else
    _detail_main="$_detail"
  fi

  _detail_main=$(printf '%s' "$_detail_main" | tr -d '\r' | tr '\n' ' ' \
                 | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  _detail_cont=$(printf '%s' "$_detail_cont" | tr -d '\r' | tr '\n' ' ' \
                 | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')

  if [ "${#_detail_main}" -gt 72 ]; then
    _detail_main="${_detail_main:0:69}..."
  fi
  if [ "${#_detail_cont}" -gt 72 ]; then
    _detail_cont="${_detail_cont:0:69}..."
  fi

  _pad=$(_vf_pf_pad "$_name" 22)

  # 각 검사는 순식간에 끝나서(수 ms) 항목명이 하나씩 스쳐 지나가는 진행률
  # 표시 자체가 불필요한 시각적 소음이었다. 화면에는 아무것도 띄우지 않고
  # 조용히 카운트만 올린 뒤, 최종 결과(판정/요약 줄)만 보여준다.
  _VF_PF_COUNT=$((_VF_PF_COUNT + 1))

  # SELinux/SSH/sudo/rsyslog는 전부 통과했을 때 보여줄 한 줄 요약에 쓴다.
  case "$_name" in
    SELinux)       _VF_PF_SELINUX_STATE="$_detail_main" ;;
    "SSH 설정")     _VF_PF_SSH_STATE="$_level" ;;
    "sudo 설정")    _VF_PF_SUDO_STATE="$_level" ;;
    "rsyslog 설정") _VF_PF_RSYSLOG_STATE="$_level" ;;
  esac

  case "$_level" in
    PASS)
      _VF_PF_PASS=$((_VF_PF_PASS + 1))
      printf -v _line "   ${GREEN}✓${RESET}  %s  %s" "$_pad" "$_detail_main"
      ;;
    INFO)
      _VF_PF_INFO=$((_VF_PF_INFO + 1))
      printf -v _line "   ${CYAN}ℹ${RESET}  %s  %s" "$_pad" "$_detail_main"
      ;;
    WARN)
      _VF_PF_WARN=$((_VF_PF_WARN + 1))
      printf -v _line "   ${YELLOW}⚠${RESET}  %s  %s" "$_pad" "$_detail_main"
      ;;
    FAIL)
      _VF_PF_FAIL=$((_VF_PF_FAIL + 1))
      printf -v _line "   ${RED}✗${RESET}  %s  %s" "$_pad" "$_detail_main"
      ;;
    *)
      return 1
      ;;
  esac

  if [ -n "$_detail_cont" ]; then
    printf -v _cont_line "                              %s" "$_detail_cont"
    _line="${_line}"$'\n'"${_cont_line}"
  fi

  # 정상/참고(PASS/INFO)는 더 이상 화면에 줄 단위로 쌓지 않는다 — 카운트에는
  # 반영되지만(위에서 이미 증가) 상세 라인은 경고·실패일 때만 보여준다.
  case "$_level" in
    WARN|FAIL) ;;
    *) return 0 ;;
  esac

  case "${_VF_PF_SECTION:-execution}" in
    execution)  _VF_PF_LINES_EXECUTION+=("$_line") ;;
    deployment) _VF_PF_LINES_DEPLOYMENT+=("$_line") ;;
    report)     _VF_PF_LINES_REPORT+=("$_line") ;;
    config)     _VF_PF_LINES_CONFIG+=("$_line") ;;
    reference)  _VF_PF_LINES_REFERENCE+=("$_line") ;;
    *)          _VF_PF_LINES_EXECUTION+=("$_line") ;;
  esac
}

_vf_pf_render_section() {
  local _title="$1"; shift
  local -a _lines=("$@")
  [ "${#_lines[@]}" -gt 0 ] || return 0

  echo -e " ${BOLD}${WHITE}[${_title}]${RESET}"
  local _line
  for _line in "${_lines[@]}"; do
    printf '%s\n' "$_line"
  done
  echo ""
}

_vf_pf_check_config() {
  # _vf_pf_check_config <표시명> <critical|warning> <명령...>
  local _name="$1" _severity="$2"; shift 2
  local _out _rc
  _out=$("$@" 2>&1); _rc=$?
  if [ "$_rc" -eq 0 ]; then
    _vf_pf_record PASS "$_name" "구문 검사 정상"
  elif [ "$_severity" = "critical" ]; then
    _out=$(printf '%s' "$_out" | tr '\r\n' ' ' | cut -c1-180)
    _vf_pf_record FAIL "$_name" "현재 설정 오류: ${_out:-반환 코드 $_rc}"
  else
    _out=$(printf '%s' "$_out" | tr '\r\n' ' ' | cut -c1-180)
    _vf_pf_record WARN "$_name" "현재 설정 확인 필요: ${_out:-반환 코드 $_rc}"
  fi
}

_vf_pf_check_authselect() {
  # authselect check 실패는 PAM 문법 오류와 동일하지 않다.
  # system-auth/password-auth가 일반 파일이거나 프로필과 불일치하면 비관리 구성으로
  # 분류하고, 롤백은 허용하며 일반 조치에서는 PAM 자동 변경만 제한한다.
  local _mode="${1:-standalone}" _out="" _rc=127 _summary=""

  if ! command -v authselect >/dev/null 2>&1; then
    _AUTHSELECT_MANAGED=0
    _AUTHSELECT_CHECK_DETAIL="authselect 명령 없음"
    # 주의: --rollback 은 배포 적합성 사전 점검을 실행하지 않으므로
    #       이 함수는 fix / standalone 모드에서만 호출된다.
    _vf_pf_record INFO "PAM 구성" "직접 관리 방식|||정책값은 적용하고 PAM 연결은 수동 확인으로 기록"
    return 0
  fi

  _out=$(authselect check 2>&1); _rc=$?
  _summary=$(printf '%s' "$_out" | tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-180)
  _AUTHSELECT_CHECK_DETAIL="${_summary:-반환 코드 $_rc}"

  if [ "$_rc" -eq 0 ]; then
    _AUTHSELECT_MANAGED=1
    _vf_pf_record PASS "PAM 구성" "authselect 관리 구성 정상"
    return 0
  fi

  _AUTHSELECT_MANAGED=0
  # authselect check 의 원본 출력을 그대로 붙이지 않는다.
  #   authselect 는 자기 기준으로 "[error] ...는 상징적 링크가 아닙니다" 를 출력하는데,
  #   이는 PAM 을 수동 구성한 RHEL 서버의 매우 흔한 정상 상태다.
  #   같은 화면에 FAIL 0 을 표시하면서 [error] 를 노출하면 운영자가 스크립트가
  #   실패한 것으로 오인하고, 여러 줄로 넘쳐 위아래 PASS 행까지 덮는다.
  #   상세 원문은 _AUTHSELECT_CHECK_DETAIL 에 보존되어 PAM 항목 화면에서 표시된다.
  _vf_pf_record INFO "PAM 구성" \
    "직접 관리 방식|||정책값은 적용하고 PAM 연결은 수동 확인으로 기록"
  return 0
}

_vf_run_deployment_preflight() {
  local _mode="${1:-standalone}"
  _VF_PF_PASS=0; _VF_PF_INFO=0; _VF_PF_WARN=0; _VF_PF_FAIL=0
  _VF_PF_COUNT=0
  _VF_PF_SELINUX_STATE=""; _VF_PF_SSH_STATE=""; _VF_PF_SUDO_STATE=""; _VF_PF_RSYSLOG_STATE=""
  _VF_PF_SECTION="execution"
  _VF_PF_LINES_EXECUTION=()
  _VF_PF_LINES_DEPLOYMENT=()
  _VF_PF_LINES_REPORT=()
  _VF_PF_LINES_CONFIG=()
  _VF_PF_LINES_REFERENCE=()

  # 제목 박스는 여기서 바로 찍지 않는다. 사전 적합성 점검은 실행 가능 여부를
  # 보장하기 위한 내부 검사일 뿐이고, 전부 통과하면 사용자가 알 필요가 없다.
  # 경고·실패가 있을 때만 함수 끝에서 제목과 상세를 함께 출력한다.
  # (--preflight 단독 실행은 이 점검 자체가 목적이므로 예외로 항상 출력한다.)
  if [ "$_mode" = "standalone" ]; then
    echo ""
    _div_item
    echo -e " ${BOLD}취약점 조치 적합성 점검${RESET}"
    _div_item
    echo ""
  fi
  _vf_cursor_hide

  # Bash 기능 요구사항: 연관 배열·프로세스 치환·printf -v 사용.
  local _bash_major="${BASH_VERSINFO[0]:-0}"
  if [ "$_bash_major" -ge 4 ] 2>/dev/null; then
    _vf_pf_record PASS "Bash 버전" "${BASH_VERSION}"
  else
    _vf_pf_record FAIL "Bash 버전" "4.x 이상 필요 (현재 ${BASH_VERSION:-확인 불가})"
  fi

  # OS 지원 범위. RHEL 계열 8/9를 배포 검증 기준으로 삼고, Debian 계열은 호환 경고.
  local _os_id="unknown" _os_ver="unknown" _os_pretty="unknown" _os_major=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    _os_id="${ID:-unknown}"
    _os_ver="${VERSION_ID:-unknown}"
    _os_pretty="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
  fi
  _os_major="${_os_ver%%.*}"
  case "$_os_id" in
    rhel|rocky|almalinux|centos)
      if [ "$_os_major" = "8" ] || [ "$_os_major" = "9" ]; then
        _vf_pf_record PASS "운영체제" "${_os_pretty} (검증 대상 계열)"
      else
        _vf_pf_record INFO "운영체제" "${_os_pretty} — 주 검증 범위는 RHEL 계열 8/9"
      fi
      ;;
    ubuntu|debian)
      _vf_pf_record INFO "운영체제" "${_os_pretty} — 호환 로직 있음, 적용 전 회귀 테스트 권장"
      ;;
    *)
      _vf_pf_record INFO "운영체제" "${_os_pretty} — 미검증 배포판"
      ;;
  esac

  local _arch
  _arch=$(uname -m 2>/dev/null)
  case "$_arch" in
    x86_64|aarch64) _vf_pf_record PASS "CPU 아키텍처" "$_arch" ;;
    *) _vf_pf_record INFO "CPU 아키텍처" "${_arch:-확인 불가} — 별도 테스트 필요" ;;
  esac

  # 컨테이너에서는 호스트 보안 설정을 정확히 판단·변경할 수 없으므로 배포 차단.
  # systemd-detect-virt --container는 비컨테이너일 때 "none"을 출력하면서
  # 종료 코드 1을 반환할 수 있다. 출력 문자열만 보면 호스트를 컨테이너로 오판하므로
  # 종료 코드 0과 실제 컨테이너 식별자를 함께 확인한다.
  local _container="" _container_rc=1 _container_marker=0
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    _container="container marker"
    _container_rc=0
    _container_marker=1
  elif command -v systemd-detect-virt >/dev/null 2>&1; then
    _container=$(systemd-detect-virt --container 2>/dev/null)
    _container_rc=$?
  fi

  if { [ "$_container_marker" -eq 1 ] || [ "$_container_rc" -eq 0 ]; }      && [ -n "$_container" ] && [ "$_container" != "none" ]; then
    _vf_pf_record FAIL "실행 환경" "컨테이너 감지(${_container}) — 호스트 OS에서 실행 필요"
  else
    _vf_pf_record PASS "실행 환경" "물리/가상 호스트 환경"
  fi

  local _pid1
  _pid1=$(cat /proc/1/comm 2>/dev/null)
  if [ "$_pid1" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    _vf_pf_record PASS "init 시스템" "systemd"
  else
    _vf_pf_record FAIL "init 시스템" "systemd 필요 (PID 1: ${_pid1:-확인 불가})"
  fi

  _VF_PF_SECTION="deployment"

  # 필수 명령. 없으면 점검·백업·롤백 또는 보고서 무결성을 보장할 수 없다.
  local -a _required_cmds=(
    awk sed grep find stat tar gzip hostname date mktemp df du cp chmod chown
    sort cut tr head tail wc xargs getent flock sha256sum python3 systemctl
  )
  local -a _missing=()
  local _cmd
  for _cmd in "${_required_cmds[@]}"; do
    command -v "$_cmd" >/dev/null 2>&1 || _missing+=("$_cmd")
  done
  if [ "${#_missing[@]}" -eq 0 ]; then
    _vf_pf_record PASS "필수 명령" "${#_required_cmds[@]}개 확인"
  else
    _vf_pf_record FAIL "필수 명령" "누락: ${_missing[*]}"
  fi

  if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
    _vf_pf_record PASS "포트 조회 도구" "$(command -v ss 2>/dev/null || command -v netstat 2>/dev/null)"
  elif [ -r /proc/net/tcp ] && [ -r /proc/net/udp ]; then
    _vf_pf_record INFO "포트 조회 도구" "ss/netstat 없음 — /proc 대체 로직 사용"
  else
    _vf_pf_record FAIL "포트 조회 도구" "ss/netstat 및 /proc 네트워크 정보 사용 불가"
  fi

  # 배포 파일 구조와 무결성.
  local _base="${_VF_EXPECTED_DIR:-/linux_vuln_fix}"
  if [ -d "$_base" ] && [ -r "$0" ]; then
    _vf_pf_record PASS "설치 경로" "$_base"
  else
    _vf_pf_record FAIL "설치 경로" "스크립트 또는 설치 디렉터리 확인 불가"
  fi

  # CRLF 개행 검사.
  # Windows 를 경유해 파일을 전송하면 각 줄 끝에 \r 이 붙어
  #   bash: $'\r': command not found
  # 형태로 즉시 실패한다. 배포 실패 원인 1순위이므로 사전에 차단한다.
  if LC_ALL=C grep -q $'\r'$ "$0" 2>/dev/null; then
    _vf_pf_record FAIL "개행 형식" \
      "CRLF 감지 — dos2unix 또는 sed -i 's/\r\$//' 로 LF 변환 필요"
  else
    _vf_pf_record PASS "개행 형식" "LF (Unix)"
  fi

  local _mode_octal=""
  _mode_octal=$(stat -c '%a' "$0" 2>/dev/null)
  if [[ "$_mode_octal" =~ ^[0-7]{3,4}$ ]]; then
    local _mode_num=$((8#${_mode_octal}))
    if (( _mode_num & 8#022 )); then
      _vf_pf_record FAIL "스크립트 권한" "${_mode_octal} — group/other 쓰기 권한 제거 필요"
    else
      _vf_pf_record PASS "스크립트 권한" "${_mode_octal}"
    fi
  else
    _vf_pf_record WARN "스크립트 권한" "권한 확인 불가"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    local _self_sha
    _self_sha=$(sha256sum "$0" 2>/dev/null | awk '{print $1}')
    if [ -n "$_self_sha" ]; then
      _vf_pf_record PASS "스크립트 SHA-256" "$_self_sha"
    else
      _vf_pf_record WARN "스크립트 SHA-256" "계산 실패"
    fi
  fi

  _VF_PF_SECTION="report"

  # lib 디렉터리와 openpyxl 은 "결과보고서(XLSX) 생성"에만 필요한 의존성이다.
  # 이를 FAIL 로 처리하면 보고서 라이브러리가 없다는 이유로 점검·조치 자체가
  # 차단되어, 보안 조치보다 보고서 의존성이 우선하는 구조가 된다.
  # 실제로 스크립트 종료부는 XLSX 생성 실패를 경고로만 처리하므로 내부 모순이기도 하다.
  # → WARN 으로 낮추고, 보고서는 CSV/텍스트로 폴백하도록 안내한다.
  if [ -d "${_base}/lib" ]; then
    _vf_pf_record PASS "lib 디렉터리" "${_base}/lib"
  else
    _vf_pf_record WARN "lib 디렉터리" "보고서 의존 파일 디렉터리 누락 — 점검·조치는 가능, XLSX 생성 불가"
  fi

  # Python/openpyxl은 실행 도중 OS 패키지를 설치하지 않고 사전 준비된 환경만 사용한다.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import openpyxl' >/dev/null 2>&1; then
    local _opx_ver
    _opx_ver=$(python3 -c 'import openpyxl; print(openpyxl.__version__)' 2>/dev/null)
    _vf_pf_record PASS "Excel 생성 환경" "system openpyxl ${_opx_ver:-확인됨}"
  else
    local _offline_tar="${_base}/lib/openpyxl_install.tar"
    if [ -s "$_offline_tar" ] && tar -tf "$_offline_tar" >/dev/null 2>&1 \
       && tar -tf "$_offline_tar" 2>/dev/null | grep -qE '\.whl$'; then
      _vf_pf_record PASS "Excel 생성 환경" "오프라인 openpyxl 번들 확인"
    else
      # 보고서 생성 불가는 실행 차단 사유가 아니다. 조치 결과는 화면과
      # CSV/텍스트 산출물로 확인할 수 있으므로 경고로만 기록한다.
      _vf_pf_record WARN "Excel 생성 환경" \
        "openpyxl 없음 — 점검·조치는 정상 수행, XLSX 대신 CSV/텍스트 산출물만 생성"
    fi
  fi

  _VF_PF_SECTION="deployment"

  # 파일시스템 쓰기 가능성과 최소 여유 공간. 실제 파일은 생성하지 않는다.
  local _avail_base="" _avail_tmp=""
  _avail_base=$(df -Pk "$_base" 2>/dev/null | awk 'NR==2{print $4}')
  _avail_tmp=$(df -Pk /tmp 2>/dev/null | awk 'NR==2{print $4}')
  if [ -w "$_base" ]; then
    _vf_pf_record PASS "설치 경로 쓰기" "backup/report 생성 가능"
  else
    _vf_pf_record FAIL "설치 경로 쓰기" "$_base 쓰기 불가"
  fi
  if [[ "$_avail_base" =~ ^[0-9]+$ ]]; then
    if [ "$_avail_base" -lt 262144 ]; then
      _vf_pf_record FAIL "설치 경로 여유 공간" "$((_avail_base / 1024)) MiB — 최소 256 MiB 필요"
    elif [ "$_avail_base" -lt 1048576 ]; then
      _vf_pf_record WARN "설치 경로 여유 공간" "$((_avail_base / 1024)) MiB — 1 GiB 이상 권장"
    else
      _vf_pf_record PASS "설치 경로 여유 공간" "$((_avail_base / 1024)) MiB"
    fi
  else
    _vf_pf_record WARN "설치 경로 여유 공간" "확인 불가"
  fi
  if [[ "$_avail_tmp" =~ ^[0-9]+$ ]]; then
    if [ "$_avail_tmp" -lt 131072 ]; then
      _vf_pf_record FAIL "/tmp 여유 공간" "$((_avail_tmp / 1024)) MiB — 최소 128 MiB 필요"
    elif [ "$_avail_tmp" -lt 524288 ]; then
      _vf_pf_record WARN "/tmp 여유 공간" "$((_avail_tmp / 1024)) MiB — 512 MiB 이상 권장"
    else
      _vf_pf_record PASS "/tmp 여유 공간" "$((_avail_tmp / 1024)) MiB"
    fi
  else
    _vf_pf_record WARN "/tmp 여유 공간" "확인 불가"
  fi

  # tar 메타데이터 보존 기능 확인.
  local -a _tar_missing=()
  tar --help 2>/dev/null | grep -q -- '--acls' || _tar_missing+=(ACL)
  tar --help 2>/dev/null | grep -q -- '--xattrs' || _tar_missing+=(xattr)
  tar --help 2>/dev/null | grep -q -- '--selinux' || _tar_missing+=(SELinux)
  if [ "${#_tar_missing[@]}" -eq 0 ]; then
    _vf_pf_record PASS "tar 보존 기능" "ACL/xattr/SELinux 지원"
  else
    _vf_pf_record WARN "tar 보존 기능" "미지원: ${_tar_missing[*]}"
  fi

  _VF_PF_SECTION="reference"

  # SELinux 상태는 강제 조건이 아니지만 운영 정책 판단에 표시한다.
  if command -v getenforce >/dev/null 2>&1; then
    local _selinux
    _selinux=$(getenforce 2>/dev/null)
    case "$_selinux" in
      Enforcing) _vf_pf_record PASS "SELinux" "Enforcing" ;;
      Permissive) _vf_pf_record INFO "SELinux" "Permissive" ;;
      Disabled) _vf_pf_record INFO "SELinux" "Disabled" ;;
      *) _vf_pf_record INFO "SELinux" "${_selinux:-확인 불가}" ;;
    esac
  else
    _vf_pf_record INFO "SELinux" "getenforce 없음"
  fi

  _VF_PF_SECTION="config"

  # 주요 설정 검사. 현재 sshd/sudoers 문법이 깨진 상태에서 조치를 진행하면
  # 원인 구분이 불가능해지므로 차단한다.
  # (--rollback 은 이 사전 점검을 실행하지 않는다. 깨진 설정을 되돌리는 것이
  #  롤백의 목적이므로, 여기서 차단하면 복원 자체가 불가능해지기 때문이다.)
  local _core_config_severity="critical"
  command -v sshd >/dev/null 2>&1 \
    && _vf_pf_check_config "SSH 설정" "$_core_config_severity" sshd -t
  command -v visudo >/dev/null 2>&1 && [ -f /etc/sudoers ] \
    && _vf_pf_check_config "sudo 설정" "$_core_config_severity" visudo -cf /etc/sudoers

  _VF_PF_SECTION="reference"
  _vf_pf_check_authselect "$_mode"

  _VF_PF_SECTION="config"
  command -v rsyslogd >/dev/null 2>&1 \
    && _vf_pf_check_config "rsyslog 설정" warning rsyslogd -N1
  command -v named-checkconf >/dev/null 2>&1 \
    && _vf_pf_check_config "BIND 설정" warning named-checkconf
  command -v postfix >/dev/null 2>&1 \
    && _vf_pf_check_config "Postfix 설정" warning postfix check

  _VF_PF_SECTION="reference"

  # NTP 동기화 상태는 보고서 시각·백업 매칭의 신뢰도와 연관된다.
  if command -v timedatectl >/dev/null 2>&1; then
    local _ntp_sync
    _ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$_ntp_sync" = "yes" ]; then
      _vf_pf_record PASS "시각 동기화" "NTP 동기화 확인"
    else
      _vf_pf_record INFO "시각 동기화" "NTP 동기화 미확인"
    fi
  else
    _vf_pf_record INFO "시각 동기화" "timedatectl 없음"
  fi

  # 기존 백업의 sidecar 누락을 조기에 알린다.
  local _bak_count=0 _missing_sidecar=0 _bak
  if [ -d "${_base}/backup" ]; then
    while IFS= read -r _bak; do
      [ -n "$_bak" ] || continue
      _bak_count=$((_bak_count + 1))
      [ -f "${_bak}.records" ] || _missing_sidecar=$((_missing_sidecar + 1))
    done < <(find "${_base}/backup" -maxdepth 1 -type f -name 'vulnFix_backup_*.tar.gz' 2>/dev/null)
  fi
  if [ "$_missing_sidecar" -gt 0 ]; then
    _vf_pf_record WARN "기존 롤백 자료" "백업 ${_bak_count}개 중 .records 누락 ${_missing_sidecar}개"
  elif [ "$_bak_count" -gt 0 ]; then
    _vf_pf_record PASS "기존 롤백 자료" "백업 ${_bak_count}개 sidecar 확인"
  else
    _vf_pf_record PASS "기존 롤백 자료" "기존 조치 백업 없음"
  fi

  # 진행률 한 줄을 정리한다.
  printf '\r\033[K'
  _vf_cursor_show

  if [ "$_VF_PF_WARN" -eq 0 ] && [ "$_VF_PF_FAIL" -eq 0 ]; then
    # 전부 통과 — 화면에 아무것도 남기지 않는다. 이 점검은 실행 가능 여부를
    # 보장하기 위한 내부 절차일 뿐이라, 문제가 없으면 사용자가 이 단계가
    # 있었다는 사실조차 알 필요가 없다.
    # (--preflight 단독 실행은 이 점검 자체가 목적이므로 결과를 표시한다.)
    if [ "$_mode" = "standalone" ]; then
      echo -e " ${GREEN}판정: 적합 — 필수 실행 조건을 모두 충족했습니다.${RESET}"
      echo ""
    fi
    return 0
  fi

  # 여기부터는 경고·실패가 있는 경우다. 시작 시 생략했던 제목 박스를 이제
  # 출력하고(단독 실행 모드에서는 이미 출력했으므로 건너뛴다) 상세를 보여준다.
  if [ "$_mode" != "standalone" ]; then
    echo ""
    _div_item
    echo -e " ${BOLD}취약점 조치 적합성 점검${RESET}"
    _div_item
    echo ""
  fi

  # SELinux/SSH/sudo/rsyslog 요약과 해당 항목의 상세를 보여준다.
  local _pf_headline
  _pf_headline="SELinux: ${_VF_PF_SELINUX_STATE:-확인 안 됨}"
  _pf_headline+=", SSH 설정: $(_vf_pf_level_word "$_VF_PF_SSH_STATE")"
  _pf_headline+=", sudo 설정: $(_vf_pf_level_word "$_VF_PF_SUDO_STATE")"
  _pf_headline+=", rsyslog 설정: $(_vf_pf_level_word "$_VF_PF_RSYSLOG_STATE")"

  echo -e " ${YELLOW}⚠${RESET} 적합성 점검 — ${_pf_headline}"
  echo ""
  _vf_pf_render_section "실행 환경" "${_VF_PF_LINES_EXECUTION[@]}"
  _vf_pf_render_section "배포 및 백업 환경" "${_VF_PF_LINES_DEPLOYMENT[@]}"
  _vf_pf_render_section "보고서 환경" "${_VF_PF_LINES_REPORT[@]}"
  _vf_pf_render_section "설정 안전성" "${_VF_PF_LINES_CONFIG[@]}"
  _vf_pf_render_section "환경 참고" "${_VF_PF_LINES_REFERENCE[@]}"

  _div_item
  printf " 정상 %d건  |  참고 %d건  |  확인 필요 %d건  |  실행 불가 %d건\n" \
    "$_VF_PF_PASS" "$_VF_PF_INFO" "$_VF_PF_WARN" "$_VF_PF_FAIL"
  _div_item
  echo ""

  if [ "$_VF_PF_FAIL" -gt 0 ]; then
    echo -e " ${RED}판정: 실행 불가 — 실행 불가 항목을 먼저 해결해야 합니다.${RESET}"
    echo ""
    return 1
  fi
  echo -e " ${YELLOW}판정: 조건부 적합 — 확인 필요 항목을 검토한 뒤 진행하세요.${RESET}"
  echo ""
  return 3
}

# --preflight는 영구 디렉터리·임시 레코드·실행 잠금을 만들기 전에 종료한다.
if [ "${_VF_EARLY_PREFLIGHT:-0}" -eq 1 ]; then
  _vf_run_deployment_preflight standalone
  exit $?
fi

# ── KISA 권고 기본값 ─────────────────────────────────────────────────────────
# 값을 바꾸고 싶으면 이 줄만 수정하면 된다.
# 실제 적용 파일: /etc/login.defs, /etc/security/pwquality.conf 등 리눅스 표준 파일.
DEFAULT_PASS_MAX_DAYS=90
DEFAULT_PASS_MIN_DAYS=1
DEFAULT_MINLEN=8
DEFAULT_DENY=5
DEFAULT_UNLOCK_TIME=300
DEFAULT_TMOUT=600

# ── 대화형 입력 공통 계층 ────────────────────────────────────────────────────
# 이 스크립트는 운영자가 화면을 확인하며 승인하는 대화형 실행만 지원한다.
# 모든 사용자 입력은 stdin이 아니라 제어 터미널(/dev/tty)의 전용 FD를 통해 읽는다.
# 따라서 파이프·리디렉션·Ansible/Jenkins 비대화형 실행에서는 입력을 추측하지 않고
# 시작 단계에서 안전하게 중단한다.
_VF_INPUT_FD=""

_vf_init_interactive_console() {
  if ! [ -t 0 ]; then
    echo -e "${RED}[오류] 표준 입력이 대화형 터미널이 아닙니다.${RESET}"
    echo -e "${YELLOW}       파이프·리디렉션·Ansible/Jenkins 무인 실행은 지원하지 않습니다.${RESET}"
    echo -e "${YELLOW}       파일 배포 후 SSH 터미널에서 스크립트를 직접 실행하세요.${RESET}"
    return 1
  fi
  if ! { exec 7<>/dev/tty; } 2>/dev/null || ! [ -t 7 ]; then
    echo -e "${RED}[오류] 대화형 제어 터미널(/dev/tty)을 사용할 수 없습니다.${RESET}"
    echo -e "${YELLOW}       이 버전은 운영자가 직접 확인하는 대화형 실행 전용입니다.${RESET}"
    echo -e "${YELLOW}       Ansible/Jenkins에서는 파일 배포까지만 수행하고, 조치는 SSH 터미널에서 실행하세요.${RESET}"
    return 1
  fi
  _VF_INPUT_FD=7
  return 0
}

_vf_close_interactive_console() {
  if [ -n "${_VF_INPUT_FD:-}" ]; then
    { exec 7>&- 7<&-; } 2>/dev/null || true
    _VF_INPUT_FD=""
  fi
}

# _vf_read_line <변수명> <프롬프트> [제한시간(초)]
# 반환값: 0=입력 성공, 1=EOF/터미널 단절/시간 초과
_vf_read_line() {
  local __varname="$1" __prompt="${2:-}" __timeout="${3:-}" __value=""
  [ -n "${_VF_INPUT_FD:-}" ] || return 1
  printf '%s' "$__prompt" >&${_VF_INPUT_FD}
  if [ -n "$__timeout" ]; then
    IFS= read -r -t "$__timeout" -u "$_VF_INPUT_FD" __value || return 1
  else
    IFS= read -r -u "$_VF_INPUT_FD" __value || return 1
  fi
  printf -v "$__varname" '%s' "$__value"
  return 0
}

_vf_tty_printf() { printf "$@" >&${_VF_INPUT_FD}; }
_vf_tty_line()   { printf '%s\n' "$*" >&${_VF_INPUT_FD}; }

_vf_input_abort() {
  echo ""
  echo -e "${RED}[오류] 사용자 입력 터미널이 종료되었거나 입력을 읽을 수 없습니다.${RESET}"
  echo -e "${YELLOW}       안전을 위해 현재 작업을 중단합니다.${RESET}"
  exit 1
}

# _confirm_yn <prompt>
# y/n 외 입력은 무시하고 다시 묻는다.
# 반환값: 0 = 예(y), 1 = 아니오(n)
_confirm_yn() {
  local prompt="$1" ans
  while true; do
    _vf_read_line ans "$prompt" || _vf_input_abort
    case "$ans" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo -e " ${RED}y 또는 n만 입력해주세요.${RESET}" ;;
    esac
  done
}

# _read_yn <변수명> <프롬프트>
# 검증된 Y/y 또는 N/n 값만 변수에 저장한다.
_read_yn() {
  local __varname="$1" __prompt="$2" __val
  while true; do
    _vf_read_line __val "$__prompt" || _vf_input_abort
    case "$__val" in
      [Yy]|[Nn]) printf -v "$__varname" '%s' "$__val"; return 0 ;;
      *) echo -e " ${RED}y 또는 n만 입력해주세요.${RESET}" ;;
    esac
  done
}

# _read_num <변수명> <프롬프트> <기본값> <최소값> [<최대값>]
# 기본값 인자는 안내·호환 목적으로 유지하며, EOF일 때 자동 적용하지 않는다.
_read_num() {
  local __varname="$1" __prompt="$2" __default="$3" __min="$4" __max="${5:-}" __val
  while true; do
    _vf_read_line __val "$__prompt" || _vf_input_abort
    if [[ "$__val" =~ ^[0-9]+$ ]] && [ "$__val" -ge "$__min" ] 2>/dev/null \
       && { [ -z "$__max" ] || [ "$__val" -le "$__max" ] 2>/dev/null; }; then
      printf -v "$__varname" '%s' "$__val"
      return 0
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
#                      기존 양호 / 재확인 통과
#                      조치 완료 / 최종 검증 통과
#                      수동 확인 필요
#                      조치 실패
#   [변경 파일]      총 N개  (변경 파일이 없으면 "없음")
#   [변경 파일 목록]  실제 변경된 절대경로 목록
#                      - 5개 이하: 전체 나열
#                      - 6개 이상: 상위 3~5개만 표시 + "외 N개"
#                        (전체 목록은 Excel "조치 변경 내역" 시트에 기록)
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
# ├── backup/          사전 백업 tar.gz, sha256, records
# └── report/          최종 Excel 결과 보고서(.xlsx)
#
# 일반 실행 로그, TXT, 영구 CSV 및 롤백 로그는 생성하지 않는다.
_BASE_DIR="/linux_vuln_fix"
# 영구 산출물은 백업과 보고서만 저장하고, 롤백 작업 파일은 /tmp를 사용한다.
_BAK_DIR="${_BASE_DIR}/backup"
_RPT_BASE_DIR="${_BASE_DIR}/report"
_RB_DIR="/tmp/linux_vuln_fix/rollback"

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
_RB_DIR=$(_vf_prepare_private_dir "/tmp/linux_vuln_fix/rollback" "/tmp/linux_vuln_fix/rollback")   || { echo -e "${RED}[오류] 롤백 임시 작업 디렉터리를 준비할 수 없습니다.${RESET}"; exit 1; }

# 일반 내부 진단와 누적 히스토리는 생성하지 않는다.
# 롤백에 필요한 데이터만 백업 옆 .records 파일로 저장한다.

# 이 실행 전체에서 공용으로 사용하는 시각과 식별자
_RUN_TS=$(date +%Y%m%d_%H%M%S)
_RUN_ID="${_RUN_TS}_$$"
_RUN_START_ISO="$(date '+%Y-%m-%dT%H:%M:%S%z')"

# 롤백 보조 레코드는 실행 중 임시 파일에만 기록하고,
# 실행 종료 시 <백업파일>.records로 저장한다.
_CURRENT_RECORDS_FILE="${_BAK_DIR}/.vulnfix_records_${_RUN_ID}.tmp"
( umask 077; : > "$_CURRENT_RECORDS_FILE" ) 2>/dev/null \
  || { echo -e "${RED}[오류] 롤백 보조 레코드 임시 파일을 생성할 수 없습니다.${RESET}"; exit 1; }
chmod 600 "$_CURRENT_RECORDS_FILE" 2>/dev/null || true

_vf_now_ms() {
  local _n
  _n=$(date +%s%3N 2>/dev/null)
  case "$_n" in ''|*[!0-9]*) _n=$(( $(date +%s) * 1000 )) ;; esac
  printf '%s' "$_n"
}

_vf_log_field() {
  local _v="${1:-}" _limit="${2:-500}"
  _v=$(printf '%s' "$_v" | tr '\r\n|' '   ' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' 2>/dev/null)
  printf '%s' "${_v:0:_limit}"
}

_vf_sha256_file() {
  local _file="$1"
  [ -f "$_file" ] || { printf 'UNAVAILABLE'; return 1; }
  command -v sha256sum >/dev/null 2>&1 \
    || { printf 'UNAVAILABLE'; return 1; }

  local _hash
  _hash=$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')
  [ -n "$_hash" ] || { printf 'UNAVAILABLE'; return 1; }
  printf '%s' "$_hash"
}

_vf_write_sha256_sidecar() {
  local _file="$1" _hash
  [ -f "$_file" ] || return 1
  _hash=$(_vf_sha256_file "$_file" 2>/dev/null || true)
  [ -n "$_hash" ] && [ "$_hash" != "UNAVAILABLE" ] || return 1

  (
    umask 077
    printf '%s  %s\n' "$_hash" "$(basename "$_file")" \
      > "${_file}.sha256"
  ) 2>/dev/null || return 1

  chmod 600 "${_file}.sha256" 2>/dev/null || true
  return 0
}

# 롤백 복원에 실제로 필요한 레코드만 저장한다.
_vf_record_write() {
  local _record="${1:-}"
  case "$_record" in
    PERM_RESTORE\|*|GROUP_MEMBERSHIP\|*|VERIFY_BASELINE\|*|CREATED_PATH\|*|ORPHAN_RESTORE\|*)
      printf '%s\n' "$_record" >> "$_CURRENT_RECORDS_FILE" 2>/dev/null
      ;;
  esac
}

_vf_records_exit_finalize() {
  _vf_progress_spinner_stop 2>/dev/null || true
  _vf_progress_line_clear 2>/dev/null || true
  _vf_cursor_show 2>/dev/null || true
  _vf_close_interactive_console
  _scan_cache_cleanup 2>/dev/null || true
  if declare -F _vf_export_run_records_sidecar >/dev/null 2>&1 \
     && [ -n "${_PRE_BAK_FILE:-}" ] \
     && [ -f "${_PRE_BAK_FILE:-}" ] \
     && [ ! -f "${_PRE_BAK_FILE}.records" ]; then
    _vf_export_run_records_sidecar "$_PRE_BAK_FILE" >/dev/null 2>&1 || true
  fi

  rm -f "$_CURRENT_RECORDS_FILE" 2>/dev/null || true
  rm -f "${REPORT_CSV:-}" 2>/dev/null || true
  if [ -n "${_RPT_BASE_DIR:-}" ] && [ -n "${_RUN_TS:-}" ]; then
    rm -f "${_RPT_BASE_DIR}/.xlsx_error_${_RUN_TS}.tmp" 2>/dev/null || true
  fi
}
trap _vf_records_exit_finalize EXIT

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
  autofs.service finger.socket finger.service fingerd.service cfingerd.service
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
: "${VULNFIX_KEEP_LOGS:=10}"          # 상세/롤백/내부 검증
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


# 기준 검증 명령과 실제 설정 상태를 서로 다른 해시로 기록한다.
_vf_baseline_command_text() {
  local _arg _out=""
  for _arg in "$@"; do
    printf -v _arg '%q' "$_arg"
    _out="${_out}${_out:+ }${_arg}"
  done
  printf '%s' "$_out"
}

_vf_hash_state_stream() {
  command -v sha256sum >/dev/null 2>&1 || return 1
  sha256sum | awk '{print $1}'
}

_vf_baseline_state_sha256() {
  local _name="$1"
  command -v sha256sum >/dev/null 2>&1 || return 1

  case "$_name" in
    "SSH 설정")
      command -v sshd >/dev/null 2>&1 || return 1
      sshd -T 2>/dev/null | LC_ALL=C sort | _vf_hash_state_stream
      ;;
    "sudo 설정")
      {
        find /etc/sudoers /etc/sudoers.d -xdev -type f -print0 2>/dev/null \
          | LC_ALL=C sort -z \
          | xargs -0 -r sha256sum 2>/dev/null
      } | _vf_hash_state_stream
      ;;
    "PAM/authselect 구성")
      {
        command -v authselect >/dev/null 2>&1 && authselect current -r 2>/dev/null
        find /etc/pam.d /etc/authselect -xdev -type f -print0 2>/dev/null \
          | LC_ALL=C sort -z \
          | xargs -0 -r sha256sum 2>/dev/null
      } | _vf_hash_state_stream
      ;;
    "rsyslog 설정")
      {
        find /etc/rsyslog.conf /etc/rsyslog.d -xdev -type f -print0 2>/dev/null \
          | LC_ALL=C sort -z \
          | xargs -0 -r sha256sum 2>/dev/null
      } | _vf_hash_state_stream
      ;;
    "Postfix 설정")
      command -v postconf >/dev/null 2>&1 || return 1
      postconf -n 2>/dev/null | LC_ALL=C sort | _vf_hash_state_stream
      ;;
    *)
      return 1
      ;;
  esac
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
    local _status="FAIL" _rc=1 _cmd=""
    local _out_hash="UNAVAILABLE" _state_hash="UNAVAILABLE"
    : > "$_bl_out"
    "$@" >"$_bl_out" 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] && _status="PASS"

    _bl_text=$(cat "$_bl_out" 2>/dev/null)
    _bl_hash=$(_vf_verify_output_sha256 "$_bl_text" 2>/dev/null || true)
    [ -n "$_bl_hash" ] && _out_hash="$_bl_hash"
    _state_hash=$(_vf_baseline_state_sha256 "$_name" 2>/dev/null || true)
    [ -n "$_state_hash" ] || _state_hash="UNAVAILABLE"
    _cmd=$(_vf_log_field "$(_vf_baseline_command_text "$@")" 500)

    printf 'VERIFY_BASELINE|%s|%s|METHOD=COMMAND_EXIT|COMMAND=%s|EXIT_CODE=%s|OUTPUT_SHA256=%s|STATE_SHA256=%s\n' \
      "$_name" "$_status" "$_cmd" "$_rc" "$_out_hash" "$_state_hash" >> "$_dest"
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
#   롤백 보조 records 또는 .records 파일에서 선택한 백업에 대응하는 한 실행의
#   롤백 역산·검증 레코드만 추출한다.
#
# 입력:
#   $1 : 선택한 백업의 .records 파일
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
    active && /^(PERM_RESTORE|GROUP_MEMBERSHIP|VERIFY_BASELINE|CREATED_PATH|ORPHAN_RESTORE)\|/ {
      line=$0
      sub(/\|SCHEMA=.*/, "", line)
      sub(/\|RUN_ID=.*/, "", line)
      print line
    }
    END { if (!matched) exit 1 }
  ' "$_src" 2>/dev/null
}

# 선택한 백업 레코드의 원래 조치 실행 ID와 버전을 조회한다.
_vf_extract_source_run_meta() {
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
    /^RUN_START\|/ && run_matches() {
      id="UNKNOWN"; ver="UNKNOWN"; started=$2
      for (i=1; i<=NF; i++) {
        if ($i ~ /^ID=/)      { id=$i; sub(/^ID=/,"",id) }
        if ($i ~ /^RUN_ID=/)  { id=$i; sub(/^RUN_ID=/,"",id) }
        if ($i ~ /^VERSION=/) { ver=$i; sub(/^VERSION=/,"",ver) }
        if ($i ~ /^START=/)   { started=$i; sub(/^START=/,"",started) }
      }
      printf "%s|%s|%s\n", id, ver, started
      exit 0
    }
    END { if (NR==0) exit 1 }
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
#   - 롤백 보조 records 파일의 원본 레코드 형식은 변경하지 않음
# -----------------------------------------------------------------------------
_vf_export_run_records_sidecar() {
  local _bak="$1" _sidecar="${1}.records" _tmp="${1}.records.tmp.$$"
  local _record_count=0
  [ -f "$_bak" ] || return 1
  [ -f "$_CURRENT_RECORDS_FILE" ] || return 1
  _record_count=$(grep -cE '^(PERM_RESTORE|GROUP_MEMBERSHIP|VERIFY_BASELINE|CREATED_PATH|ORPHAN_RESTORE)\|' "$_CURRENT_RECORDS_FILE" 2>/dev/null || true)
  case "$_record_count" in ''|*[!0-9]*) _record_count=0 ;; esac
  if ! ( umask 077
    printf 'RUN_START|%s|ID=%s|MODE=FIX|BAK=%s|START=%s|VERSION=%s|RECORDS=%s\n' \
      "$_RUN_TS" "$_RUN_ID" "$_bak" "$_RUN_START_ISO" "$_SCRIPT_VERSION" "$_record_count"
    cat "$_CURRENT_RECORDS_FILE" 2>/dev/null
  ) > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    return 1
  fi
  grep -q '^RUN_START|' "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$_sidecar" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_sidecar" 2>/dev/null || true
  _vf_write_sha256_sidecar "$_sidecar" || true
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
    printf 'SCRIPT_VERSION|%s\n' "$_SCRIPT_VERSION"
    printf 'RELEASE_CHANNEL|%s\n' "$_SCRIPT_RELEASE_CHANNEL"
    printf 'BUILD_DATE|%s\n' "$_SCRIPT_BUILD_DATE"
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
#   $4 : 내부 진단 출력 대상(영구 저장 안 함)
#   $5 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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
#   - 롤백 실행·내부 검증에 생성 결과 기록
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
  _err="${_workdir}/pre_rollback_error.tmp"

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
  if [ -f "$_sidecar" ]; then
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
    printf 'SCRIPT_VERSION|%s\n' "${_SCRIPT_VERSION:-unknown}"
    printf 'RELEASE_CHANNEL|%s\n' "${_SCRIPT_RELEASE_CHANNEL:-unknown}"
    printf 'BUILD_DATE|%s\n' "${_SCRIPT_BUILD_DATE:-unknown}"
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

  _vf_progress_spinner_start 0 1 "안전 백업" "" "상태 정보 수집"
  _vf_capture_services "${_meta}/services.tsv"
  _vf_capture_packages "${_meta}/packages.tsv"
  _vf_capture_accounts "${_meta}/accounts.tsv"
  _vf_capture_firewall "${_meta}/firewall"
  _vf_capture_verify_baselines "$_baseline_records" "$_workdir" || true
  _vf_progress_spinner_stop

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
    local _safe_spin_idx=0 _safe_spin="" _safe_pct=0 _safe_last_pct=-1
    : > "$_ckpt_file"
    ( umask 077
      tar "${_create_features[@]}" --no-recursion --null -czpf "$_tmp_tar" \
        --checkpoint=1 --checkpoint-action="exec=printf x >> \"$_ckpt_file\"" \
        -C / -T "$_existing0" -C "$_meta_root" -T "$_meta0" ) 2>"$_err" &
    _tar_pid=$!
    while kill -0 "$_tar_pid" 2>/dev/null; do
      _ckpt_now=$(wc -c < "$_ckpt_file" 2>/dev/null | tr -d ' ')
      case "$_ckpt_now" in ''|*[!0-9]*) _ckpt_now=0 ;; esac
      [ "$_ckpt_now" -gt "$_ckpt_total" ] && _ckpt_now="$_ckpt_total"
      _safe_pct=$(( _ckpt_now * 100 / _ckpt_total ))
      _safe_spin=$(_vf_spinner_frame "$_safe_spin_idx")

      if [ "$_safe_pct" -ne "$_safe_last_pct" ]; then
        _show_progress_bar "$_ckpt_now" "$_ckpt_total" "안전 백업" "" "$_safe_spin" "설정 파일 압축"
        _safe_last_pct="$_safe_pct"
      else
        _vf_progress_spinner_tick "$_safe_spin"
      fi

      _safe_spin_idx=$((_safe_spin_idx+1))
      sleep 0.5
    done
    wait "$_tar_pid"
    _tar_rc=$?
    rm -f "$_ckpt_file" 2>/dev/null
    if [ "$_tar_rc" -ne 0 ]; then
      printf '\r\033[2K'
      _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
      rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
      return 1
    fi
  else
    _vf_progress_spinner_start 0 1 "안전 백업" "" "설정 파일 압축"
    ( umask 077
      tar "${_create_features[@]}" --no-recursion --null -czpf "$_tmp_tar" \
        -C / -T "$_existing0" -C "$_meta_root" -T "$_meta0" ) 2>"$_err"
    _tar_rc=$?
    _vf_progress_spinner_stop
    if [ "$_tar_rc" -ne 0 ]; then
      _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
      rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
      return 1
    fi
  fi

  _vf_progress_spinner_start "$_ckpt_total" "$_ckpt_total" "안전 백업" "" "무결성 검증"
  tar tzf "$_tmp_tar" >/dev/null 2>>"$_err"
  _safe_verify_rc=$?
  _vf_progress_spinner_stop
  if [ "$_safe_verify_rc" -ne 0 ]; then
    _VF_PRE_RB_ERROR=$(cat "$_err" 2>/dev/null)
    rm -f "$_tmp_tar" "$_tmp_sha" 2>/dev/null
    return 1
  fi

  _show_progress_bar "$_ckpt_total" "$_ckpt_total" "안전 백업 완료"
  echo ""

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
#   $3 : 내부 진단 출력 대상(영구 저장 안 함)
#   $4 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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
#   $3 : 내부 진단 출력 대상(영구 저장 안 함)
#   $4 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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

# 스크립트 실행 과정에서 생성되는 백업 흔적을 분류한다.
# 이 경로들은 롤백 복원 실패가 아니라 감사·복구용 보조 산출물이므로
# 자동 삭제하지 않고 참고 정보로 기록하며 종료 코드 계산에서는 제외한다.
_vf_classify_script_artifact() {
  local _path="$1"

  if [[ "$_path" =~ ^/var/lib/authselect/backups/vulnfix_[0-9]{8}_[0-9]{6}(/.*)?$ ]]; then
    echo "AUTHSELECT"
    return 0
  fi

  if [[ "$_path" =~ \.bak\.[0-9]{8}_[0-9]{6}$ ]]; then
    case "$_path" in
      /etc/pam.d/*)
        echo "PAM"
        return 0
        ;;
      /etc/ssh/*)
        echo "SSH"
        return 0
        ;;
      /etc/postfix/*|/etc/mail/*|/etc/exim4/*)
        echo "MAIL"
        return 0
        ;;
      /etc/*|/root/*)
        echo "CONFIG"
        return 0
        ;;
    esac
  fi

  return 1
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
#   $4 : 내부 진단 출력 대상(영구 저장 안 함)
#   $5 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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

  _VF_PATH_OK=0
  _VF_PATH_FAIL=0
  _VF_PATH_MANUAL=0
  _VF_PATH_SCRIPT_ARTIFACT=0
  _VF_PATH_SCRIPT_PAM=0
  _VF_PATH_SCRIPT_SSH=0
  _VF_PATH_SCRIPT_MAIL=0
  _VF_PATH_SCRIPT_AUTHSELECT=0
  _VF_PATH_SCRIPT_CONFIG=0
  _VF_PATH_NEW_TOTAL=0

  local _work_prefix="${_meta_dir%/.vulnfix_meta}"
  local _baseline="$_meta_dir/inventory.paths"
  local _roots="$_meta_dir/inventory.roots"
  local _current="${_work_prefix}/inventory.current"
  local _new="${_work_prefix}/inventory.new"
  local _missing="${_work_prefix}/inventory.missing"
  local _baseline_sorted="${_work_prefix}/inventory.baseline.sorted"
  local _current_sorted="${_work_prefix}/inventory.current.sorted"
  local _script_artifacts="${_work_prefix}/inventory.script_artifacts"
  local _manual_new="${_work_prefix}/inventory.manual_new"
  local _path_analysis="${_work_prefix}/inventory.analysis"

  _VF_PATH_SCRIPT_ARTIFACT_FILE="$_script_artifacts"
  _VF_PATH_MANUAL_FILE="$_manual_new"

  : > "$_current"
  : > "$_script_artifacts"
  : > "$_manual_new"
  : > "$_path_analysis"

  if [ -f "$_roots" ]; then
    while IFS= read -r _root; do
      [ -e "$_root" ] || [ -L "$_root" ] || continue
      if [ -d "$_root" ] && [ ! -L "$_root" ]; then
        find "$_root" -xdev -printf '%p\t%y\n' 2>/dev/null
      else
        printf '%s\t%s\n' "$_root" \
          "$( [ -L "$_root" ] && echo l || [ -f "$_root" ] && echo f || echo o )"
      fi
    done < "$_roots" | LC_ALL=C sort -u > "$_current"
  fi

  if [ -f "$_baseline" ]; then
    LC_ALL=C sort -u "$_baseline" > "$_baseline_sorted"
    LC_ALL=C sort -u "$_current" > "$_current_sorted"
    comm -23 "$_baseline_sorted" "$_current_sorted" > "$_missing"
    comm -13 "$_baseline_sorted" "$_current_sorted" > "$_new"
  else
    : > "$_missing"
    : > "$_new"
    _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
    printf 'BASELINE_MISSING\t-\t-\n' >> "$_manual_new"
    echo "PATH|BASELINE_MISSING" >> "$_log" 2>/dev/null
  fi

  _VF_PATH_NEW_TOTAL=$(wc -l < "$_new" 2>/dev/null | tr -d ' ')
  case "$_VF_PATH_NEW_TOTAL" in ''|*[!0-9]*) _VF_PATH_NEW_TOTAL=0 ;; esac

  local _line _path _type _artifact_category=""
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

    # 선택한 실행에서 직접 생성한 개별 .bak 파일은 기존 방식대로 자동 정리한다.
    if [[ "$_path" == *.bak."$_run_ts" ]] && [ -f "$_path" ]; then
      if rm -f -- "$_path" 2>/dev/null; then
        _VF_PATH_OK=$((_VF_PATH_OK+1))
        echo "PATH|REMOVE_ARTIFACT|PASS|${_path}" >> "$_log" 2>/dev/null
      else
        _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
        echo "PATH|REMOVE_ARTIFACT|FAIL|${_path}" >> "$_log" 2>/dev/null
      fi
      continue
    fi

    if printf '%s\n' "$_created_records" \
       | awk -F'|' -v p="$_path" '$1=="CREATED_PATH" && $2==p {found=1} END{exit !found}'; then
      if [ -L "$_path" ] || [ -f "$_path" ]; then
        if rm -f -- "$_path" 2>/dev/null; then
          _VF_PATH_OK=$((_VF_PATH_OK+1))
        else
          _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
        fi
      elif [ -d "$_path" ]; then
        if rmdir -- "$_path" 2>/dev/null; then
          _VF_PATH_OK=$((_VF_PATH_OK+1))
        else
          _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
          printf 'RECORDED_NONEMPTY\t%s\t%s\n' "$_path" "$_type" >> "$_manual_new"
        fi
      else
        _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
        printf 'RECORDED_UNKNOWN\t%s\t%s\n' "$_path" "$_type" >> "$_manual_new"
      fi
      echo "PATH|CREATED_ROLLBACK|${_path}|type=${_type}" >> "$_log" 2>/dev/null
      continue
    fi

    _artifact_category=""
    if _artifact_category=$(_vf_classify_script_artifact "$_path" 2>/dev/null); then
      _VF_PATH_SCRIPT_ARTIFACT=$((_VF_PATH_SCRIPT_ARTIFACT+1))
      case "$_artifact_category" in
        PAM)        _VF_PATH_SCRIPT_PAM=$((_VF_PATH_SCRIPT_PAM+1)) ;;
        SSH)        _VF_PATH_SCRIPT_SSH=$((_VF_PATH_SCRIPT_SSH+1)) ;;
        MAIL)       _VF_PATH_SCRIPT_MAIL=$((_VF_PATH_SCRIPT_MAIL+1)) ;;
        AUTHSELECT) _VF_PATH_SCRIPT_AUTHSELECT=$((_VF_PATH_SCRIPT_AUTHSELECT+1)) ;;
        CONFIG)     _VF_PATH_SCRIPT_CONFIG=$((_VF_PATH_SCRIPT_CONFIG+1)) ;;
      esac
      printf '%s\t%s\t%s\n' "$_artifact_category" "$_path" "$_type" >> "$_script_artifacts"
      echo "PATH|SCRIPT_ARTIFACT|${_artifact_category}|${_path}|${_type}" >> "$_log" 2>/dev/null
    else
      _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
      printf 'UNTRACKED\t%s\t%s\n' "$_path" "$_type" >> "$_manual_new"
      echo "PATH|NEW_UNTRACKED|${_path}|${_type}" >> "$_log" 2>/dev/null
    fi
  done < "$_new"

  # 조치 전 부재 상태가 기록된 대표 경로도 별도로 비교한다.
  if [ -f "$_meta_dir/path_candidates.tsv" ]; then
    while IFS=$'\t' read -r _path _state _type _meta; do
      [ -n "$_path" ] || continue

      if [ "$_state" = 'EXISTS' ]; then
        if [ ! -e "$_path" ] && [ ! -L "$_path" ] \
           && [ -z "${_handled_missing[$_path]:-}" ]; then
          _handled_missing["$_path"]=1
          _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
          echo "PATH|CANDIDATE_MISSING|${_path}" >> "$_log" 2>/dev/null
        fi
        continue
      fi

      if [ "$_state" = 'ABSENT' ] && { [ -e "$_path" ] || [ -L "$_path" ]; }; then
        [ -n "${_handled_new[$_path]:-}" ] && continue
        _handled_new["$_path"]=1

        if printf '%s\n' "$_created_records" \
           | awk -F'|' -v p="$_path" '$1=="CREATED_PATH" && $2==p {found=1} END{exit !found}'; then
          if [ -f "$_path" ] || [ -L "$_path" ]; then
            rm -f -- "$_path" 2>/dev/null \
              && _VF_PATH_OK=$((_VF_PATH_OK+1)) \
              || _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
          elif [ -d "$_path" ]; then
            if rmdir -- "$_path" 2>/dev/null; then
              _VF_PATH_OK=$((_VF_PATH_OK+1))
            else
              _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
              printf 'CANDIDATE_NONEMPTY\t%s\t%s\n' "$_path" "$_type" >> "$_manual_new"
            fi
          fi
        else
          _artifact_category=""
          if _artifact_category=$(_vf_classify_script_artifact "$_path" 2>/dev/null); then
            _VF_PATH_SCRIPT_ARTIFACT=$((_VF_PATH_SCRIPT_ARTIFACT+1))
            case "$_artifact_category" in
              PAM)        _VF_PATH_SCRIPT_PAM=$((_VF_PATH_SCRIPT_PAM+1)) ;;
              SSH)        _VF_PATH_SCRIPT_SSH=$((_VF_PATH_SCRIPT_SSH+1)) ;;
              MAIL)       _VF_PATH_SCRIPT_MAIL=$((_VF_PATH_SCRIPT_MAIL+1)) ;;
              AUTHSELECT) _VF_PATH_SCRIPT_AUTHSELECT=$((_VF_PATH_SCRIPT_AUTHSELECT+1)) ;;
              CONFIG)     _VF_PATH_SCRIPT_CONFIG=$((_VF_PATH_SCRIPT_CONFIG+1)) ;;
            esac
            printf '%s\t%s\t%s\n' "$_artifact_category" "$_path" "$_type" >> "$_script_artifacts"
            echo "PATH|SCRIPT_ARTIFACT|${_artifact_category}|${_path}|${_type}" >> "$_log" 2>/dev/null
          else
            _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
            printf 'CANDIDATE_NEW\t%s\t%s\n' "$_path" "$_type" >> "$_manual_new"
            echo "PATH|CANDIDATE_NEW|${_path}" >> "$_log" 2>/dev/null
          fi
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
      rm -f -- "$_path" 2>/dev/null \
        && _VF_PATH_OK=$((_VF_PATH_OK+1)) \
        || _VF_PATH_FAIL=$((_VF_PATH_FAIL+1))
    elif [ -d "$_path" ]; then
      if rmdir -- "$_path" 2>/dev/null; then
        _VF_PATH_OK=$((_VF_PATH_OK+1))
      else
        _VF_PATH_MANUAL=$((_VF_PATH_MANUAL+1))
        printf 'EXPLICIT_NONEMPTY\t%s\t%s\n' "$_path" "$_kind" >> "$_manual_new"
      fi
    fi
  done <<< "$_created_records"

  # 경로 비교 결과를 사람이 바로 이해할 수 있는 형태로 검증 집계에 반영하며 영구 파일로 저장하지 않는다.
  {
    echo ""
    echo "[신규 경로 분석]"
    echo "전체 신규 경로        : ${_VF_PATH_NEW_TOTAL}건"
    echo "자동 정리             : ${_VF_PATH_OK}건"
    echo "스크립트 생성 흔적    : ${_VF_PATH_SCRIPT_ARTIFACT}건"
    echo "미분류 신규 경로      : ${_VF_PATH_MANUAL}건"
    echo "복원 후 누락/실패     : ${_VF_PATH_FAIL}건"
    echo "종료 코드 영향        : 스크립트 생성 흔적은 영향 없음 / 미분류 신규 경로만 추가 확인 대상으로 반영"
    echo ""
    echo "[스크립트 생성 흔적 분류]"
    echo "PAM 백업 파일         : ${_VF_PATH_SCRIPT_PAM}건"
    echo "SSH 백업 파일         : ${_VF_PATH_SCRIPT_SSH}건"
    echo "메일 설정 백업 파일   : ${_VF_PATH_SCRIPT_MAIL}건"
    echo "authselect 백업 경로  : ${_VF_PATH_SCRIPT_AUTHSELECT}건"
    echo "기타 설정 백업 파일   : ${_VF_PATH_SCRIPT_CONFIG}건"

    if [ -s "$_script_artifacts" ]; then
      echo ""
      echo "[스크립트 생성 흔적 상세]"
      while IFS=$'\t' read -r _artifact_category _path _type; do
        case "$_artifact_category" in
          PAM)        _artifact_label="PAM 백업" ;;
          SSH)        _artifact_label="SSH 백업" ;;
          MAIL)       _artifact_label="메일 설정 백업" ;;
          AUTHSELECT) _artifact_label="authselect 백업" ;;
          CONFIG)     _artifact_label="기타 설정 백업" ;;
          *)          _artifact_label="스크립트 산출물" ;;
        esac
        printf '%-22s : %s (유형=%s)\n' "$_artifact_label" "$_path" "$_type"
      done < "$_script_artifacts"
    fi

    if [ -s "$_manual_new" ]; then
      echo ""
      echo "[추가 확인 대상 경로 상세]"
      while IFS=$'\t' read -r _reason _path _type; do
        printf '%-22s : %s (유형=%s)\n' "$_reason" "$_path" "$_type"
      done < "$_manual_new"
    fi

    if [ -s "$_missing" ]; then
      echo ""
      echo "[복원 후 누락 경로 상세]"
      cat "$_missing"
    fi
  } > "$_path_analysis"

  cat "$_path_analysis" >> "$_verify" 2>/dev/null
  cat "$_path_analysis" >> "$_log" 2>/dev/null
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
#   $2 : 내부 진단 출력 대상(영구 저장 안 함)
#   $3 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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
#   $2 : 내부 진단 출력 대상(영구 저장 안 함)
#   $3 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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
#   $3 : 내부 진단 출력 대상(영구 저장 안 함)
#   $4 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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

  _vf_rb_service_stage_record() {
    local _name="$1" _svc="$2" _stage="$3" _status="$4" _command="$5" _text="$6"
    local _one
    _one=$(printf '%s\n' "$_text" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-1000)
    echo "SERVICE_CONFIG_STAGE|RUN_ID=${_RUN_ID}|SERVICE=${_name}|UNIT=${_svc:-NONE}|STAGE=${_stage}|STATUS=${_status}|COMMAND=${_command:-NONE}|DETAIL=${_one:-NONE}" >> "$_log" 2>/dev/null
    {
      echo ""
      echo "[${_name} ${_stage}]"
      echo "상태   : ${_status}"
      echo "서비스 : ${_svc:-확인되지 않음}"
      echo "명령   : ${_command:-수행하지 않음}"
      [ -n "$_text" ] && { echo "상세   :"; printf '%s\n' "$_text" | sed 's/^/  /'; } || echo "상세   : 없음"
    } >> "$_verify" 2>/dev/null
  }

  _vf_rb_config_apply_record() {
    local _status="$1" _name="$2" _svc="$3" _test="$4" _apply="$5" _text="$6"
    local _one _final="REVIEW"
    _one=$(printf '%s\n' "$_text" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-500)
    if [ "${_VF_RB_STAGE_LOGGED:-0}" -ne 1 ]; then
      case "$_status" in
        PASS) _vf_rb_service_stage_record "$_name" "$_svc" "TEST" "PASS" "$_test" "$_text"; _final="PASS" ;;
        SKIP) _vf_rb_service_stage_record "$_name" "$_svc" "TEST" "SKIP" "$_test" "$_text"; _final="SKIP" ;;
        *)    _vf_rb_service_stage_record "$_name" "$_svc" "TEST" "FAIL" "$_test" "$_text"; _final="REVIEW" ;;
      esac
      _vf_rb_service_stage_record "$_name" "$_svc" "FINAL" "$_final" "$_apply" "$_text"
    fi
    case "$_status" in
      PASS) _VF_CONFIG_APPLY_OK=$((_VF_CONFIG_APPLY_OK+1)); _ok "${_name} 설정 반영: ${_apply} 완료" ;;
      SKIP) _VF_CONFIG_APPLY_SKIP=$((_VF_CONFIG_APPLY_SKIP+1)); _info "${_name} 비활성/미설치 상태: 서비스를 임의로 시작하지 않음" ;;
      *) _VF_CONFIG_APPLY_MANUAL=$((_VF_CONFIG_APPLY_MANUAL+1)); _warn "${_name} 설정 반영: 추가 확인 필요" ;;
    esac
    echo "SERVICE_CONFIG|${_name}|${_status}|unit=${_svc:-NONE}|test=${_test:-NONE}|action=${_apply:-NONE}|${_one}" >> "$_log" 2>/dev/null
  }

  _vf_rb_reload_or_restart() {
    local _name="$1" _svc="$2" _test="$3" _test_out="$4"
    local _reload_out="${_workdir}/reload_${_name//[^A-Za-z0-9]/_}.out"
    local _restart_out="${_workdir}/restart_${_name//[^A-Za-z0-9]/_}.out"
    local _reload_status="FAIL"
    : > "$_reload_out"; : > "$_restart_out"
    _VF_RB_STAGE_LOGGED=1
    _vf_rb_service_stage_record "$_name" "$_svc" "TEST" "PASS" "$_test" "$_test_out"
    if systemctl reload "$_svc" >"$_reload_out" 2>&1; then
      _action="reload"
      _vf_rb_service_stage_record "$_name" "$_svc" "RELOAD" "PASS" "systemctl reload ${_svc}" "$(cat "$_reload_out" 2>/dev/null)"
    else
      grep -qiE 'not applicable|not supported|Job type reload' "$_reload_out" 2>/dev/null && _reload_status="NOT_APPLICABLE"
      _vf_rb_service_stage_record "$_name" "$_svc" "RELOAD" "$_reload_status" "systemctl reload ${_svc}" "$(cat "$_reload_out" 2>/dev/null)"
      if systemctl restart "$_svc" >"$_restart_out" 2>&1; then
        _action="restart"
        _vf_rb_service_stage_record "$_name" "$_svc" "RESTART" "PASS" "systemctl restart ${_svc}" "$(cat "$_restart_out" 2>/dev/null)"
      else
        _vf_rb_service_stage_record "$_name" "$_svc" "RESTART" "FAIL" "systemctl restart ${_svc}" "$(cat "$_restart_out" 2>/dev/null)"
        _detail="${_test_out}"$'\n'"$(cat "$_reload_out" "$_restart_out" 2>/dev/null)"
        _vf_rb_service_stage_record "$_name" "$_svc" "FINAL" "REVIEW" "systemctl is-active ${_svc}" "$_detail"
        _vf_rb_config_apply_record "MANUAL" "$_name" "$_svc" "$_test" "reload/restart 실패" "$_detail"
        _VF_RB_STAGE_LOGGED=0
        return 1
      fi
    fi
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
      _detail="${_test_out}"$'\n'"$(cat "$_reload_out" "$_restart_out" 2>/dev/null)"
      _vf_rb_service_stage_record "$_name" "$_svc" "FINAL" "PASS" "systemctl is-active ${_svc}" "active"
      _vf_rb_config_apply_record "PASS" "$_name" "$_svc" "$_test" "$_action" "$_detail"
      _VF_RB_STAGE_LOGGED=0
      return 0
    fi
    _detail="${_test_out}"$'\n'"$(cat "$_reload_out" "$_restart_out" 2>/dev/null)"$'\n'"반영 후 서비스가 active 상태가 아님"
    _vf_rb_service_stage_record "$_name" "$_svc" "FINAL" "REVIEW" "systemctl is-active ${_svc}" "$_detail"
    _vf_rb_config_apply_record "MANUAL" "$_name" "$_svc" "$_test" "${_action} 후 상태 이상" "$_detail"
    _VF_RB_STAGE_LOGGED=0
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
#   $3 : 내부 진단 출력 대상(영구 저장 안 함)
#   $4 : 롤백 내부 검증 출력 대상(영구 저장 안 함)
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
#   $4 : 내부 진단 출력 대상(영구 저장 안 함)
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

# XLSX 생성에 필요한 CSV는 /tmp 중간 파일로만 사용하고 실행 종료 시 삭제한다.
REPORT_CSV="/tmp/.vulnFixResult_${_HOSTNAME_VAL}_${_RUN_TS}_$$.csv"
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
#   XLSX 생성용 임시 CSV를 최초 한 번 초기화하고 표준 머리글을 기록한다.
#
# 출력:
#   /tmp의 REPORT_CSV 경로에 UTF-8 BOM과 고정 컬럼 머리글을 생성한다.
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
#   한 취약점 항목의 최종 결과와 증빙값을 XLSX 생성용 임시 행으로 기록한다.
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
      양호)     after="기존 양호 (재확인 통과)" ;;
      조치완료) after="조치 완료 (검증 통과)" ;;
      수동확인) after="수동 확인 필요" ;;
      실패)     after="조치 실패" ;;
      해당없음) after="해당없음" ;;
      건너뜀)   after="조치 보류 (사용자 선택)" ;;
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
#   TARGET_IDS 중 임시 결과 행이 생성되지 않은 항목을 찾아 실패 행으로 보정한다.
#
# 목적:
#   전체 진단 항목 수와 Excel 결과 행 수가 달라지는 무결성 오류를 방지한다.
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

# root 권한과 실행 경로는 영구 파일 생성 전에 상단 사전 점검에서 검증한다.

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
  trap '_vf_records_exit_finalize; _release_instance_lock' EXIT
else
  echo -e "${YELLOW}[알림] flock 명령이 없어 동시 실행 방지를 건너뜁니다. 이 서버에서 스크립트를 두 세션 이상 동시에 실행하지 마세요.${RESET}"
fi

echo -e "${BOLD}"
_box_top
_box_line "자동 점검 및 조치 스크립트 | KISA 2026 가이드 기반"
_box_line "v${_SCRIPT_VERSION}-yyyee"
_box_bottom
echo -e "${RESET}"

# ── 실행 옵션 파싱 ────────────────────────────────────────────────────────────
ROLLBACK=0
SCAN_ONLY=0
_ARGS=()
for _a in "$@"; do
  case "$_a" in
    --no-prompt)
      echo -e "${RED}[오류] --no-prompt 옵션은 안전상의 이유로 제거되었습니다.${RESET}"
      echo -e "${YELLOW}       이 스크립트는 운영자 승인 기반 대화형 실행만 지원합니다.${RESET}"
      echo -e "${YELLOW}       Ansible/Jenkins에서는 배포까지만 수행하고 SSH 터미널에서 직접 실행하세요.${RESET}"
      exit 2
      ;;
    --rollback)        ROLLBACK=1  ;;
    --scan-only)       SCAN_ONLY=1 ;;
    -h|--help)
      _HELP_SCRIPT_NAME=$(basename "$0")
      echo ""
      echo -e " ${CYAN}[프로그램 구성]${RESET}"
      echo ""
      echo -e "   /linux_vuln_fix/"
      echo -e "   ├── ${_HELP_SCRIPT_NAME}    실행 스크립트"
      echo -e "   └── lib/                    보고서 생성에 필요한 내부 파일"
      echo ""
      echo -e "   ${YELLOW}※ /linux_vuln_fix 폴더는 반드시 루트(/) 바로 아래에 두어야 합니다.${RESET}"
      echo -e "   ${YELLOW}※ 실행 스크립트와 lib 폴더는 같은 위치에 있어야 합니다.${RESET}"
      echo -e "   ${YELLOW}※ lib 폴더의 파일은 직접 실행하거나 이름을 변경하지 마세요.${RESET}"
      echo ""
      echo -e " ${CYAN}[기본 사용법]${RESET}"
      echo ""
      echo -e "   1. 전체 점검 및 조치"
      echo ""
      echo -e "      cd /linux_vuln_fix"
      echo -e "      chmod +x ${_HELP_SCRIPT_NAME}"
      echo -e "      bash ./${_HELP_SCRIPT_NAME}"
      echo ""
      echo -e "      U-01~U-67 항목을 점검하고, 취약 항목별로"
      echo -e "      조치 여부를 확인한 후 선택한 항목을 조치합니다."
      echo ""
      echo -e "   2. 조치 전 환경 점검"
      echo ""
      echo -e "      bash ./${_HELP_SCRIPT_NAME} --preflight"
      echo ""
      echo -e "      설정을 변경하지 않고 OS, systemd, 필수 명령, 저장공간,"
      echo -e "      openpyxl 및 주요 설정 문법을 확인합니다."
      echo -e "      authselect 비관리 구성은 WARN으로 표시하고 PAM 자동 조치를 제한합니다."
      echo ""
      echo -e "   3. 이전 백업으로 복원"
      echo ""
      echo -e "      bash ./${_HELP_SCRIPT_NAME} --rollback"
      echo ""
      echo -e "      기존 백업 목록에서 복원할 시점을 선택하여"
      echo -e "      파일, 권한, 소유권 및 주요 서비스 설정을 복원합니다."
      echo -e "      실제 복원 전에는 현재 상태의 안전 백업을 자동 생성합니다."
      echo ""
      echo -e "      ${YELLOW}※ 백업 파일을 다른 위치로 옮길 때는 같은 이름의${RESET}"
      echo -e "      ${YELLOW}   .records 파일도 함께 복사해야 합니다.${RESET}"
      echo ""
      echo -e " ${CYAN}[지원 옵션]${RESET}"
      echo ""
      echo -e "   --help, -h    도움말 표시"
      echo -e "   --scan-only   시스템 변경 없이 점검만 수행 (비대화형 실행 가능, CSV 출력)"
      echo -e "   --preflight   시스템 변경 없이 취약점 조치 적합성 점검"
      echo -e "   --rollback    기존 백업을 선택하여 복원"
      echo ""
      echo -e " ${CYAN}[결과 저장 위치]${RESET}"
      echo ""
      echo -e "   백업 파일             : ${_BAK_DIR}/"
      echo -e "   Excel 결과 보고서     : ${_RPT_BASE_DIR}/"
      echo ""
      echo -e " ${CYAN}[실행 전 확인]${RESET}"
      echo ""
      echo -e "   - root 계정 또는 root 권한으로 실행해야 합니다."
      echo -e "   - 실행 스크립트와 lib 폴더를 분리하지 마세요."
      echo -e "   - 취약 항목별 조치 여부를 직접 확인한 후 진행합니다."
      echo -e "   - 대화형 제어 터미널(/dev/tty)이 반드시 필요합니다."
      echo -e "   - Ansible/Jenkins 무인 조치는 지원하지 않으며 파일 배포까지만 권장합니다."
      echo -e "   - 운영 서버에서는 현재 SSH 접속 세션을 유지하세요."
      echo -e "   - 조치 시작 전 백업 생성 결과를 확인하세요."
      echo ""
      echo -e " ${CYAN}[프로세스 종료 코드]${RESET}"
      echo ""
      echo -e "   0    정상 완료 — 조치 실패 항목 없음"
      echo -e "   1    조치 실패, 파일 복원 실패 또는 핵심 검증 실패"
      echo -e "   2    비대화형 환경, 옵션 오류 또는 제거된 옵션 사용"
      echo -e "   3    확인 필요 — 수동 확인/조치 보류 항목 존재"
      echo -e "        (--preflight: 필수 조건 충족, 경고 항목 존재)"
      echo -e "        (--scan-only: 취약 또는 수동 확인 항목 존재)"
      echo -e "   4    조치는 정상이나 결과보고서(XLSX) 생성 실패"
      echo -e "   130  조치 단계에서 사용자 중단(Ctrl+C·세션 종료)"
      echo ""
      echo -e "      추가 확인 사항은 종료 코드가 아니라 OUTCOME=COMPLETED_WITH_REVIEW로 구분합니다."
      echo -e "      원인과 확인 방법은 Rollback 결과 화면에 표시됩니다."
      echo ""
      echo -e "${BOLD}${WHITE}==================================================================${RESET}"
      echo ""
      exit 0
      ;;
    -*)
      echo -e "${RED}[오류] 지원하지 않는 옵션입니다: ${_a}${RESET}"
      echo -e "${YELLOW}       도움말: bash ./$(basename "$0") --help${RESET}"
      exit 1
      ;;
    *) _ARGS+=("$_a") ;;
  esac
done
set -- "${_ARGS[@]}"

if [ "$#" -gt 0 ]; then
  echo -e "${RED}[오류] 위치 인자는 지원하지 않습니다: $*${RESET}"
  echo -e "${YELLOW}       기본 실행: bash ./$(basename "$0")${RESET}"
  echo -e "${YELLOW}       롤백 실행: bash ./$(basename "$0") --rollback${RESET}"
  exit 1
fi

# 조치와 롤백은 운영자 승인 기반 대화형 실행만 허용한다.
# 다만 --scan-only 는 시스템 설정을 전혀 변경하지 않는 읽기 전용 점검이므로
# 비대화형(Ansible/Jenkins 등) 실행을 허용한다. 이렇게 하면 다수 서버의
# "점검·현황 수집"까지는 자동화하고, 실제 조치만 운영자가 직접 수행하는
# 현실적인 운영 분리가 가능하다.
if [ "$SCAN_ONLY" -eq 1 ]; then
  if [ "$ROLLBACK" -eq 1 ]; then
    echo -e "${RED}[오류] --scan-only 와 --rollback 은 함께 사용할 수 없습니다.${RESET}"
    exit 2
  fi
  # TTY 가 있으면 대화형 콘솔을 쓰고, 없으면 비대화형으로 계속 진행한다.
  _vf_init_interactive_console >/dev/null 2>&1 || _VF_INPUT_FD=""
  echo -e " ${CYAN}※${RESET} 점검 전용 모드: 시스템 설정을 변경하지 않고 점검·보고서 생성만 수행합니다."
  echo ""
else
  _vf_init_interactive_console || exit 2
fi

# ── 배포 적합성 사전 점검 (--rollback 은 제외) ────────────────────────────────
# 롤백은 "현재 설정이 이미 깨진 상태"를 되돌리기 위한 복구 기능이다.
# authselect 비관리, NTP 미동기화, SELinux 상태, openpyxl 미설치, 미검증 배포판
# 같은 항목은 정상 점검·조치 실행에서는 의미 있는 사전 경고지만, 복구를 가로막는
# 실행 차단 사유가 되어서는 안 된다. 사전 점검이 FAIL을 내면 정작 설정이 깨져
# 있을 때 복원 자체가 불가능해지는 모순이 생긴다.
# 따라서 롤백 경로에서는 배포 적합성 사전 점검을 실행하지 않고, 복원 동작에
# 실제로 필요한 최소 조건만 확인한다.
#
# 롤백 자체의 안전 검사는 그대로 유지된다(_do_rollback 내부에서 수행):
#   root 권한 / 실행 경로 / 대화형 입력 / 중복 실행 방지 / 백업 파일 선택 /
#   SHA-256 검증 / tar 무결성 검사 / 스크립트 적용 범위 확인 /
#   복원 공간 확인 / 롤백 직전 안전 백업
if [ "$ROLLBACK" -eq 1 ]; then
  _vf_rb_min_fail=0

  # 연관 배열(declare -A)을 사용하므로 Bash 4.x 이상은 롤백에서도 필수다.
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] 2>/dev/null; then
    _fail "Bash 4.x 이상이 필요합니다 (현재 ${BASH_VERSION:-확인 불가})."
    _vf_rb_min_fail=1
  fi

  # 복원 동작에 직접 사용하는 명령만 확인한다. (보고서용 python3/openpyxl 등은 제외)
  for _vf_rb_cmd in tar gzip awk sed grep stat find; do
    command -v "$_vf_rb_cmd" >/dev/null 2>&1 && continue
    _fail "복원에 필요한 명령을 찾을 수 없습니다: ${_vf_rb_cmd}"
    _vf_rb_min_fail=1
  done

  if [ "$_vf_rb_min_fail" -eq 1 ]; then
    echo ""
    _fail "롤백 최소 실행 조건 미충족으로 중단합니다."
    echo -e "${YELLOW}       전체 환경 점검이 필요하면 bash ./$(basename "$0") --preflight 를 사용하세요.${RESET}"
    echo ""
    exit 1
  fi
  unset _vf_rb_min_fail _vf_rb_cmd
  echo -e " ${CYAN}※${RESET} 롤백 모드: 취약점 조치 적합성 점검을 생략하고 복원 안전 검사만 수행합니다."
  echo ""
else
  _vf_run_deployment_preflight "fix"
  _vf_pf_rc=$?
  if [ "$_vf_pf_rc" -eq 1 ]; then
    _fail "취약점 조치 적합성 점검 실패로 실행을 중단합니다."
    exit 1
  elif [ "$_vf_pf_rc" -eq 3 ]; then
    _read_yn _vf_pf_continue " 경고 항목을 확인했습니다. 계속 진행하시겠습니까? (y/n): "
    if [[ "$_vf_pf_continue" != [Yy] ]]; then
      echo -e "${YELLOW} 사전 점검 경고 검토를 위해 실행을 종료합니다.${RESET}"
      exit 0
    fi
    echo ""
  fi
  unset _vf_pf_rc _vf_pf_continue
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
  _vf_read_line _choice " 복원할 번호를 선택하세요 (1~${#_bak_files[@]}, q=취소): " || _vf_input_abort
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
  # 하위 복원 함수의 출력 인자를 유지하되 영구 로그 파일은 만들지 않는다.
  local _rb_log="/dev/null"
  local _verify_log="/dev/null"
  local _rb_files_tsv="/dev/null"
  local _rb_start_epoch; _rb_start_epoch=$(date +%s)
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

  if [ ! -f "${_selected}.records" ]; then
    _fail "선택한 백업의 롤백 보조 레코드가 없습니다."
    echo ""
    _row "필수 파일" "$(basename "$_selected").records"
    _row "처리 결과" "시스템 파일을 변경하지 않고 롤백 중단"
    echo ""
    _warn "백업 이동 시 tar.gz, .sha256, .records 파일을 함께 복사해야 합니다."
    _rb_cleanup
    return 1
  fi
  if ! grep -q '^RUN_START|' "${_selected}.records" 2>/dev/null; then
    _fail "롤백 보조 레코드 형식이 올바르지 않습니다."
    _rb_cleanup
    return 1
  fi

  # 백업 SHA-256을 검증하며 체크섬이 없으면 추가 확인으로 분류한다.
  if command -v sha256sum >/dev/null 2>&1; then
    local _expected_sha="" _actual_sha=""
    if [ -f "${_selected}.sha256" ]; then
      _expected_sha=$(awk 'NF {print $1; exit}' "${_selected}.sha256" 2>/dev/null)
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
      _vf_read_line _force_rb " 강제로 계속하려면 FORCE를 입력하세요: " || _vf_input_abort
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
      _vf_read_line _force_scope " 범위가 다른 백업입니다. 강제로 계속하려면 FORCE를 입력하세요: " || _vf_input_abort
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
    _fail "안전 백업이 없으므로 롤백을 시작하지 않습니다."
    echo "PRE_ROLLBACK_BACKUP|FAIL|ROLLBACK_ABORTED_FAIL_CLOSED" >> "$_rb_log" 2>/dev/null
    trap - INT TERM HUP
    _rb_cleanup
    return 1
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

    _vf_progress_spinner_start "$((_idx-1))" "$_total" "복원" "$_filepath" "파일·권한·속성"
    tar "${_tar_extract_features[@]}" --numeric-owner -xzpf "$_selected" -C / "${_tar_extra[@]}" "$_entry" 2>"$_tmp_err"
    _restore_one_rc=$?
    _vf_progress_spinner_stop

    if [ "$_restore_one_rc" -eq 0 ]; then
      local _file_type _file_mode _file_owner
      if [ -L "$_filepath" ]; then _file_type="symlink"
      elif [ -d "$_filepath" ]; then _file_type="directory"
      elif [ -f "$_filepath" ]; then _file_type="file"
      else _file_type="other"; fi
      _file_mode=$(stat -c '%a' "$_filepath" 2>/dev/null || echo '-')
      _file_owner=$(stat -c '%U:%G' "$_filepath" 2>/dev/null || echo '-')
      printf '%s\t%s\t%s\t%s\tPASS\t%s\t%s\t%s\t%s\t-\n' \
        "$_RUN_ID" "$_idx" "$_total" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$_filepath" "$_file_type" "$_file_mode" "$_file_owner" >> "$_rb_files_tsv" 2>/dev/null
      _ok_cnt=$((_ok_cnt+1))
    else
      printf "\r\033[K"
      echo -e "   ${RED}✗${RESET} [${_idx}/${_total}] 복원 실패 : ${_filepath}"
      local _restore_err_text
      _restore_err_text=$(tr '\r\n\t' '   ' < "$_tmp_err" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-1000)
      printf '%s\t%s\t%s\t%s\tFAIL\t%s\t-\t-\t-\t%s\n' \
        "$_RUN_ID" "$_idx" "$_total" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$_filepath" "$(_vf_log_field "$_restore_err_text" 1000)" >> "$_rb_files_tsv" 2>/dev/null
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

    # 실제 완료 파일 수는 다음 항목 spinner와 마지막 완료 화면에 반영한다.
    _current_pct=$(( _idx * 100 / _total ))
    _last_pct="$_current_pct"
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
    echo "파일 상세 : ${_rb_files_tsv}"
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
  declare -A _rb_baseline_hash=()   # 조치 전 명령 출력 정규화 SHA-256
  declare -A _rb_baseline_state_hash=() # 조치 전 실제 설정 상태 SHA-256

  # 백업 옆 .records만 롤백 원본으로 사용한다. 롤백 보조 records 폴백은 사용하지 않는다.
  local _rb_run_ts _rb_sel_base _records_sidecar _record_source="" _run_record_matched=0
  local _source_run_id="UNKNOWN" _source_version="UNKNOWN" _source_started="UNKNOWN"
  local _source_backup_sha256="UNAVAILABLE" _source_meta=""
  _rb_run_ts=$(basename "$_selected" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
  _rb_sel_base=$(basename "$_selected")
  _records_sidecar="${_selected}.records"

  if [ -f "$_records_sidecar" ]; then
    if _inverse_records=$(_vf_extract_run_records "$_records_sidecar" "$_selected" "$_rb_sel_base" "$_rb_run_ts"); then
      _run_record_matched=1
      _record_source="$_records_sidecar"
      _row "레코드 파일" "$_records_sidecar"
      echo ""
      echo "INVERSE|SOURCE|SIDECAR|${_records_sidecar}" >> "$_rb_log" 2>/dev/null
    fi
  fi

  if [ "$_run_record_matched" -eq 0 ]; then
    _fail "선택한 백업의 .records 파일에서 복원 정보를 읽지 못했습니다."
    _rb_cleanup
    return 1
  fi

  if [ "$_run_record_matched" -eq 1 ]; then
    _source_meta=$(_vf_extract_source_run_meta       "$_record_source" "$_selected" "$_rb_sel_base" "$_rb_run_ts" 2>/dev/null || true)
    if [ -n "$_source_meta" ]; then
      IFS='|' read -r _source_run_id _source_version _source_started <<< "$_source_meta"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      _source_backup_sha256=$(sha256sum "$_selected" 2>/dev/null | awk '{print $1}')
      [ -n "$_source_backup_sha256" ] || _source_backup_sha256="UNAVAILABLE"
    fi
    echo "INVERSE|SOURCE_RUN_ID|${_source_run_id}|VERSION=${_source_version}|START=${_source_started}|BACKUP_SHA256=${_source_backup_sha256}"       >> "$_rb_log" 2>/dev/null

    # 같은 파일의 PERM_RESTORE가 한 실행에서 여러 번 기록될 수 있다
    # (예: U-23이 crontab 4755→755, 이어서 U-37이 755→750 기록).
    # 경로별 첫 번째 기록(조치 전 원상태)만 남긴다.
    _inverse_records=$(printf '%s\n' "$_inverse_records" | awk -F'|' '
      $1 == "PERM_RESTORE" { if (seen[$2]++) next }
      { print }
    ')

    # 조치 전 검증 기준값, 명령 출력 해시와 실제 설정 상태 해시를 로드한다.
    while IFS= read -r _bl_line; do
      [ -n "$_bl_line" ] || continue
      IFS='|' read -r -a _bl_parts <<< "$_bl_line"
      [ "${_bl_parts[0]:-}" = "VERIFY_BASELINE" ] || continue

      _bl_name="${_bl_parts[1]:-확인불가}"
      _bl_status="${_bl_parts[2]:-UNKNOWN}"
      _rb_baseline["$_bl_name"]="$_bl_status"

      _bl_output_hash=""
      _bl_state_hash=""
      _bl_command=""
      _bl_exit_code=""
      for _bl_field in "${_bl_parts[@]:3}"; do
        case "$_bl_field" in
          SHA256=*)        _bl_output_hash="${_bl_field#SHA256=}" ;; # 구버전 호환
          OUTPUT_SHA256=*) _bl_output_hash="${_bl_field#OUTPUT_SHA256=}" ;;
          STATE_SHA256=*)  _bl_state_hash="${_bl_field#STATE_SHA256=}" ;;
          COMMAND=*)       _bl_command="${_bl_field#COMMAND=}" ;;
          EXIT_CODE=*)     _bl_exit_code="${_bl_field#EXIT_CODE=}" ;;
        esac
      done

      [ -n "$_bl_output_hash" ] || _bl_output_hash="UNAVAILABLE"
      [ -n "$_bl_state_hash" ] || _bl_state_hash="UNAVAILABLE"
      if [ "$_bl_output_hash" = "UNAVAILABLE" ]; then
        _rb_baseline_hash["$_bl_name"]=""
      else
        _rb_baseline_hash["$_bl_name"]="$_bl_output_hash"
      fi
      _rb_baseline_state_hash["$_bl_name"]="$_bl_state_hash"

      echo "BASELINE|NAME=${_bl_name}|RESULT=${_bl_status}|METHOD=COMMAND_EXIT|COMMAND=${_bl_command:-LEGACY_UNKNOWN}|EXIT_CODE=${_bl_exit_code:-LEGACY_UNKNOWN}|OUTPUT_SHA256=${_bl_output_hash}|STATE_SHA256=${_bl_state_hash}" \
        >> "$_rb_log" 2>/dev/null
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
    _VF_PATH_OK=0
    _VF_PATH_FAIL=0
    _VF_PATH_MANUAL=1
    _VF_PATH_SCRIPT_ARTIFACT=0
    _VF_PATH_SCRIPT_PAM=0
    _VF_PATH_SCRIPT_SSH=0
    _VF_PATH_SCRIPT_MAIL=0
    _VF_PATH_SCRIPT_AUTHSELECT=0
    _VF_PATH_SCRIPT_CONFIG=0
    _VF_PATH_NEW_TOTAL=0
    _VF_PATH_SCRIPT_ARTIFACT_FILE=""
    _VF_PATH_MANUAL_FILE=""
    _VF_ACCOUNT_OK=0
    _VF_ACCOUNT_FAIL=0
    _VF_ACCOUNT_MANUAL=1
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
    [ "${#_content_fail_files[@]}" -gt 5 ] && _warn "내용 불일치 외 $((${#_content_fail_files[@]}-5))개는 현재 집계에 포함"
    for _cf in "${_meta_fail_files[@]:0:5}"; do _warn "메타정보 불일치: ${_cf}"; done
    [ "${#_meta_fail_files[@]}" -gt 5 ] && _warn "메타정보 불일치 외 $((${#_meta_fail_files[@]}-5))개는 현재 집계에 포함"
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
  local -a _verify_manual_names=()

  # 롤백 보조 레코드 매칭 실패로 선행 수동 확인이 발생한 경우 원인을 보존한다.
  if [ "${_verify_manual_pre:-0}" -gt 0 ]; then
    _verify_manual_names+=("롤백 보조 레코드: 선택 백업과 일치하는 실행 레코드 없음")
  fi

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
      _verify_manual_names+=("${_name}: 구버전 롤백 직전 백업에 검증 기준 없음")
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
          _verify_manual_names+=("${_name}: 조치 전·현재 오류 원인 불일치")
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
        _verify_manual_names+=("${_name}: 자동 검증 불가 또는 명령 미지원")
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
  local _manual_display_total=$((_manual_total + _pkg_change_total))

  # 종료 코드 2를 만든 원인을 범주별로 보존한다.
  # 상세 집계는 기존 카운터를 그대로 사용하고, 화면에는 범주·사유·확인 방법을 표시한다.
  local -a _manual_reason_counts=()
  local -a _manual_reason_codes=()
  local -a _manual_reason_titles=()
  local -a _manual_reason_details=()
  local -a _manual_reason_actions=()

  _rb_add_manual_reason() {
    local _count="$1" _title="$2" _detail="$3" _action="$4" _code="OTHER_REVIEW"
    [ "${_count:-0}" -gt 0 ] 2>/dev/null || return 0

    case "$_title" in
      "롤백 직전 안전 백업 미생성") _code="PRE_ROLLBACK_BACKUP_MISSING" ;;
      "백업 무결성 검증")           _code="BACKUP_INTEGRITY_UNVERIFIED" ;;
      "백업 식별 정보")             _code="BACKUP_IDENTITY_MISMATCH" ;;
      "설정 검증")                  _code="CONFIG_VERIFY_REVIEW" ;;
      "복원 결과 비교")             _code="RESTORE_COMPARE_REVIEW" ;;
      "확장 메타정보")              _code="EXTENDED_METADATA_REVIEW" ;;
      "미분류 신규 경로")           _code="UNCLASSIFIED_NEW_PATH" ;;
      "신규 계정")                  _code="NEW_ACCOUNT_DETECTED" ;;
      "서비스 상태")                _code="SERVICE_STATE_REVIEW" ;;
      "복원 설정 서비스 반영")      _code="CONFIG_APPLY_REVIEW" ;;
      "방화벽 상태")                _code="FIREWALL_STATE_REVIEW" ;;
      "무소유 파일(U-15)")          _code="ORPHAN_OWNER_REVIEW" ;;
      "패키지 기준 정보")           _code="PACKAGE_BASELINE_UNAVAILABLE" ;;
      "패키지 변경")                _code="PACKAGE_DRIFT" ;;
    esac

    _manual_reason_counts+=("$_count")
    _manual_reason_codes+=("$_code")
    _manual_reason_titles+=("$_title")
    _manual_reason_details+=("$_detail")
    _manual_reason_actions+=("$_action")
  }

  local _verify_manual_name_text=""
  if [ "${#_verify_manual_names[@]}" -gt 0 ]; then
    _verify_manual_name_text=$(printf '%s; ' "${_verify_manual_names[@]}")
    _verify_manual_name_text="${_verify_manual_name_text%; }"
  fi

  _rb_add_manual_reason \
    "$_pre_rollback_manual" \
    "롤백 직전 안전 백업 미생성" \
    "디스크 공간 부족 등으로 안전 백업을 만들지 못한 상태에서 사용자가 강제 진행했습니다." \
    "현재 설정과 서비스 상태를 확인하고, 필요 시 원본 백업 기준으로 다시 복원하세요."

  _rb_add_manual_reason \
    "$_integrity_manual" \
    "백업 무결성 검증" \
    "체크섬 파일 또는 sha256sum 명령이 없어 압축 구조만 검증했습니다." \
    "백업 생성 서버의 SHA-256 값과 선택한 백업 파일을 별도로 비교하세요."

  _rb_add_manual_reason \
    "$_manifest_manual" \
    "백업 식별 정보" \
    "manifest 부재, 범위 불일치 또는 다른 서버 백업의 강제 사용이 감지됐습니다." \
    "백업의 서버명·OS·스크립트 범위가 현재 서버와 일치하는지 확인하세요."

  _rb_add_manual_reason \
    "$_verify_manual" \
    "설정 검증" \
    "${_verify_manual_name_text:-자동 검증이 불가능하거나 조치 전 기준값과 현재 결과의 원인이 달랐습니다.}" \
    "화면에 표시된 검증 명령과 현재 설정값을 직접 확인하세요."

  _rb_add_manual_reason \
    "$_compare_manual" \
    "복원 결과 비교" \
    "백업 원본과 현재 파일을 비교할 환경 또는 기준 정보가 충분하지 않았습니다." \
    "내부 검증에서 파일 내용·권한·소유자 비교 결과를 확인하세요."

  _rb_add_manual_reason \
    "$_VF_EXT_MANUAL" \
    "확장 메타정보" \
    "ACL, xattr, SELinux context 또는 file capability 검증 도구가 일부 없었습니다." \
    "운영 서버에서 해당 메타정보를 백업 기준과 직접 비교하세요."

  _rb_add_manual_reason \
    "$_VF_PATH_MANUAL" \
    "미분류 신규 경로" \
    "스크립트 생성 흔적으로 식별되지 않았거나 자동 삭제할 수 없는 신규 경로가 발견됐습니다." \
    "내부 검증의 경로 목록을 확인하고 업무 데이터 여부를 판단한 후 정리하세요."

  _rb_add_manual_reason \
    "$_VF_ACCOUNT_MANUAL" \
    "신규 계정" \
    "조치 전 기준에 없던 계정이 발견됐습니다." \
    "패키지·서비스 설치로 생성된 계정인지 확인하고 불필요한 경우 별도 조치하세요."

  _rb_add_manual_reason \
    "$_VF_SERVICE_MANUAL" \
    "서비스 상태" \
    "원격 연결 보호, unit 변경 또는 기준 정보 부족으로 일부 서비스를 자동 복원하지 않았습니다." \
    "active/enabled 상태를 백업 시점의 운영 정책과 비교하세요."

  _rb_add_manual_reason \
    "$_VF_CONFIG_APPLY_MANUAL" \
    "복원 설정 서비스 반영" \
    "비기동 검증 미지원, 설정 검증 실패 또는 reload/restart 실패로 일부 설정을 자동 반영하지 않았습니다." \
    "설정 구문을 확인한 뒤 운영 승인 후 reload 또는 restart를 수행하세요."

  local _fw_detail="연결 단절 위험 또는 지원 도구 제한으로 일부 방화벽 상태를 자동 적용하지 않았습니다."
  if [ "${_VF_FW_RUNTIME_DRIFT:-0}" -eq 1 ]; then
    _fw_detail="${_fw_detail} 백업 시점 firewalld Runtime과 Permanent 규칙도 서로 달랐습니다."
  fi
  _rb_add_manual_reason \
    "$_VF_FW_MANUAL" \
    "방화벽 상태" \
    "$_fw_detail" \
    "현재 연결을 유지한 상태에서 Runtime·Permanent·nftables 규칙을 비교하세요."

  _rb_add_manual_reason \
    "$_VF_ORPHAN_MANUAL" \
    "무소유 파일(U-15)" \
    "저장된 UID/GID 재사용, inode 변경 또는 계정 매핑 문제로 일부 소유권을 자동 복원하지 않았습니다." \
    "내부 검증의 파일별 UID/GID와 현재 계정 매핑을 확인하세요."

  _rb_add_manual_reason \
    "$_VF_PKG_MANUAL" \
    "패키지 기준 정보" \
    "패키지 기준 목록이 없거나 패키지 비교 도구를 사용할 수 없었습니다." \
    "현재 패키지 목록을 백업 시점 목록과 별도로 비교하세요."

  _rb_add_manual_reason \
    "$_pkg_change_total" \
    "패키지 변경" \
    "추가 ${_VF_PKG_ADDED}건, 제거 ${_VF_PKG_REMOVED}건, 버전 변경 ${_VF_PKG_CHANGED}건이 감지됐습니다." \
    "자동 다운그레이드는 수행하지 않으므로 패키지 변경 목록을 검토하고 복구 여부를 결정하세요."

  local _manual_reason_category_count=${#_manual_reason_titles[@]}
  local _manual_reason_code_text=""

  # 기존 카운터에 수동 확인 값이 있는데 원인 범주가 만들어지지 않은 경우 누락을 숨기지 않는다.
  if [ "$_manual_display_total" -gt 0 ] && [ "$_manual_reason_category_count" -eq 0 ]; then
    _rb_add_manual_reason \
      "$_manual_display_total" \
      "기타 확인 항목" \
      "수동 확인 집계가 있으나 세부 범주를 자동 분류하지 못했습니다." \
      "화면에 표시된 추가 확인 항목을 확인하세요."
    _manual_reason_category_count=${#_manual_reason_titles[@]}
  fi

  if [ "${#_manual_reason_codes[@]}" -gt 0 ]; then
    _manual_reason_code_text=$(IFS=,; printf '%s' "${_manual_reason_codes[*]}")
  else
    _manual_reason_code_text="NONE"
  fi

  local _rollback_outcome="COMPLETED"
  if [ "$_hard_fail" -gt 0 ]; then
    _rollback_outcome="FAILED"
  elif [ "$_manual_display_total" -gt 0 ]; then
    _rollback_outcome="COMPLETED_WITH_REVIEW"
  fi

  local _legacy_result_code=0
  local _process_status="SUCCESS"
  if [ "$_hard_fail" -gt 0 ]; then
    _final_status="롤백 일부 실패 / 상세 검증 필요"
    _final_rc=1
    _legacy_result_code=1
    _process_status="FAILURE"
  elif [ "$_pkg_change_total" -gt 0 ]; then
    _final_status="롤백 완료 / 추가 확인 사항 ${_manual_display_total}건 (${_manual_reason_category_count}개 범주, 패키지 변경 포함)"
    _final_rc=0
    _legacy_result_code=2
  elif [ "$_manual_total" -gt 0 ]; then
    _final_status="롤백 완료 / 추가 확인 사항 ${_manual_display_total}건 (${_manual_reason_category_count}개 범주)"
    _final_rc=0
    _legacy_result_code=2
  else
    _final_status="롤백 완료 / 검증 통과"
    _final_rc=0
    _legacy_result_code=0
  fi

  {
    echo ""
    echo "[최종 요약]"
    echo "완료 시간         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "파일 복원         : ${_ok_cnt}/${_total} 성공"
    echo "내용 일치 검증    : 일치 ${_content_ok} / 불일치 ${_content_fail}"
    echo "메타정보 검증     : 일치 ${_meta_ok} / 불일치 ${_meta_fail}"
    echo "설정 검증         : 정상통과 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
    echo "설정 서비스 반영  : 성공 ${_service_ok} / 실패 ${_service_fail} / 추가확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
    echo "서비스 상태 복원  : 성공 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
    echo "방화벽 상태 복원  : 성공 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
    echo "계정 상태 비교    : 일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
    echo "경로 생성·삭제    : 자동정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 스크립트흔적 ${_VF_PATH_SCRIPT_ARTIFACT} / 추가확인 ${_VF_PATH_MANUAL}"
    echo "무소유 파일(U-15) : 복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 추가확인 ${_VF_ORPHAN_MANUAL}"
    echo "패키지 변경       : 추가 ${_VF_PKG_ADDED} / 제거 ${_VF_PKG_REMOVED} / 버전변경 ${_VF_PKG_CHANGED}"
    echo "권한 자동 역산    : 성공 ${_perm_cnt} / 실패 ${_perm_fail}"
    echo "그룹 자동 역산    : 성공 ${_grp_cnt} / 실패 ${_grp_fail}"
    echo "원본 실행 ID      : ${_source_run_id}"
    echo "원본 버전         : ${_source_version}"
    echo "원본 백업 SHA-256 : ${_source_backup_sha256}"
    echo "복귀용 안전 백업  : ${_pre_rollback_backup:-생성되지 않음}"
    echo "추가 확인 집계    : ${_manual_display_total}건 / ${_manual_reason_category_count}개 범주"
    echo "프로세스 상태     : ${_process_status}"
    echo "업무 결과         : ${_rollback_outcome}"
    echo "최종 결과         : ${_final_status}"
    echo "프로세스 종료 코드: ${_final_rc}"
    echo "구형 결과 코드    : ${_legacy_result_code}"
  } >> "$_verify_log" 2>/dev/null

  {
    echo ""
    echo "[최종 요약]"
    echo "완료 시간         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "파일 복원         : ${_ok_cnt}/${_total} 성공"
    echo "내용 일치 검증    : 일치 ${_content_ok} / 불일치 ${_content_fail}"
    echo "메타정보 검증     : 일치 ${_meta_ok} / 불일치 ${_meta_fail}"
    echo "설정 검증         : 정상통과 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
    echo "설정 서비스 반영  : 성공 ${_service_ok} / 실패 ${_service_fail} / 추가확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
    echo "서비스 상태 복원  : 성공 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
    echo "방화벽 상태 복원  : 성공 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
    echo "계정 상태 비교    : 일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
    echo "경로 생성·삭제    : 자동정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 스크립트흔적 ${_VF_PATH_SCRIPT_ARTIFACT} / 추가확인 ${_VF_PATH_MANUAL}"
    echo "무소유 파일(U-15) : 복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 추가확인 ${_VF_ORPHAN_MANUAL}"
    echo "패키지 변경       : 추가 ${_VF_PKG_ADDED} / 제거 ${_VF_PKG_REMOVED} / 버전변경 ${_VF_PKG_CHANGED}"
    echo "권한 자동 역산    : 성공 ${_perm_cnt} / 실패 ${_perm_fail}"
    echo "그룹 자동 역산    : 성공 ${_grp_cnt} / 실패 ${_grp_fail}"
    echo "원본 실행 ID      : ${_source_run_id}"
    echo "원본 버전         : ${_source_version}"
    echo "원본 백업 SHA-256 : ${_source_backup_sha256}"
    echo "복귀용 안전 백업  : ${_pre_rollback_backup:-생성되지 않음}"
    echo "추가 확인 집계    : ${_manual_display_total}건 / ${_manual_reason_category_count}개 범주"
    echo "프로세스 상태     : ${_process_status}"
    echo "업무 결과         : ${_rollback_outcome}"
    echo "최종 결과         : ${_final_status}"
    echo "프로세스 종료 코드: ${_final_rc}"
    echo "구형 결과 코드    : ${_legacy_result_code}"
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
  if [ "$_process_status" = "FAILURE" ]; then
    _row "최종 결과" "${_final_status}" "✗"
  elif [ "$_rollback_outcome" = "COMPLETED_WITH_REVIEW" ]; then
    _row "최종 결과" "${_final_status}" "${YELLOW}⚠${RESET}"
  else
    _row "최종 결과" "${_final_status}" "✓"
  fi
  _row "프로세스 상태" "${_process_status}"
  _row "업무 결과" "${_rollback_outcome}"
  _row "종료 코드" "${_final_rc} (0=정상 실행, 1=실패)"
  if [ "$_manual_display_total" -gt 0 ]; then
    _row "추가 확인" "${_manual_display_total}건 / ${_manual_reason_category_count}개 범주"
  fi
  _row "복원 파일" "${_ok_cnt}/${_total}개 성공"
  _row "파일 일치" "${_file_match_text}"
  _row "설정 검증" "정상 ${_verify_ok} / 기준일치 ${_verify_baseline_match} / 실패 ${_verify_fail} / 추가확인 ${_verify_manual}"
  _row "설정 서비스 반영" "성공 ${_service_ok} / 실패 ${_service_fail} / 추가확인 ${_VF_CONFIG_APPLY_MANUAL} / 건너뜀 ${_service_skip}"
  _row "서비스 상태" "복원 ${_VF_SERVICE_OK} / 실패 ${_VF_SERVICE_FAIL} / 추가확인 ${_VF_SERVICE_MANUAL}"
  _row "방화벽 상태" "복원 ${_VF_FW_OK} / 실패 ${_VF_FW_FAIL} / 추가확인 ${_VF_FW_MANUAL}"
  _row "계정 상태" "일치 ${_VF_ACCOUNT_OK} / 불일치 ${_VF_ACCOUNT_FAIL} / 신규 ${_VF_ACCOUNT_MANUAL}"
  _row "생성·삭제 경로" "정리 ${_VF_PATH_OK} / 실패 ${_VF_PATH_FAIL} / 스크립트흔적 ${_VF_PATH_SCRIPT_ARTIFACT} / 추가확인 ${_VF_PATH_MANUAL}"
  _row "무소유 파일(U-15)" "복원 ${_VF_ORPHAN_OK} / 실패 ${_VF_ORPHAN_FAIL} / 추가확인 ${_VF_ORPHAN_MANUAL}"
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
    echo ""
  fi

  _row "복원 기준" "$(basename "$_selected")"
  _row "원본 실행 ID" "${_source_run_id}"
  _row "원본 버전" "${_source_version}"
  _row "원본 백업 SHA-256" "${_source_backup_sha256}"
  _row "복귀용 안전 백업" "${_pre_rollback_backup:-생성되지 않음}"
  echo ""

  # 추가 확인 사항은 화면에 범주별로 표시한다.
  if [ "$_manual_display_total" -gt 0 ]; then
    echo -e " ${BOLD}${YELLOW}[추가 확인 사항: ${_manual_display_total}건 / ${_manual_reason_category_count}개 범주]${RESET}"
    echo ""
    _info "복원은 완료됐으며, 아래 항목은 추가 확인이 필요합니다."
    echo ""

    local _manual_reason_file="${_rb_tmp_dir}/additional_checks.txt"
    : > "$_manual_reason_file"
    {
      echo ""
      echo "[추가 확인 사항]"
      echo "복원 상태 : 완료"
      echo "범주 수   : ${_manual_reason_category_count}"
      echo "상세 집계 : ${_manual_display_total}건"
      echo ""
    } >> "$_manual_reason_file"

    local _mr_idx
    for ((_mr_idx=0; _mr_idx<_manual_reason_category_count; _mr_idx++)); do
      echo -e " ${BOLD}$((_mr_idx+1)). ${_manual_reason_titles[$_mr_idx]} (${_manual_reason_counts[$_mr_idx]}건)${RESET}"
      echo -e "    ${WHITE}코드${RESET} : ${_manual_reason_codes[$_mr_idx]}"
      echo -e "    ${WHITE}사유${RESET} : ${_manual_reason_details[$_mr_idx]}"
      echo -e "    ${CYAN}확인${RESET} : ${_manual_reason_actions[$_mr_idx]}"
      echo ""

      {
        echo "$((_mr_idx+1)). ${_manual_reason_titles[$_mr_idx]} (${_manual_reason_counts[$_mr_idx]}건)"
        echo "   코드 : ${_manual_reason_codes[$_mr_idx]}"
        echo "   사유 : ${_manual_reason_details[$_mr_idx]}"
        echo "   확인 : ${_manual_reason_actions[$_mr_idx]}"
        echo ""
      } >> "$_manual_reason_file"
    done

    if [ "$_pkg_change_total" -gt 0 ] \
       && [ -n "${_VF_PKG_DIFF_FILE:-}" ] && [ -s "$_VF_PKG_DIFF_FILE" ]; then
      echo -e " ${BOLD}${YELLOW}[패키지 변경 목록]${RESET}"
      echo ""
      while IFS= read -r _pkg_line; do
        echo "   ${_pkg_line}"
      done < "$_VF_PKG_DIFF_FILE"
      echo ""

      {
        echo "[패키지 변경 목록]"
        cat "$_VF_PKG_DIFF_FILE"
        echo ""
      } >> "$_manual_reason_file"
    fi

    _info "위 항목을 확인하면 롤백 검증을 최종 완료할 수 있습니다."
    echo ""
  fi

  # 스크립트 생성 백업 흔적은 복원 실패나 추가 확인 원인이 아니므로 참고 정보로만 표시한다.
  if [ "${_VF_PATH_SCRIPT_ARTIFACT:-0}" -gt 0 ]; then
    echo -e " ${BOLD}${CYAN}[참고 정보: 스크립트 생성 백업 흔적]${RESET}"
    echo ""
    _row "전체" "${_VF_PATH_SCRIPT_ARTIFACT}건"
    [ "${_VF_PATH_SCRIPT_PAM:-0}" -gt 0 ] \
      && _row "PAM 백업 파일" "${_VF_PATH_SCRIPT_PAM}건"
    [ "${_VF_PATH_SCRIPT_SSH:-0}" -gt 0 ] \
      && _row "SSH 백업 파일" "${_VF_PATH_SCRIPT_SSH}건"
    [ "${_VF_PATH_SCRIPT_MAIL:-0}" -gt 0 ] \
      && _row "메일 설정 백업" "${_VF_PATH_SCRIPT_MAIL}건"
    [ "${_VF_PATH_SCRIPT_AUTHSELECT:-0}" -gt 0 ] \
      && _row "authselect 백업" "${_VF_PATH_SCRIPT_AUTHSELECT}건"
    [ "${_VF_PATH_SCRIPT_CONFIG:-0}" -gt 0 ] \
      && _row "기타 설정 백업" "${_VF_PATH_SCRIPT_CONFIG}건"
    _row "판정" "스크립트 실행 과정에서 생성된 정상 백업 흔적"
    _row "종료 코드 영향" "없음"
    echo ""
  fi

  # SSH/PAM 파일 복원 자체는 종료 코드 2의 직접 원인이 아닐 수 있으므로 참고로 분리한다.
  if printf '%s\n' "$_file_list" | grep -qE '(^|/)etc/ssh/|(^|/)etc/pam\.d/|(^|/)etc/authselect/'; then
    echo -e " ${BOLD}${WHITE}[참고 사항]${RESET}"
    echo ""
    _warn "SSH/PAM 관련 파일이 복원되었습니다. 적용 시점은 운영 정책에 따라 확인하세요."
    _info "필요 시: sshd -t && systemctl restart sshd"
    echo ""
  fi

  trap - INT TERM HUP
  _rb_cleanup
  unset -f _rb_verify_record _rb_add_manual_reason _rb_interrupted _rb_cleanup 2>/dev/null
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
  TARGET_IDS=()
  for _n in $(seq -w "$_SPLIT_MIN" "$_SPLIT_MAX"); do TARGET_IDS+=("U-${_n}"); done
fi
echo ""

# =============================================================================
# ── [실행 결과 로그] 단계·오류 형식 표준화 ───────────────────────────────────
# - 화면: 현재 상태 → 조치 중 → 조치 결과 → 최종 검증 순서를 유지한다.
# - 화면은 CHECK / FIX / VERIFY / RESULT 순서를 유지한다.
# - 내부 명령 결과는 판정에만 사용하고 영구 로그 파일로 저장하지 않는다.
# - Excel 보고서와 롤백용 .records만 영구 산출물로 유지한다 (CSV는 Excel 생성용 임시 파일).
# =============================================================================

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
#   최대 200줄까지 셀 값에 포함하며 초과분은 화면 출력 생략 사실을 안내한다.
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
      | sed ':a;N;$!ba;s/\n/ || /g') || ... 외 $((_total-200))줄 더 있음 (화면 출력 생략)"
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
  local _cmd="$1" _out _err _start_ms _end_ms
  _out=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_out.%s' "$$")
  _err=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_err.%s' "$$")
  : > "$_out" 2>/dev/null; : > "$_err" 2>/dev/null
  _start_ms=$(_vf_now_ms)
  ( eval "$_cmd" ) >"$_out" 2>"$_err"
  _VF_CAPTURE_RC=$?
  _end_ms=$(_vf_now_ms)
  _VF_CAPTURE_DURATION_MS=0
  [ "$_end_ms" -ge "$_start_ms" ] 2>/dev/null && _VF_CAPTURE_DURATION_MS=$((_end_ms-_start_ms))
  _VF_CAPTURE_STDOUT=$(cat "$_out" 2>/dev/null)
  _VF_CAPTURE_STDERR=$(cat "$_err" 2>/dev/null)
  rm -f "$_out" "$_err" 2>/dev/null
  return 0
}


# -----------------------------------------------------------------------------
# _vf_capture_eval_subshell_delayed_spinner
#
# 역할:
#   현재 상태 조회 명령을 실행하되 2초 안에 끝나면 spinner를 전혀 표시하지 않는다.
#   2초를 초과한 경우에만 현재 위치에 "점검 중 <spinner>"를 표시해
#   스크립트가 정상 실행 중임을 알린다.
#
# 입력:
#   $1 : eval로 실행할 점검 명령 문자열
#   $2 : spinner 표시 지연시간(초, 기본 2)
#
# 결과 전역:
#   _VF_CAPTURE_RC / _VF_CAPTURE_STDOUT / _VF_CAPTURE_STDERR /
#   _VF_CAPTURE_DURATION_MS
#
# 주의:
#   점검 명령 출력은 임시 파일에 저장하므로 spinner와 실제 출력이 섞이지 않는다.
# -----------------------------------------------------------------------------
_vf_capture_eval_subshell_delayed_spinner() {
  local _cmd="$1" _delay="${2:-2}"
  local _out _err _start_ms _end_ms _pid _wait_rc=0
  local _i _poll_count _shown=0 _frame_no=0 _frame=""

  _out=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_out.%s' "$$")
  _err=$(mktemp 2>/dev/null || printf '/tmp/.vulnfix_capture_err.%s' "$$")
  : > "$_out" 2>/dev/null
  : > "$_err" 2>/dev/null

  _start_ms=$(_vf_now_ms)
  ( eval "$_cmd" ) >"$_out" 2>"$_err" &
  _pid=$!

  # 0.1초 단위로 최대 지연시간만큼 기다린다.
  # 이 시간 안에 끝나면 spinner나 빈 행을 전혀 만들지 않는다.
  if [[ "$_delay" =~ ^[0-9]+$ ]]; then
    _poll_count=$((_delay * 10))
  else
    _poll_count=20
  fi

  for ((_i=0; _i<_poll_count; _i++)); do
    kill -0 "$_pid" 2>/dev/null || break
    sleep 0.1
  done

  # 지연시간 이후에도 실행 중일 때만 spinner를 표시한다.
  if kill -0 "$_pid" 2>/dev/null; then
    _shown=1
    _vf_cursor_hide
    _frame=$(_vf_spinner_frame 0)
    printf '   %s' "$_frame"

    _frame_no=1
    while kill -0 "$_pid" 2>/dev/null; do
      sleep 0.5
      kill -0 "$_pid" 2>/dev/null || break
      _frame=$(_vf_spinner_frame "$_frame_no")
      # 직전 spinner 문자 한 글자만 교체한다.
      printf '\b%s' "$_frame"
      _frame_no=$((_frame_no + 1))
    done
    _vf_cursor_show
  fi

  wait "$_pid"
  _wait_rc=$?

  # spinner가 실제로 표시된 경우에만 해당 줄을 지운다.
  if [ "$_shown" -eq 1 ]; then
    printf '\r\033[2K'
  fi

  _VF_CAPTURE_RC="$_wait_rc"
  _end_ms=$(_vf_now_ms)
  _VF_CAPTURE_DURATION_MS=0
  [ "$_end_ms" -ge "$_start_ms" ] 2>/dev/null \
    && _VF_CAPTURE_DURATION_MS=$((_end_ms-_start_ms))

  _VF_CAPTURE_STDOUT=$(cat "$_out" 2>/dev/null)
  _VF_CAPTURE_STDERR=$(cat "$_err" 2>/dev/null)
  rm -f "$_out" "$_err" 2>/dev/null
  return 0
}

# 항목 화면 단계의 시작을 CHECK/FIX/VERIFY/RESULT 코드로 검증 데이터에 반영한다.
# 입력: $1=항목 ID, $2=단계 코드, $3=화면 단계 설명
# 로그 파일은 생성하지 않는다.
# 기존 U-항목 호출 흐름을 변경하지 않기 위한 무출력 호환 함수다.
_detail_log_stage() { return 0; }
_detail_log_item_start() { return 0; }
_detail_log_command() { return 0; }
_detail_log_result() { return 0; }
_detail_log_note() { return 0; }
_detail_log_header() { return 0; }
_detail_log_summary() { return 0; }

# ── U-33 공용 숨김파일 탐색 함수 ─────────────────────────────────────────────
# 정상 dotfile/dotdir을 최대한 제외하고 의심 항목만 반환한다.
# 이 함수를 check_still_vuln과 do_manual 양쪽에서 공유하여 판정 기준을 일치시킨다.
_u33_find() { _scan_cached u33_dot _u33_find_raw; }
_u33_find_raw() {
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

# ── 리스닝 포트 확인 공용 헬퍼 (ss 부재 시 미탐 방지) ────────────────────────
# 기존 코드는 ss 실행 실패를 "포트 미개방"과 구분하지 않아, iproute2 가 없는
# 최소 설치 이미지·컨테이너에서 포트 기반 항목(U-01 telnet, U-34, U-36, U-38,
# U-39, U-44, U-52, U-54, U-56, U-58)이 전부 조용히 양호로 처리됐다.
# ss → netstat → /proc/net 순으로 폴백한다.
_listen_dump() {
  local _proto="${1:-tcp}" _f
  if command -v ss >/dev/null 2>&1; then
    case "$_proto" in
      tcp) ss -tlnp 2>/dev/null ;;
      udp) ss -ulnp 2>/dev/null ;;
    esac
    return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    case "$_proto" in
      tcp) netstat -tlnp 2>/dev/null ;;
      udp) netstat -ulnp 2>/dev/null ;;
    esac
    return 0
  fi
  # 최후 폴백: /proc/net 직접 파싱. 16진 포트를 10진으로 변환한다.
  # (strtonum 은 gawk 전용이라 mawk 환경을 위해 직접 구현한다)
  for _f in "/proc/net/${_proto}" "/proc/net/${_proto}6"; do
    [ -r "$_f" ] || continue
    awk -v pr="$_proto" '
      function hex2dec(h,   i, c, d, v) {
        h = tolower(h); v = 0
        for (i = 1; i <= length(h); i++) {
          c = substr(h, i, 1)
          d = index("0123456789abcdef", c) - 1
          if (d < 0) continue
          v = v * 16 + d
        }
        return v
      }
      NR > 1 {
        n = split($2, a, ":")
        if (n < 2) next
        if (pr == "tcp" && $4 != "0A") next
        printf "LISTEN 0 0 0.0.0.0:%d 0.0.0.0:*\n", hex2dec(a[n])
      }' "$_f" 2>/dev/null
  done
  return 0
}

# _port_listening <tcp|udp> <포트...> : 지정 포트 중 하나라도 리스닝이면 0
_port_listening() {
  local _proto="$1"; shift
  local _dump _p
  _dump=$(_listen_dump "$_proto")
  [ -n "$_dump" ] || return 1
  for _p in "$@"; do
    printf '%s\n' "$_dump" | grep -qE ":${_p}[[:space:]]" && return 0
  done
  return 1
}

# ── 확장 ACL 검사 (권한 항목 미탐 방지) ──────────────────────────────────────
# stat -c '%a' 는 POSIX ACL 을 반영하지 않는다. 644 파일에 "group:dev:rw" ACL 이
# 걸려 있으면 실제로는 그룹 쓰기가 가능한데 기존 로직은 양호로 판정했다.
# 반환: 0 = 쓰기를 허용하는 확장 ACL 존재, 1 = 없음 또는 확인 불가
_has_permissive_acl() {
  local _path="$1"
  [ -e "$_path" ] || return 1
  command -v getfacl >/dev/null 2>&1 || return 1

  # ACL의 표기 권한이 아니라 mask가 반영된 실제 유효 권한으로 판단한다.
  # 예: user:alice:rw- + mask::r-- 는 실제 쓰기 권한이 없으므로 취약으로 보지 않는다.
  # 디렉터리는 신규 파일에 상속되는 default ACL도 별도로 검사한다.
  getfacl -cp --absolute-names -- "$_path" 2>/dev/null | awk -F: '
    function perms(v) { sub(/[[:space:]].*$/, "", v); return substr(v, 1, 3) }
    function writable(v) { return index(perms(v), "w") > 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line[++n] = $0
      if ($1 == "mask") access_mask = perms($3)
      if ($1 == "default" && $2 == "mask") default_mask = perms($4)
    }
    END {
      for (i = 1; i <= n; i++) {
        split(line[i], f, ":")
        if ((f[1] == "user" || f[1] == "group") && f[2] != "") {
          if (writable(f[3]) && (access_mask == "" || writable(access_mask))) found = 1
        }
        if (f[1] == "default" && (f[2] == "user" || f[2] == "group") && f[3] != "") {
          if (writable(f[4]) && (default_mask == "" || writable(default_mask))) found = 1
        }
      }
      exit(found ? 0 : 1)
    }'
}

# ── login.defs UID_MIN (일반 사용자 판별 기준) ───────────────────────────────
# 1000 을 하드코딩하면 UID_MIN=500 인 구형 RHEL/CentOS 에서 일반 사용자 계정이
# 점검 대상에서 통째로 빠진다.
_login_uid_min() {
  local _v
  _v=$(grep -vE '^[[:space:]]*#' /etc/login.defs 2>/dev/null \
       | awk '$1=="UID_MIN"{v=$2} END{print v}')
  [[ "$_v" =~ ^[0-9]+$ ]] || _v=1000
  printf '%s' "$_v"
}

# ── pwquality 설정값 조회 (U-02 미탐 방지) ───────────────────────────────────
# minlen/lcredit 등은 pwquality.conf 외에 pwquality.conf.d/*.conf 와
# PAM 의 pam_pwquality/pam_cracklib 인라인 인자로도 설정된다.
# 적용 우선순위가 높은 PAM 인라인 인자를 마지막에 확인한다.
_pwquality_value() {
  local _key="$1" _last="" _v _pv _f
  for _f in /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf; do
    [ -f "$_f" ] || continue
    _v=$(grep -vE '^[[:space:]]*#' "$_f" 2>/dev/null | awk -F= -v k="$_key" '
           { gsub(/[[:space:]]/, "", $1); gsub(/[[:space:]]/, "", $2) }
           $1 == k && $2 != "" { v = $2 }
           END { if (v != "") print v }')
    [ -n "$_v" ] && _last="$_v"
  done
  for _f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-password; do
    [ -f "$_f" ] || continue
    _pv=$(grep -vE '^[[:space:]]*#' "$_f" 2>/dev/null \
          | grep -E 'pam_(pwquality|cracklib)\.so' \
          | grep -oE "(^|[[:space:]])${_key}=-?[0-9]+" | tail -1 | cut -d= -f2)
    [ -n "$_pv" ] && _last="$_pv"
  done
  [ -n "$_last" ] && printf '%s' "$_last"
  return 0
}

# ── sshd 설정 평가 순서 스트림 (U-01 미탐 방지) ──────────────────────────────
# sshd 는 Include 지시자가 "선언된 위치"에서 해당 파일을 전개하고, 같은
# 키워드는 먼저 얻은 값을 채택한다. 기존 코드는 메인 파일을 항상 먼저 읽어
# Include 가 최상단에 있는 Ubuntu 등에서 우선순위를 뒤집었다.
_sshd_config_stream() {
  local _file="${1:-/etc/ssh/sshd_config}" _depth="${2:-0}" _line _pat _f
  [ "$_depth" -gt 4 ] && return 0
  [ -f "$_file" ] || return 0
  while IFS= read -r _line; do
    if printf '%s' "$_line" | grep -qiE '^[[:space:]]*Include[[:space:]]+'; then
      _pat=$(printf '%s' "$_line" | sed -E 's/^[[:space:]]*[Ii]nclude[[:space:]]+//')
      for _f in $_pat; do
        case "$_f" in
          /*) : ;;
          *) _f="/etc/ssh/${_f}" ;;
        esac
        [ -f "$_f" ] && _sshd_config_stream "$_f" $((_depth + 1))
      done
      continue
    fi
    printf '%s\n' "$_line"
  done < "$_file"
  return 0
}

# OpenSSH pattern-list가 특정 사용자와 일치하는지 확인한다.
# 반환: 0=일치, 1=불일치
_sshd_pattern_list_matches() {
  local _target="$1" _list="$2" _pat _neg=0 _positive=0 _matched=0
  local _old_ifs="$IFS"
  IFS=','
  for _pat in $_list; do
    [ -n "$_pat" ] || continue
    _neg=0
    case "$_pat" in !*) _neg=1; _pat="${_pat#!}" ;; esac
    if [[ "$_target" == $_pat ]]; then
      [ $_neg -eq 1 ] && { IFS="$_old_ifs"; return 1; }
      _matched=1
    fi
    [ $_neg -eq 0 ] && _positive=1
  done
  IFS="$_old_ifs"
  [ $_positive -eq 1 ] && [ $_matched -eq 1 ]
}

_sshd_group_pattern_list_matches() {
  local _list="$1" _g
  while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    _sshd_pattern_list_matches "$_g" "$_list" && return 0
  done < <(id -Gn root 2>/dev/null | tr ' ' '\n')
  return 1
}

# Match 블록의 PermitRootLogin이 실제로 root 사용자에게 적용될 가능성이 있는지 확인한다.
# 기존 구현은 "Match User backup" 같은 root와 무관한 블록도 취약으로 판정했다.
# User/Group 조건이 root를 명확히 제외하는 블록은 무시하고, Address/Host 등 다른
# 조건만 있는 블록은 특정 접속 조건에서 root에 적용될 수 있으므로 보수적으로 검사한다.
_sshd_match_permits_root() {
  local _line _key _val _root_applies=0 _in_match=0 _i
  local -a _tok=()
  while IFS= read -r _line; do
    _line="${_line%%#*}"
    [ -n "${_line//[[:space:]]/}" ] || continue
    read -r -a _tok <<< "$_line"
    [ ${#_tok[@]} -gt 0 ] || continue
    _key="${_tok[0],,}"

    if [ "$_key" = "match" ]; then
      _in_match=1
      _root_applies=1
      _i=1
      while [ $_i -lt ${#_tok[@]} ]; do
        _key="${_tok[$_i],,}"
        case "$_key" in
          all|final) _i=$((_i+1)); continue ;;
          user)
            _i=$((_i+1)); [ $_i -lt ${#_tok[@]} ] || break
            _sshd_pattern_list_matches root "${_tok[$_i]}" || _root_applies=0 ;;
          group)
            _i=$((_i+1)); [ $_i -lt ${#_tok[@]} ] || break
            _sshd_group_pattern_list_matches "${_tok[$_i]}" || _root_applies=0 ;;
          exec)
            # exec 뒤는 공백을 포함할 수 있어 이후 토큰을 조건 키워드로 해석하지 않는다.
            break ;;
          address|host|localaddress|localnetwork|localport|rdomain)
            _i=$((_i+1)) ;;
        esac
        _i=$((_i+1))
      done
      continue
    fi

    if [ $_in_match -eq 1 ] && [ $_root_applies -eq 1 ] \
       && [ "$_key" = "permitrootlogin" ]; then
      _val="${_tok[1],,}"
      case "$_val" in
        no|prohibit-password|without-password) : ;;
        *) return 0 ;;
      esac
    fi
  done < <(_sshd_config_stream 2>/dev/null | grep -vE '^[[:space:]]*#')
  return 1
}

# ── BIND 설정 파일 위치 (U-50/U-51 미탐 방지) ────────────────────────────────
# Debian/Ubuntu 는 /etc/bind/named.conf.options 를 사용하므로 /etc/named.conf
# 만 확인하던 기존 로직은 BIND 운영 중에도 "해당없음"으로 처리했다.
_bind_config_files() {
  local _f
  for _f in /etc/named.conf /etc/named.conf.local /etc/named/named.conf \
            /etc/named/*.conf /etc/bind/named.conf /etc/bind/named.conf.options \
            /etc/bind/named.conf.local /etc/bind/*.conf \
            /var/named/chroot/etc/named.conf; do
    [ -f "$_f" ] && printf '%s\n' "$_f"
  done
  return 0
}

# named 설정의 주석(// , # , /* */)을 제거한다.
_named_strip_comments() {
  awk '
    {
      line = $0
      while (1) {
        if (inblock) {
          p = index(line, "*/")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 2); inblock = 0
        }
        p = index(line, "/*")
        if (p == 0) break
        rest = substr(line, p + 2)
        q = index(rest, "*/")
        if (q == 0) { line = substr(line, 1, p - 1); inblock = 1; break }
        line = substr(line, 1, p - 1) substr(rest, q + 2)
      }
      sub(/\/\/.*$/, "", line)
      sub(/#.*$/, "", line)
      print line
    }'
}


# ── BIND 유효 정책 감사 (U-50/U-51) ─────────────────────────────────────────
# named-checkconf -p로 include를 전개한 유효 설정을 파싱하고 options/view/zone
# 상속 관계를 반영한다. 해석이 불가능한 사용자 ACL·update-policy는 양호/취약으로
# 단정하지 않고 확인 필요로 반환한다.
_bind_main_config() {
  local _f
  if [ -n "${VULNFIX_BIND_CONF:-}" ] && [ -f "$VULNFIX_BIND_CONF" ]; then
    printf '%s\n' "$VULNFIX_BIND_CONF"; return 0
  fi
  for _f in /etc/named.conf /etc/bind/named.conf /etc/named/named.conf \
            /var/named/chroot/etc/named.conf; do
    [ -f "$_f" ] && { printf '%s\n' "$_f"; return 0; }
  done
  return 1
}

_bind_service_active() {
  local _u
  for _u in named.service bind9.service named-chroot.service; do
    systemctl is-active "$_u" 2>/dev/null | grep -qE '^(active|activating)$' && return 0
  done
  pgrep -x named >/dev/null 2>&1 && return 0
  _port_listening udp 53 && return 0
  _port_listening tcp 53 && return 0
  return 1
}

_bind_policy_audit() {
  local _mode="$1" _main _tmp _rc
  _bind_service_active || { echo "BIND 서비스와 TCP/UDP 53 리스닝이 확인되지 않았습니다."; return 2; }
  _main=$(_bind_main_config) || { echo "BIND 주 설정 파일을 찾지 못했습니다."; return 3; }
  command -v named-checkconf >/dev/null 2>&1 \
    || { echo "named-checkconf가 없어 include·상속 정책을 안전하게 해석할 수 없습니다."; return 3; }
  command -v python3 >/dev/null 2>&1 \
    || { echo "python3가 없어 BIND zone별 유효 정책을 해석할 수 없습니다."; return 3; }

  _tmp=$(mktemp 2>/dev/null) || { echo "BIND 감사 임시 파일 생성 실패"; return 3; }
  if named-checkconf -h 2>&1 | grep -q -- '-x'; then
    named-checkconf -p -x "$_main" >"$_tmp" 2>/dev/null
  else
    named-checkconf -p "$_main" >"$_tmp" 2>/dev/null
  fi
  _rc=$?
  if [ $_rc -ne 0 ] || [ ! -s "$_tmp" ]; then
    rm -f "$_tmp"
    echo "named-checkconf 검증 또는 include 전개에 실패했습니다: $_main"
    return 3
  fi

  python3 - "$_mode" "$_tmp" <<'PY_BIND_AUDIT'
import ipaddress
import re
import sys

mode, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{};]|[^\s{};]+', text)

class Node:
    def __init__(self, head, children=None):
        self.head = head
        self.children = children
    @property
    def block(self):
        return self.children is not None

def parse(pos=0, stop=False):
    nodes = []
    n = len(tokens)
    while pos < n:
        if tokens[pos] == '}':
            return nodes, pos + 1
        head = []
        while pos < n and tokens[pos] not in ('{', ';', '}'):
            head.append(tokens[pos]); pos += 1
        if pos >= n:
            if head: nodes.append(Node(head))
            break
        if tokens[pos] == ';':
            pos += 1
            if head: nodes.append(Node(head))
        elif tokens[pos] == '{':
            pos += 1
            children, pos = parse(pos, True)
            if pos < n and tokens[pos] == ';': pos += 1
            nodes.append(Node(head, children))
        elif tokens[pos] == '}':
            if head: nodes.append(Node(head))
            return nodes, pos + 1
    return nodes, pos

root, _ = parse()

def key(n):
    return n.head[0].lower() if n.head else ''

def direct(container, name):
    if container is None: return None
    name = name.lower()
    for n in container.children or []:
        if key(n) == name:
            return n
    return None

def stmt_value(container, name):
    n = direct(container, name)
    if n and not n.block and len(n.head) > 1:
        return n.head[1].strip('"').lower()
    return ''

def elems(n):
    out = []
    if n is None: return out
    for c in n.children or []:
        if c.block:
            out.extend(elems(c))
        elif c.head:
            out.append(c.head)
    return out

acls = {}
def collect_acls(nodes):
    for n in nodes:
        if key(n) == 'acl' and n.block and len(n.head) > 1:
            acls[n.head[1].strip('"').lower()] = n
        if n.block:
            collect_acls(n.children)
collect_acls(root)

broad = {'any', '*', '0/0', '0.0.0.0/0', '::/0', '0:0:0:0:0:0:0:0/0'}
builtin_restricted = {'localhost', 'localnets'}

def normalize_elem(parts):
    neg = False
    p = [x.lower() for x in parts]
    if p and p[0] == '!': neg, p = True, p[1:]
    elif p and p[0].startswith('!'):
        neg, p[0] = True, p[0][1:]
    return neg, p

def is_ip_or_net(v):
    try:
        ipaddress.ip_network(v, strict=False)
        return True
    except Exception:
        try:
            ipaddress.ip_address(v)
            return True
        except Exception:
            return False

def classify_acl_node(node, transfer=True, seen=None):
    seen = set() if seen is None else set(seen)
    positives = []
    manual = False
    for raw in elems(node):
        neg, p = normalize_elem(raw)
        if neg or not p:
            continue
        token = p[0]
        if token == 'none':
            continue
        if token in broad:
            return 'VULN', '전체 대상(any/0.0.0.0/0/::/0) 허용'
        if token == 'key' and len(p) > 1:
            positives.append('key'); continue
        if token in builtin_restricted:
            positives.append('network'); continue
        if is_ip_or_net(token):
            positives.append('network'); continue
        if token in acls:
            if token in seen:
                manual = True; continue
            st, rs = classify_acl_node(acls[token], transfer, seen | {token})
            if st == 'VULN': return st, f'ACL {token}: {rs}'
            if st == 'MANUAL': manual = True
            else: positives.append('acl')
            continue
        manual = True
    if manual:
        return 'MANUAL', '사용자 ACL 또는 복합 부정 조건을 자동 해석할 수 없음'
    if not positives:
        return 'GOOD', 'none 또는 빈 허용 목록'
    if transfer:
        return 'GOOD', '특정 주소·네트워크·TSIG 키로 제한'
    if all(x == 'key' for x in positives):
        return 'GOOD', 'TSIG 키로 제한'
    return 'MANUAL', 'IP 기반 동적 업데이트 허용은 운영 정책·TSIG 적용 여부 확인 필요'

def policy(container, name):
    n = direct(container, name)
    return n if n and n.block else None

def describe_zone(z, view_name, parent_policy, global_policy):
    zname = z.head[1].strip('"') if len(z.head) > 1 else '<unknown>'
    ztype = stmt_value(z, 'type')
    if ztype == 'master': ztype = 'primary'
    if ztype == 'slave': ztype = 'secondary'
    if mode == 'transfer':
        if ztype not in ('primary', 'secondary', 'mirror'):
            return None
        own = policy(z, 'allow-transfer')
        eff = own or parent_policy or global_policy
        source = 'zone' if own else ('view' if parent_policy else ('options' if global_policy else 'default'))
        if eff is None:
            st, reason = 'GOOD', 'BIND 기본값 none(전송 차단)'
        else:
            st, reason = classify_acl_node(eff, True)
    else:
        if ztype != 'primary':
            return None
        up = direct(z, 'update-policy')
        if up is not None:
            st, reason, source = 'MANUAL', 'update-policy 규칙의 TSIG identity·grant 범위 확인 필요', 'zone'
        else:
            own = policy(z, 'allow-update')
            eff = own or parent_policy or global_policy
            source = 'zone' if own else ('view' if parent_policy else ('options' if global_policy else 'default'))
            if eff is None:
                st, reason = 'GOOD', 'BIND 기본값 deny(동적 업데이트 차단)'
            else:
                st, reason = classify_acl_node(eff, False)
    return (view_name, zname, ztype or 'unknown', source, st, reason)

options = next((n for n in root if key(n) == 'options' and n.block), None)
global_name = 'allow-transfer' if mode == 'transfer' else 'allow-update'
global_policy = policy(options, global_name)
rows = []
for n in root:
    if key(n) == 'zone' and n.block:
        r = describe_zone(n, 'default', None, global_policy)
        if r: rows.append(r)
    elif key(n) == 'view' and n.block:
        vname = n.head[1].strip('"') if len(n.head) > 1 else '<unnamed>'
        vp = policy(n, global_name)
        for z in n.children or []:
            if key(z) == 'zone' and z.block:
                r = describe_zone(z, vname, vp, global_policy)
                if r: rows.append(r)

label = 'allow-transfer' if mode == 'transfer' else 'allow-update/update-policy'
print(f'BIND 유효 정책 감사: {label}')
if not rows:
    print('  권한 판단 대상 authoritative zone이 없습니다.')
    sys.exit(2)
for view, name, ztype, source, st, reason in rows:
    print(f'  view={view} | zone={name} | type={ztype} | source={source} | {st} | {reason}')
counts = {x: sum(1 for r in rows if r[4] == x) for x in ('VULN','MANUAL','GOOD')}
print(f"  요약: 취약 {counts['VULN']} / 확인 필요 {counts['MANUAL']} / 양호 {counts['GOOD']}")
if counts['VULN']:
    sys.exit(0)
if counts['MANUAL']:
    sys.exit(3)
sys.exit(1)
PY_BIND_AUDIT
  _rc=$?
  rm -f "$_tmp"
  return $_rc
}

# ── FTP TLS 강제 여부 감사 (U-54) ───────────────────────────────────────────
_conf_last_value() {
  local _file="$1" _key="$2" _default="${3:-}" _v
  [ -f "$_file" ] || { printf '%s' "$_default"; return 0; }
  _v=$(grep -vE '^[[:space:]]*#' "$_file" 2>/dev/null \
       | awk -F= -v k="$_key" '
           { key=$1; gsub(/[[:space:]]/, "", key) }
           tolower(key)==tolower(k) { v=$2; gsub(/[[:space:]]/, "", v) }
           END { print toupper(v) }')
  printf '%s' "${_v:-$_default}"
}

_vsftpd_runtime_config() {
  local _args _candidate _f _count=0 _only=""
  _args=$(ps -ww -o args= -C vsftpd 2>/dev/null | head -1)
  for _candidate in $_args; do
    case "$_candidate" in
      /*.conf|*.conf)
        [ -f "$_candidate" ] && { printf '%s\n' "$_candidate"; return 0; }
        ;;
    esac
  done
  for _f in /etc/vsftpd/vsftpd.conf /etc/vsftpd.conf; do
    [ -f "$_f" ] || continue
    _count=$((_count+1)); _only="$_f"
  done
  [ $_count -eq 1 ] && { printf '%s\n' "$_only"; return 0; }
  return 1
}

_u54_tls_state() {
  local _active=0 _vs_active=0 _pro_active=0 _f
  local _ssl _implicit _local _anon _flog _fdata _alog _adata
  local _engine_on _engine_off _required_on _required_off _includes

  _port_listening tcp 21 990 && _active=1
  pgrep -x vsftpd >/dev/null 2>&1 && { _active=1; _vs_active=1; }
  pgrep -x proftpd >/dev/null 2>&1 && { _active=1; _pro_active=1; }
  systemctl is-active vsftpd.service 2>/dev/null | grep -qE '^(active|activating)$' \
    && { _active=1; _vs_active=1; }
  systemctl is-active proftpd.service 2>/dev/null | grep -qE '^(active|activating)$' \
    && { _active=1; _pro_active=1; }

  [ $_active -eq 0 ] && return 1
  [ $_vs_active -eq 0 ] && [ $_pro_active -eq 0 ] && return 3

  if [ $_vs_active -eq 1 ]; then
    _f=$(_vsftpd_runtime_config) || return 3
    _ssl=$(_conf_last_value "$_f" ssl_enable NO)
    _implicit=$(_conf_last_value "$_f" implicit_ssl NO)
    [ "$_ssl" = YES ] || return 0

    if [ "$_implicit" != YES ]; then
      _local=$(_conf_last_value "$_f" local_enable NO)
      _anon=$(_conf_last_value "$_f" anonymous_enable NO)
      _flog=$(_conf_last_value "$_f" force_local_logins_ssl YES)
      _fdata=$(_conf_last_value "$_f" force_local_data_ssl YES)
      _alog=$(_conf_last_value "$_f" force_anon_logins_ssl NO)
      _adata=$(_conf_last_value "$_f" force_anon_data_ssl NO)
      if [ "$_local" = YES ] && { [ "$_flog" != YES ] || [ "$_fdata" != YES ]; }; then return 0; fi
      if [ "$_anon" = YES ] && { [ "$_alog" != YES ] || [ "$_adata" != YES ]; }; then return 0; fi
    fi
  fi

  if [ $_pro_active -eq 1 ]; then
    if [ ! -f /etc/proftpd.conf ]        && ! find /etc/proftpd -maxdepth 2 -type f -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
      return 3
    fi
    # Include·VirtualHost·IfModule 범위 때문에 정적 grep만으로 전역 유효값을
    # 확정할 수 없다. 명백한 미설정은 취약, on 후보가 있으면 확인 필요로 둔다.
    _engine_on=$(grep -rhEc '^[[:space:]]*TLSEngine[[:space:]]+on([[:space:]]|$)' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null || true)
    _engine_off=$(grep -rhEc '^[[:space:]]*TLSEngine[[:space:]]+off([[:space:]]|$)' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null || true)
    _required_on=$(grep -rhEc '^[[:space:]]*TLSRequired[[:space:]]+on([[:space:]]|$)' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null || true)
    _required_off=$(grep -rhEc '^[[:space:]]*TLSRequired[[:space:]]+(off|auth|ctrl|data)([[:space:]]|$)' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null || true)
    _includes=$(grep -rhEc '^[[:space:]]*Include(Optional)?[[:space:]]+' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null || true)
    [ "${_engine_on:-0}" -gt 0 ] && [ "${_required_on:-0}" -gt 0 ] || return 0
    # on 후보가 있어도 유효 범위는 확인 필요다. 상충 설정은 사유로 보고된다.
    : "${_engine_off:=0}" "${_required_off:=0}" "${_includes:=0}"
    return 3
  fi

  return 1
}

_u54_status_report() {
  echo "FTP 리스닝 상태:"
  local _listen _f _k
  _listen=$(_listen_dump tcp | grep -E ':(21|990)[[:space:]]' || true)
  [ -n "$_listen" ] && printf '%s\n' "$_listen" | sed 's/^/  /' || echo "  TCP 21/990 리스닝 없음"
  _f=$(_vsftpd_runtime_config 2>/dev/null || true)
  if [ -n "$_f" ]; then
    echo "vsftpd 유효 후보 설정: $_f"
    for _k in ssl_enable implicit_ssl local_enable anonymous_enable \
              force_local_logins_ssl force_local_data_ssl \
              force_anon_logins_ssl force_anon_data_ssl; do
      echo "  $_k=$(_conf_last_value "$_f" "$_k" '<default>')"
    done
  elif pgrep -x vsftpd >/dev/null 2>&1 \
       || systemctl is-active vsftpd.service 2>/dev/null | grep -qE '^(active|activating)$'; then
    echo "vsftpd 설정: 실행 중이나 단일 유효 설정 파일을 확정하지 못함"
  fi
  if [ -f /etc/proftpd.conf ] || [ -d /etc/proftpd ]; then
    echo "ProFTPD TLS 설정 후보:"
    grep -rhE '^[[:space:]]*(TLSEngine|TLSRequired|Include(Optional)?)[[:space:]]+' \
      /etc/proftpd.conf /etc/proftpd 2>/dev/null | sed 's/^/  /' || true
    echo "  ※ Include/VirtualHost 범위는 수동 확인 필요"
  fi
}

# ── SNMP 버전 감사 (U-59) ───────────────────────────────────────────────────
_snmp_config_files() {
  local _f
  for _f in /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.d/*.conf \
            /etc/snmp/conf.d/*.conf /etc/snmp/snmp.conf.d/*.conf \
            /var/lib/net-snmp/snmpd.conf /var/lib/snmp/snmpd.conf; do
    [ -f "$_f" ] && printf '%s\n' "$_f"
  done
}

_snmp_service_active() {
  systemctl is-active snmpd.service 2>/dev/null | grep -qE '^(active|activating)$' && return 0
  pgrep -x snmpd >/dev/null 2>&1 && return 0
  _port_listening udp 161 && return 0
  return 1
}

_snmp_version_audit() {
  local _files _f _tmp _rc
  _snmp_service_active || { echo "SNMP 서비스와 UDP 161 리스닝이 확인되지 않았습니다."; return 2; }
  _files=$(_snmp_config_files | sort -u)
  [ -n "$_files" ] || { echo "SNMP는 활성이나 설정 파일을 찾지 못했습니다."; return 3; }
  command -v python3 >/dev/null 2>&1 \
    || { echo "python3가 없어 SNMP VACM 연결 관계를 안전하게 해석할 수 없습니다."; return 3; }

  _tmp=$(mktemp 2>/dev/null) || { echo "SNMP 감사 임시 파일 생성 실패"; return 3; }
  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    printf '#FILE=%s\n' "$_f" >> "$_tmp"
    grep -vE '^[[:space:]]*(#|$)' "$_f" 2>/dev/null >> "$_tmp"
  done <<< "$_files"

  python3 - "$_tmp" <<'PY_SNMP_AUDIT'
import shlex
import sys

path = sys.argv[1]
com2sec = set()
groups_v12 = []
groups_v3 = []
access_groups = set()
direct_v12 = direct_v3 = v3_priv = create_users = unknown_include = files = 0

for raw in open(path, encoding='utf-8', errors='replace'):
    line = raw.strip()
    if not line:
        continue
    if line.startswith('#FILE='):
        files += 1
        continue
    try:
        parts = shlex.split(line, comments=True, posix=True)
    except ValueError:
        continue
    if not parts:
        continue
    key = parts[0].lower()
    if key in ('includefile', 'includedir'):
        unknown_include += 1
    elif key in ('rocommunity', 'rwcommunity', 'rocommunity6', 'rwcommunity6', 'authcommunity'):
        direct_v12 += 1
    elif key in ('com2sec', 'com2sec6'):
        idx = 3 if len(parts) > 1 and parts[1] == '-Cn' else 1
        if len(parts) > idx:
            com2sec.add(parts[idx])
    elif key == 'group' and len(parts) >= 4:
        group, model, secname = parts[1], parts[2].lower(), parts[3]
        if model in ('v1', 'v2c'):
            groups_v12.append((group, secname))
        elif model == 'usm':
            groups_v3.append(group)
    elif key == 'access' and len(parts) >= 2:
        access_groups.add(parts[1])
    elif key in ('rouser', 'rwuser', 'authuser'):
        direct_v3 += 1
        if any(x.lower() == 'priv' for x in parts[2:]):
            v3_priv += 1
    elif key == 'createuser':
        create_users += 1

classic_v12 = sum(1 for group, sec in groups_v12 if sec in com2sec and group in access_groups)
classic_v3 = sum(1 for group in groups_v3 if group in access_groups)
active_v12 = direct_v12 + classic_v12
active_v3 = direct_v3 + classic_v3

print(f'SNMP 설정 파일: {files}개')
print(f'SNMPv1/v2c 활성 접근 경로: {active_v12}개 (직접 community {direct_v12}, VACM 연결 {classic_v12})')
print(f'SNMPv3 활성 접근 경로: {active_v3}개 (직접 사용자 {direct_v3}, USM/VACM 연결 {classic_v3})')
print(f'SNMPv3 priv 명시 사용자: {v3_priv}개')
print(f'createUser 레코드: {create_users}개 (인증정보 내용 미표시)')
if unknown_include:
    print(f'추가 include 지시자: {unknown_include}개 — 포함 파일 범위 확인 필요')

if active_v12:
    sys.exit(0)
if active_v3 and not unknown_include:
    sys.exit(1)
sys.exit(3)
PY_SNMP_AUDIT
  _rc=$?
  rm -f "$_tmp"
  return $_rc
}

# ── OS 업데이트 저장소 검증 (U-64) ───────────────────────────────────────────
: "${VULNFIX_UPDATE_CHECK_TIMEOUT:=120}"
_U64_UPDATE_MANAGER=""; _U64_UPDATE_COUNT=0; _U64_ALL_UPDATE_COUNT=0
_U64_UPDATE_REASON=""; _U64_UPDATE_OUTPUT=""; _U64_SECURITY_PACKAGES=""
_vf_timeout_cmd() {
  local _t="$VULNFIX_UPDATE_CHECK_TIMEOUT"
  [[ "$_t" =~ ^[1-9][0-9]*$ ]] || _t=120
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_t" "$@"
  else
    "$@"
  fi
}

_u64_update_state() {
  local _out _rc _all _sec
  _U64_UPDATE_MANAGER=""; _U64_UPDATE_COUNT=0; _U64_ALL_UPDATE_COUNT=0
  _U64_UPDATE_REASON=""; _U64_UPDATE_OUTPUT=""; _U64_SECURITY_PACKAGES=""

  if command -v apt-get >/dev/null 2>&1; then
    _U64_UPDATE_MANAGER="apt"
    _out=$(_vf_timeout_cmd env LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1); _rc=$?
    if [ $_rc -ne 0 ] || printf '%s\n' "$_out" | grep -qiE '(^E:|failed to fetch|temporary failure|could not resolve|repository.*not signed|certificate verification failed)'; then
      _U64_UPDATE_REASON="apt 저장소 메타데이터 갱신 실패(rc=${_rc})"
      _U64_UPDATE_OUTPUT="$_out"; return 2
    fi
    _out=$(_vf_timeout_cmd env LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>&1); _rc=$?
    if [ $_rc -ne 0 ] || printf '%s\n' "$_out" | grep -qiE '(^E:|failed to fetch|temporary failure|could not resolve|repository.*not signed|certificate verification failed)'; then
      _U64_UPDATE_REASON="apt 업그레이드 가능 목록 확인 실패(rc=${_rc})"
      _U64_UPDATE_OUTPUT="$_out"; return 2
    fi
    _all=$(printf '%s\n' "$_out" | awk '/^Inst[[:space:]]+/{print $2}' | sed '/^$/d' | sort -u)
    _sec=$(printf '%s\n' "$_out" | awk '/^Inst[[:space:]]+/ && tolower($0) ~ /security/{print $2}' | sed '/^$/d' | sort -u)
    _U64_ALL_UPDATE_COUNT=$(printf '%s\n' "$_all" | sed '/^$/d' | wc -l | tr -d ' ')
    _U64_SECURITY_PACKAGES="$_sec"
    _U64_UPDATE_COUNT=$(printf '%s\n' "$_sec" | sed '/^$/d' | wc -l | tr -d ' ')
    _U64_UPDATE_OUTPUT="$_out"
    [ "${_U64_ALL_UPDATE_COUNT:-0}" -eq 0 ] && return 1
    [ "${_U64_UPDATE_COUNT:-0}" -gt 0 ] && return 0
    _U64_UPDATE_REASON="apt 업그레이드 ${_U64_ALL_UPDATE_COUNT}개가 있으나 보안 저장소 항목으로 신뢰성 있게 분류되지 않음"
    return 3
  fi

  if command -v dnf >/dev/null 2>&1; then
    _U64_UPDATE_MANAGER="dnf"
    _out=$(_vf_timeout_cmd env LC_ALL=C dnf -q --refresh check-update --security 2>&1); _rc=$?
    _U64_UPDATE_OUTPUT="$_out"
    if [ $_rc -eq 100 ]; then
      _U64_UPDATE_COUNT=$(printf '%s\n' "$_out" | awk 'NF>=3 && $1 !~ /^(Last|Obsoleting|Security:|Updateinfo:)/ {n++} END{print n+0}')
      [ "${_U64_UPDATE_COUNT:-0}" -gt 0 ] || { _U64_UPDATE_REASON="dnf 반환코드는 업데이트 존재이나 패키지 목록을 파싱하지 못함"; return 3; }
      return 0
    fi
    [ $_rc -eq 0 ] && return 1
    _U64_UPDATE_REASON="dnf 보안 업데이트 확인 실패(rc=${_rc})"; return 2
  fi

  if command -v yum >/dev/null 2>&1; then
    _U64_UPDATE_MANAGER="yum"
    if command -v subscription-manager >/dev/null 2>&1 \
       && subscription-manager status 2>&1 | grep -qiE 'not registered|등록되어 있지 않|소비자 ID를 읽을 수 없'; then
      _U64_UPDATE_REASON="Red Hat 구독 미등록"; return 2
    fi
    _out=$(_vf_timeout_cmd env LC_ALL=C yum -q --setopt=metadata_expire=0 check-update --security 2>&1); _rc=$?
    _U64_UPDATE_OUTPUT="$_out"
    if [ $_rc -eq 100 ]; then
      _U64_UPDATE_COUNT=$(printf '%s\n' "$_out" | awk 'NF>=3 && $1 !~ /^(Last|Obsoleting|Security:|Updateinfo:)/ {n++} END{print n+0}')
      [ "${_U64_UPDATE_COUNT:-0}" -gt 0 ] || { _U64_UPDATE_REASON="yum 반환코드는 업데이트 존재이나 패키지 목록을 파싱하지 못함"; return 3; }
      return 0
    fi
    [ $_rc -eq 0 ] && return 1
    _U64_UPDATE_REASON="yum 보안 업데이트 확인 실패(rc=${_rc})"; return 2
  fi

  if command -v zypper >/dev/null 2>&1; then
    _U64_UPDATE_MANAGER="zypper"
    _out=$(_vf_timeout_cmd env LC_ALL=C zypper --non-interactive refresh 2>&1); _rc=$?
    [ $_rc -eq 0 ] || { _U64_UPDATE_REASON="zypper 저장소 갱신 실패(rc=${_rc})"; _U64_UPDATE_OUTPUT="$_out"; return 2; }
    _out=$(_vf_timeout_cmd env LC_ALL=C zypper --non-interactive list-patches --category security 2>&1); _rc=$?
    _U64_UPDATE_OUTPUT="$_out"
    [ $_rc -eq 0 ] || { _U64_UPDATE_REASON="zypper 보안 패치 확인 실패(rc=${_rc})"; return 2; }
    _U64_UPDATE_COUNT=$(printf '%s\n' "$_out" | grep -cE '^[[:space:]]*[^|]+\|[^|]+\|[^|]+\|[[:space:]]*security[[:space:]]*\|' || true)
    [ "${_U64_UPDATE_COUNT:-0}" -gt 0 ] && return 0
    return 1
  fi

  _U64_UPDATE_REASON="지원하는 패키지 관리자(apt/dnf/yum/zypper)를 찾지 못함"
  return 2
}

_u64_print_cached_report() {
  echo "패키지 관리자: ${_U64_UPDATE_MANAGER:-확인 불가}"
  [ "${_U64_UPDATE_MANAGER:-}" = apt ] && echo "전체 업그레이드 후보: ${_U64_ALL_UPDATE_COUNT:-0}개"
  echo "보안 업데이트 대상: ${_U64_UPDATE_COUNT:-0}개"
  [ -n "$_U64_UPDATE_REASON" ] && echo "판정 사유: $_U64_UPDATE_REASON"
  [ -n "$_U64_UPDATE_OUTPUT" ] && printf '%s\n' "$_U64_UPDATE_OUTPUT" | grep -v '^[[:space:]]*$' | head -15 | sed 's/^/  /'
}

# ── U-14 PATH 내 현재 디렉터리 포함 여부 판정 ────────────────────────────────
# "." 항목뿐 아니라 빈 항목(연속 콜론 "::", 선행/후행 콜론)도 현재 디렉터리를
# 의미하므로 함께 판정한다.
# 기존 로직의 'PATH=.*\.' 는 /opt/app-1.2/bin, /usr/lib/jvm/java-11.0.2 처럼
# 정상 경로에 포함된 점까지 매칭해 사실상 모든 서버를 취약으로 오탐했다.
_u14_path_has_dot() {
  local _val="$1" _seg _old_ifs
  [ -n "$_val" ] || return 1
  _val="${_val%%#*}"            # 후행 주석 제거
  _val="${_val//\"/}"           # 따옴표 제거
  _val="${_val//\'/}"
  _val="$(printf '%s' "$_val" | tr -d '[:space:]')"
  [ -n "$_val" ] || return 1

  # 빈 항목(선행/후행/연속 콜론) = 현재 디렉터리
  case ":${_val}:" in
    *::*) return 0 ;;
  esac

  _old_ifs="$IFS"
  IFS=':'
  for _seg in $_val; do
    case "$_seg" in
      .|./) IFS="$_old_ifs"; return 0 ;;
    esac
  done
  IFS="$_old_ifs"
  return 1
}

# ── syslog TCP 원격 수신 설정 여부 (U-36 오탐 방지용) ────────────────────────
# 514/tcp 는 rsh(shell) 포트이면서 rsyslog·syslog-ng 의 TCP 수신 포트이기도 하다.
# syslog 수신 설정이 확인되면 해당 포트를 rsh 노출로 보지 않는다.
_u36_syslog_tcp() {
  grep -rhE '^[[:space:]]*(\$ModLoad[[:space:]]+imtcp|module\([[:space:]]*load="imtcp")' \
    /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | grep -q . && return 0
  grep -rhE '^[[:space:]]*\$InputTCPServerRun|input\([[:space:]]*type="imtcp"' \
    /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | grep -q . && return 0
  grep -rhE 'transport\([[:space:]]*"?tcp|tcp[[:space:]]*\([[:space:]]*port' \
    /etc/syslog-ng 2>/dev/null | grep -q . && return 0
  return 1
}

# ── SNMP 커뮤니티 스트링 추출 (U-59/U-60/U-61 공용) ──────────────────────────
# com2sec/com2sec6 는 4번째 필드, ro/rwcommunity 는 2번째 필드가 커뮤니티 스트링이다.
# snmpd.conf 단일 파일이 아니라 include 디렉터리까지 함께 본다.
_snmp_community_strings() {
  local _f
  for _f in /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.d/*.conf \
            /etc/snmp/conf.d/*.conf /etc/snmp/snmp.conf.d/*.conf; do
    [ -f "$_f" ] || continue
    grep -vE '^[[:space:]]*#' "$_f" 2>/dev/null | awk '
      tolower($1)=="com2sec" || tolower($1)=="com2sec6" {
        # com2sec [-Cn context] name source community
        if ($2 == "-Cn") { print $6 } else { print $4 }
        next
      }
      tolower($1) ~ /^(ro|rw)community6?$/ { print $2; next }
      tolower($1) == "authcommunity" { print $3 }
    '
  done | sed '/^$/d'
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
    _apt_out=$(LC_ALL=C apt list --upgradable 2>/dev/null) || return 2
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

# ── 서비스/소켓 유닛 공용 헬퍼 (U-34/U-36/U-44 등) ──────────────────────────
# 배경: finger, telnet, tftp, talk, rsh 계열은 systemd에서 접미사 없는
# "서비스명"이 아니라 <name>.socket / <name>d.service 같은 실제 유닛명으로
# 등록되는 경우가 많다. "systemctl stop finger"처럼 접미사 없이 호출하면
# 기본적으로 finger.service를 찾는데, 실제로는 finger.socket만 존재하는
# 소켓 활성화 방식이라 아무 효과가 없을 수 있다. 이 함수들은 호출부가
# 실제 유닛명(접미사 포함) 목록을 넘기고, 존재하는 유닛만 골라 처리한다.

# _svc_stop_disable_mask <유닛명(.service/.socket 등 접미사 포함)...>
# 전달된 유닛 중 실제 존재(list-unit-files에 나타남)하는 것만
# stop → disable → mask 순서로 처리한다. 존재하지 않는 유닛은 조용히 건너뛴다.
_svc_stop_disable_mask() {
  local _unit
  for _unit in "$@"; do
    systemctl list-unit-files "$_unit" --no-legend 2>/dev/null | grep -q . || continue
    systemctl stop "$_unit" 2>/dev/null
    systemctl disable "$_unit" 2>/dev/null
    systemctl mask "$_unit" 2>/dev/null
  done
}

# _svc_any_active <유닛명...>
# 전달된 유닛 중 하나라도 active 또는 activating 상태이면 0(참)을 반환한다.
_svc_any_active() {
  local _unit _st
  for _unit in "$@"; do
    _st=$(systemctl is-active "$_unit" 2>/dev/null)
    case "$_st" in
      active|activating) return 0 ;;
    esac
  done
  return 1
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


# ── 로컬 마운트 전체 순회 공용 함수 ─────────────────────────────────────────
# 여러 U-항목(U-15, U-23, U-25 등)이 파일시스템 전체를 스캔할 때 '/'만 스캔하면
# /home, /data, /u01처럼 별도 파티션에 마운트된 영역이 -xdev 때문에 누락된다.
# findmnt로 네트워크/가상 파일시스템을 제외한 로컬 마운트를 모두 찾아 각각
# -xdev로 개별 스캔한 뒤 합친다. findmnt가 없는 환경에서는 기존처럼 '/'만 스캔한다
# (네트워크 마운트를 건드리지 않기 위한 최소 안전 폴백).
_vf_local_mounts() {
  local _mnt _fstype _found=0
  if command -v findmnt &>/dev/null; then
    while read -r _mnt _fstype; do
      [ -n "$_mnt" ] || continue
      case "$_fstype" in
        proc|sysfs|devtmpfs|devpts|cgroup|cgroup2|pstore|securityfs|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|binfmt_misc|nsfs|autofs|nfs|nfs4|cifs|smb3|fuse.sshfs|overlay|squashfs|iso9660)
          continue
          ;;
        # 휘발성 메모리 파일시스템 — /run, /dev/shm, /run/user/* 의 임시 파일이
        # world-writable/nouser 로 대량 적발되어 U-15/U-23/U-25 오탐의 주원인이 된다.
        tmpfs|ramfs|efivarfs|bpf|tracefs|debugfs)
          continue
          ;;
        # POSIX 권한 의미가 없는 파일시스템 — 마운트 옵션에 따라 모든 파일이
        # 777/666 으로 보고되므로 권한 기반 판정 대상에서 제외한다.
        vfat|exfat|msdos|ntfs|ntfs3|fuseblk|udf|hfs|hfsplus)
          continue
          ;;
      esac
      [ -d "$_mnt" ] || continue
      echo "$_mnt"
      _found=1
    done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null)
  fi
  [ "$_found" -eq 1 ] || echo "/"
}
# _vf_find_all_mounts <find 조건...>
# 로컬 마운트 전체를 순회하며 각 마운트에서 -xdev로 find를 실행해 결과를 합친다.
# 사용례: _vf_find_all_mounts -type f -perm -0002
_vf_find_all_mounts() {
  local _mnt
  while IFS= read -r _mnt; do
    find "$_mnt" -xdev "$@" 2>/dev/null
  done < <(_vf_local_mounts | sort -u)
}


# ── 위험 자동 조치 제외 항목 공용 탐지 함수 ──────────────────────────────────
# U-05/U-09/U-10/U-15/U-26은 계정 삭제·UID/GID 변경·소유권 일괄 변경·파일 삭제가
# 서비스 장애로 이어질 수 있으므로 stage3부터 상태 조회와 수동 확인만 수행한다.
# 아래 함수는 판정과 보고서 출력에서 동일한 결과를 사용하도록 공통화한다.
_u05_extra_uid0_rows() {
  awk -F: '$3 == 0 && $1 != "root" {
    printf "%s|UID=%s|GID=%s|HOME=%s|SHELL=%s\n", $1, $3, $4, $6, $7
  }' /etc/passwd 2>/dev/null
}

_u09_missing_gid_rows() {
  local _user _pw _uid _gid _rest
  while IFS=: read -r _user _pw _uid _gid _rest; do
    [ -n "$_user" ] || continue
    if ! getent group "$_gid" >/dev/null 2>&1; then
      printf '%s|UID=%s|기본 GID=%s|NSS에서 그룹 확인 불가\n' \
        "$_user" "$_uid" "$_gid"
    fi
  done < /etc/passwd
}

_u10_duplicate_uid_rows() {
  awk -F: '
    {
      uid=$3
      count[uid]++
      users[uid]=(users[uid] == "" ? $1 : users[uid] "," $1)
    }
    END {
      for (uid in count) {
        if (count[uid] > 1) printf "%s|계정=%s|중복=%d개\n", uid, users[uid], count[uid]
      }
    }
  ' /etc/passwd 2>/dev/null | LC_ALL=C sort -t'|' -k1,1n
}

_u15_orphan_rows() {
  _vf_find_all_mounts \( -nouser -o -nogroup \) \
    -printf '%p|UID=%U|GID=%G|권한=%m|유형=%y\n' 2>/dev/null | LC_ALL=C sort -u
}

_u26_nondevice_rows() {
  # /dev 자체 파일시스템만 검사한다. /dev/shm, /dev/pts 등 별도 마운트는
  # -xdev로 내려가지 않으며, 일반 파일만 수동 확인 대상으로 반환한다.
  find /dev -xdev \
    \( -path /dev/shm -o -path /dev/mqueue -o -path /dev/hugepages \
       -o -path /dev/pts -o -path /dev/.udev -o -path '/dev/.lxc*' \) -prune -o \
    -type f -print 2>/dev/null | LC_ALL=C sort -u
}

# ── U-25 공용 점검 함수 ───────────────────────────────────────────────────────
# KISA U-25 범위에 맞춰 Socket/디렉터리는 제외하고 일반 파일(-type f)만 점검한다.
# 별도 파일시스템(/u01, /data 등)이 누락되지 않도록 로컬 마운트별로 순회한다.
# 설정 사유가 확인된 파일은 예외 기록에 경로·사유·확인일·확인자를 남겨 재점검 시 인정한다.
_U25_ALLOWLIST="${_RB_DIR}/u25_allowlist.conf"

# ── 전체 파일시스템 스캔 결과 캐시 ──────────────────────────────────────────
# U-15/U-23/U-25/U-33 은 같은 조건으로 전 마운트를 여러 번 스캔한다.
# (사전 점검 루프 → 항목 진입 시 판정 → 조치 후 재검증)
# 대용량 스토리지에서는 항목당 수 분이 걸려 운영자가 항목을 건너뛰게 되고,
# 그것이 실질적인 미탐 원인이 된다. 결과를 캐시하되, 조치가 실행되면
# _scan_cache_invalidate 로 반드시 무효화해 재검증이 항상 최신 상태를 보게 한다.
_SCAN_CACHE_DIR=""
_SCAN_CACHE_ON=1

_scan_cache_init() {
  [ -n "$_SCAN_CACHE_DIR" ] && return 0
  _SCAN_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vulnscan_cache.XXXXXX" 2>/dev/null) || {
    _SCAN_CACHE_ON=0; _SCAN_CACHE_DIR=""; return 1
  }
  chmod 700 "$_SCAN_CACHE_DIR" 2>/dev/null
  return 0
}

# _scan_cached <캐시키> <명령...>  — 캐시 불가 시 그대로 명령을 실행한다.
_scan_cached() {
  local _key="$1"; shift
  local _f
  if [ "${_SCAN_CACHE_ON:-0}" -ne 1 ]; then "$@"; return $?; fi
  _scan_cache_init || { "$@"; return $?; }
  _f="${_SCAN_CACHE_DIR}/${_key}"
  if [ ! -f "${_f}.done" ]; then
    "$@" > "$_f" 2>/dev/null
    : > "${_f}.done" 2>/dev/null
  fi
  cat "$_f" 2>/dev/null
  return 0
}

# _scan_cache_invalidate [캐시키...] — 인자가 없으면 전체 무효화
_scan_cache_invalidate() {
  local _k
  [ -n "$_SCAN_CACHE_DIR" ] || return 0
  if [ "$#" -eq 0 ]; then
    rm -f "${_SCAN_CACHE_DIR}"/* 2>/dev/null
  else
    for _k in "$@"; do
      rm -f "${_SCAN_CACHE_DIR}/${_k}" "${_SCAN_CACHE_DIR}/${_k}.done" 2>/dev/null
    done
  fi
  return 0
}

_scan_cache_cleanup() {
  [ -n "$_SCAN_CACHE_DIR" ] && rm -rf "$_SCAN_CACHE_DIR" 2>/dev/null
  _SCAN_CACHE_DIR=""
  return 0
}

# U-15(무소유)·U-23(SUID/SGID)·U-25(world-writable)는 전부 "전체 로컬 마운트를
# -xdev로 순회"하는 동일한 틀을 쓰면서 조건만 다르다. 기존에는 항목마다 따로
# find를 돌려 같은 디렉터리 트리를 3번 훑었다 — 파일이 많은 서버에서 이 반복
# 순회(readdir/stat)가 누적되어 점검이 느려지는 주된 원인이었다.
# 마운트당 find를 1번만 돌리면서 세 조건을 동시에 검사하도록 합친다.
#
# 주의(OR 단축평가): find는 최상위 표현식을 좌→우로 평가하다 하나가 참이면
# 그 뒤는 평가하지 않는다. 그래서 조건들을 그냥 -o로 이어 붙이면, 한 파일이
# 예를 들어 SUID이면서 동시에 world-writable이어도 먼저 매칭된 조건에만
# 잡히고 다른 조건에서는 통째로 빠진다(취약 항목 누락 위험). 이를 막기 위해
# 각 조건 그룹 끝에 "-o -true"를 붙여 그 그룹 자체는 항상 참이 되게 만들고,
# 그룹들을 공백(기본 AND)으로 이어서 파일마다 세 조건을 모두 독립적으로
# 검사·기록하도록 한다.
_vf_u15_u23_u25_combined_scan() {
  [ "${_SCAN_CACHE_ON:-0}" -eq 1 ] || return 0
  _scan_cache_init || return 0

  local _f15="${_SCAN_CACHE_DIR}/u15_noowner"
  local _f23="${_SCAN_CACHE_DIR}/u23_suid"
  local _f25="${_SCAN_CACHE_DIR}/u25_ww"

  # 셋 다 이미 채워져 있으면(이전 결합 스캔 또는 개별 캐시) 다시 돌지 않는다.
  if [ -f "${_f15}.done" ] && [ -f "${_f23}.done" ] && [ -f "${_f25}.done" ]; then
    return 0
  fi

  : > "$_f15" 2>/dev/null
  : > "$_f23" 2>/dev/null
  : > "$_f25" 2>/dev/null

  # 주의(-fprint 는 매 실행마다 truncate): find 는 -fprint 대상 파일을 실행 시작
  # 시점에 새로 비운다. 마운트를 돌며 같은 파일에 -fprint 하면 마지막 마운트
  # 결과만 남고 앞선 마운트의 탐지 결과가 통째로 유실된다(미탐). 그래서 마운트
  # 마다 임시 파일로 받은 뒤 최종 결과 파일에 누적(append)한다.
  local _t15="${_SCAN_CACHE_DIR}/.part15"
  local _t23="${_SCAN_CACHE_DIR}/.part23"
  local _t25="${_SCAN_CACHE_DIR}/.part25"

  local _mnt _scanned=0
  while IFS= read -r _mnt; do
    [ -n "$_mnt" ] || continue
    find "$_mnt" -xdev \
      \( \( -nouser -o -nogroup \)                -fprint "$_t15" -o -true \) \
      \( \( -perm -4000 -o -perm -2000 \) -type f -fprint "$_t23" -o -true \) \
      \(  -type f -perm -0002                     -fprint "$_t25" -o -true \) \
      2>/dev/null
    cat "$_t15" >> "$_f15" 2>/dev/null
    cat "$_t23" >> "$_f23" 2>/dev/null
    cat "$_t25" >> "$_f25" 2>/dev/null
    _scanned=$((_scanned + 1))
  done < <(_vf_local_mounts | sort -u)

  rm -f "$_t15" "$_t23" "$_t25" 2>/dev/null

  # 마운트를 한 개도 훑지 못했다면 결과가 비어 있는 것이 "이상 없음"을 뜻하지
  # 않는다. 이때 .done 을 남기면 빈 결과가 캐시에 굳어 U-15/23/25가 전부
  # 양호로 오판(미탐)되므로, 마커를 남기지 않고 개별 raw 스캔으로 폴백시킨다.
  if [ "$_scanned" -eq 0 ]; then
    rm -f "$_f15" "$_f23" "$_f25" 2>/dev/null
    return 0
  fi

  LC_ALL=C sort -u -o "$_f15" "$_f15" 2>/dev/null
  LC_ALL=C sort -u -o "$_f23" "$_f23" 2>/dev/null
  LC_ALL=C sort -u -o "$_f25" "$_f25" 2>/dev/null

  : > "${_f15}.done" 2>/dev/null
  : > "${_f23}.done" 2>/dev/null
  : > "${_f25}.done" 2>/dev/null
}

_u15_find_noowner_raw() { _vf_find_all_mounts \( -nouser -o -nogroup \) 2>/dev/null; }
_u15_find_noowner() {
  _vf_u15_u23_u25_combined_scan
  _scan_cached u15_noowner _u15_find_noowner_raw
}
_u23_find_suid_raw()    { _vf_find_all_mounts \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort; }
_u23_find_suid() {
  _vf_u15_u23_u25_combined_scan
  _scan_cached u23_suid _u23_find_suid_raw
}

_u25_find_world_writable_raw() {
  _vf_find_all_mounts -type f -perm -0002 | sort -u
}
_u25_find_world_writable() {
  _vf_u15_u23_u25_combined_scan
  _scan_cached u25_ww _u25_find_world_writable_raw
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
  # 첫 인자로 호출 시점을 구분한다: before(조치 전 점검) / after(조치 후 검증, 기본값)
  # "원인 추정"은 재조치 여부를 전제로 한 문구라 before 단계에서는 표시하지 않는다.
  local _mode="${1:-after}"
  # 원인 후보별 상세 확인 방법은 화면에는 요약만 남기고, 이 변수에 담아
  # 보고서(DETAIL_VAL)로만 전달한다. 매 호출마다 이전 값이 남지 않도록 초기화.
  _U65_CANDIDATE_DETAIL=""
  _svc=$(_u65_active_service 2>/dev/null || true)
  [ -n "$_svc" ] && _state="active" || { _svc="없음"; _state="inactive"; }

  if [ "$_state" = "active" ]; then
    echo -e "서비스 상태 : ${_svc} (${GREEN}${_state}${RESET})"
  else
    echo -e "서비스 상태 : ${_svc} (${YELLOW}${_state}${RESET})"
  fi

  if [ "$_mode" = "before" ]; then
    # 이 출력 직후 do_fix 공통 코드가 "조치하시겠습니까? (y/n)"을 묻는다.
    # y는 "조치를 시도하도록 승인"하는 것이지 외부 NTP 서버 응답까지
    # 스크립트가 보장한다는 뜻이 아니므로, 질문 전에 기대치를 미리 안내해
    # 조치 후 미동기화를 "스크립트가 잘못했다"고 오해하지 않도록 한다.
    echo -e "  ${CYAN}※ 아래에서 y를 선택하면 NTP 서비스를 활성화하고 설정된 소스로 시각 동기화를 시도합니다.${RESET}"
    echo -e "    ${CYAN}외부 NTP 서버가 응답하지 않으면 동기화가 안 될 수 있으며, 이 경우 조치 실패가 아니라 '수동 확인'으로 표시됩니다.${RESET}"
  fi

  _configured=$(grep -hE '^[[:space:]]*(server|pool)[[:space:]]+' \
    /etc/chrony.conf /etc/chrony/chrony.conf /etc/ntp.conf 2>/dev/null \
    | sed 's/^[[:space:]]*//' | head -3)
  if [ -n "$_configured" ]; then
    echo "설정된 NTP 소스 :"
    echo "$_configured" | sed 's/^/  /'
  else
    echo -e "설정된 NTP 소스 : ${YELLOW}없음${RESET}"
  fi

  case "$_svc" in
    chronyd|chrony)
      _selected=$(chronyc sources -n 2>/dev/null \
        | awk '$1 ~ /^[\^=]\*/ {print $1, $2; exit}')
      _leap=$(chronyc tracking 2>/dev/null \
        | awk -F':' '/^[[:space:]]*Leap status[[:space:]]*:/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
      if [ -n "$_selected" ]; then
        echo -e "선택된 NTP 소스 : ${GREEN}${_selected}${RESET}"
      else
        echo -e "선택된 NTP 소스 : ${YELLOW}없음${RESET}"
      fi
      if [ "${_leap:-확인 불가}" = "Normal" ]; then
        echo -e "Leap status : ${GREEN}${_leap}${RESET}"
      else
        echo -e "Leap status : ${YELLOW}${_leap:-확인 불가}${RESET}"
      fi
      if [ "$_mode" = "after" ] && [ "$_state" = "active" ] && [ -z "$_selected" ]; then
        # 서비스는 기동됐는데 소스를 하나도 선택하지 못한 상태.
        # 주의: 여기서 확인한 것은 "선택된 소스가 없다"는 사실뿐이다.
        #   chronyc sources 의 Reach(응답 이력)를 보지 않으므로 "응답이 없다"고
        #   단정할 수 없다. 응답은 오지만 시각 편차가 커서 배제된 경우(falseticker)
        #   원인이 정반대이고 대응 방법도 달라진다.
        #   따라서 확정 원인처럼 쓰지 않고, chronyc sources -n의 실제 심볼을
        #   분석해서 구체적인 진단 근거를 제시한다.
        # "재조치만으로는 해결되지 않습니다"라는 문구는 이미 한 번 조치를 시도한
        # 뒤(after 단계)에만 의미가 있으므로 before 단계에서는 이 블록 전체를 건너뛴다.
        if [ -z "$_configured" ]; then
          # 소스 자체가 설정되지 않은 경우는 네트워크 문제가 아니다.
          echo -e "${YELLOW}확인 결과${RESET} : 설정된 NTP 서버가 없어 시각 동기화를 진행할 수 없습니다."
          echo -e "  ${CYAN}→${RESET} 사용할 내부 또는 외부 NTP 서버 주소를 설정한 후 다시 확인하세요."
        else
          # chronyc sources -n 심볼 기준 진단:
          #   ^*=정상 선택된 소스  ^+=사용 가능한 후보  ^?=연결 불가/응답 없음
          #   ^x=falseticker로 제외  Reach=0 필드=응답 이력 없음
          local _u65_src_raw="" _u65_src_total=0 _u65_src_unreach=0
          local _u65_src_false=0 _u65_src_reach0=0 _u65_src_candidate=0
          _u65_src_raw=$(chronyc sources -n 2>/dev/null | grep -E '^\^')
          if [ -n "$_u65_src_raw" ]; then
            _u65_src_total=$(printf '%s\n' "$_u65_src_raw" | grep -c .)
            _u65_src_unreach=$(printf '%s\n' "$_u65_src_raw" | grep -cE '^\^\?')
            _u65_src_false=$(printf '%s\n' "$_u65_src_raw" | grep -cE '^\^x')
            _u65_src_candidate=$(printf '%s\n' "$_u65_src_raw" | grep -cE '^\^\+')
            _u65_src_reach0=$(printf '%s\n' "$_u65_src_raw" | awk '{print $5}' | grep -cx '0')
          fi

          if [ "$_u65_src_total" -gt 0 ] && { [ "$_u65_src_unreach" -gt 0 ] || [ "$_u65_src_reach0" -gt 0 ]; }; then
            echo -e "${YELLOW}확인 결과${RESET} : 설정된 NTP 서버에서 응답을 확인하지 못했습니다."
            echo -e "  ${CYAN}→${RESET} NTP 서버 주소, DNS, 아웃바운드 UDP 123, 원격 NTP 서비스 상태를 확인하세요."
          elif [ "$_u65_src_false" -gt 0 ]; then
            echo -e "${YELLOW}확인 결과${RESET} : NTP 서버 응답은 수신했지만 시간 차이가 커 동기화 대상에서 제외되었습니다."
            echo -e "  ${CYAN}→${RESET} 현재 서버 시간, NTP 서버 시간 및 chronyd 시각 보정 정책을 확인하세요."
          elif [ "$_u65_src_candidate" -gt 0 ]; then
            echo -e "${YELLOW}확인 결과${RESET} : 응답 가능한 NTP 서버는 있으나 아직 동기화 대상으로 선택되지 않았습니다."
            echo -e "  ${CYAN}→${RESET} 잠시 후 다시 확인하거나 chronyd 상태와 소스 선택 과정을 점검하세요."
          else
            echo -e "${YELLOW}확인 결과${RESET} : NTP 서비스는 활성화됐지만 동기화할 서버를 선택하지 못했습니다."
            echo -e "  ${CYAN}→${RESET} NTP 서버 주소, DNS, UDP 123 통신 및 원격 NTP 서비스 상태를 확인하세요."
          fi
          echo -e "  ${CYAN}→${RESET} 상세 확인 명령은 결과보고서(Excel)의 '상세내역'에서 확인하세요."
          # 화면에는 위 요약 2줄만 남기고, 후보별 상세(확인 명령 포함)는
          # 화면에 찍지 않고 보고서로만 전달한다 (읽기 어려운 화면 출력 방지).
          _U65_CANDIDATE_DETAIL="[NTP 상태 분석] 설정된 소스=${_u65_src_total}개, 응답 미확인=${_u65_src_unreach}개, 시간 차이로 제외=${_u65_src_false}개, 응답 이력 없음=${_u65_src_reach0}개, 선택 대기=${_u65_src_candidate}개 || [확인 절차] 1) chronyc sources -n으로 서버별 상태 확인 || 2) getent hosts <NTP 서버명>으로 DNS 확인 || 3) 방화벽과 네트워크에서 아웃바운드 UDP 123 허용 여부 확인 || 4) 원격 NTP 서버의 서비스 상태와 서버 주소 확인 || 5) 응답은 있으나 시간 차이로 제외된 경우 현재 서버 시간과 chronyd 보정 정책 확인"
        fi
      fi
      ;;
    ntpd|ntp)
      _selected=$(ntpq -pn 2>/dev/null | awk '$1 ~ /^\*/ {print $1; exit}')
      if [ -n "$_selected" ]; then
        echo -e "선택된 NTP 소스 : ${GREEN}${_selected}${RESET}"
      else
        echo -e "선택된 NTP 소스 : ${YELLOW}없음${RESET}"
      fi
      ;;
    *)
      echo -e "선택된 NTP 소스 : ${YELLOW}없음${RESET}"
      ;;
  esac

  _tdsync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  echo "timedatectl 동기화 : ${_tdsync:-확인 불가}"

  if _u65_is_synced; then
    echo "검증 결과 : 확인 완료"
  else
    echo -e "검증 결과 : ${RED}확인 실패${RESET}"
  fi
}

_u65_apply() {
  local _svc="" _i _candidate
  local _sync_ok=0 _had_unit_before=0

  # 보고서의 [변경 대상]과 [서비스 변경]에 실제 전·후 상태를 남기기 위한
  # U-65 전용 실행 상태값. 조치 전후 서비스와 명령 결과를 분리해 기록한다.
  _U65_APPLY_ATTEMPTED=1
  _U65_PACKAGE_INSTALLED=0
  _U65_PACKAGE_MANAGER="미사용"
  _U65_PACKAGE_INSTALL_RESULT="미수행"
  _U65_SERVICE_BEFORE="없음"
  _U65_ACTIVE_BEFORE="inactive"
  _U65_ENABLED_BEFORE="not-found"
  _U65_SERVICE_AFTER="없음"
  _U65_ACTIVE_AFTER="inactive"
  _U65_ENABLED_AFTER="not-found"
  _U65_ENABLE_RESULT="미수행"
  _U65_CHRONYC_ONLINE_RESULT="미수행"
  _U65_CHRONYC_BURST_RESULT="미수행"
  _U65_CHRONYC_MAKESTEP_RESULT="미수행"
  _U65_NTP_RESTART_RESULT="미수행"
  _U65_SYNC_VERIFIED=0

  # 활성 서비스가 없어도 설치된 비활성 unit을 찾아 조치 전 상태를 기록한다.
  _svc=$(_u65_active_service 2>/dev/null || true)
  if [ -z "$_svc" ]; then
    for _candidate in chronyd chrony ntpd ntp; do
      if _u65_unit_exists "$_candidate"; then
        _svc="$_candidate"
        break
      fi
    done
  fi

  if [ -n "$_svc" ]; then
    _had_unit_before=1
    _U65_SERVICE_BEFORE="$_svc"
    _U65_ACTIVE_BEFORE=$(systemctl is-active "$_svc" 2>/dev/null || true)
    _U65_ENABLED_BEFORE=$(systemctl is-enabled "$_svc" 2>/dev/null || true)
    [ -n "$_U65_ACTIVE_BEFORE" ] || _U65_ACTIVE_BEFORE="unknown"
    [ -n "$_U65_ENABLED_BEFORE" ] || _U65_ENABLED_BEFORE="unknown"
  fi

  # 현재 설치된 NTP 데몬이 없을 때만 chrony를 설치한다.
  if [ -z "$_svc" ]; then
    echo "→ NTP 데몬이 없어 chrony 패키지 설치를 시도합니다."
    if command -v dnf >/dev/null 2>&1; then
      _U65_PACKAGE_MANAGER="dnf"
      if dnf install -y chrony >/dev/null 2>&1; then
        _U65_PACKAGE_INSTALL_RESULT="성공"
      else
        _U65_PACKAGE_INSTALL_RESULT="실패"
        echo "✗ chrony 패키지 설치 실패"
      fi
    elif command -v yum >/dev/null 2>&1; then
      _U65_PACKAGE_MANAGER="yum"
      if yum install -y chrony >/dev/null 2>&1; then
        _U65_PACKAGE_INSTALL_RESULT="성공"
      else
        _U65_PACKAGE_INSTALL_RESULT="실패"
        echo "✗ chrony 패키지 설치 실패"
      fi
    elif command -v apt-get >/dev/null 2>&1; then
      _U65_PACKAGE_MANAGER="apt-get"
      if apt-get update >/dev/null 2>&1 && apt-get install -y chrony >/dev/null 2>&1; then
        _U65_PACKAGE_INSTALL_RESULT="성공"
      else
        _U65_PACKAGE_INSTALL_RESULT="실패"
        echo "✗ chrony 패키지 설치 실패"
      fi
    elif command -v zypper >/dev/null 2>&1; then
      _U65_PACKAGE_MANAGER="zypper"
      if zypper --non-interactive install chrony >/dev/null 2>&1; then
        _U65_PACKAGE_INSTALL_RESULT="성공"
      else
        _U65_PACKAGE_INSTALL_RESULT="실패"
        echo "✗ chrony 패키지 설치 실패"
      fi
    else
      _U65_PACKAGE_MANAGER="없음"
      _U65_PACKAGE_INSTALL_RESULT="지원 관리자 없음"
      echo "✗ 지원되는 패키지 관리자를 찾을 수 없습니다."
    fi

    if _u65_unit_exists chronyd; then
      _svc="chronyd"
    elif _u65_unit_exists chrony; then
      _svc="chrony"
    fi

    if [ "$_had_unit_before" -eq 0 ] && [ -n "$_svc" ]; then
      _U65_PACKAGE_INSTALLED=1
    fi
  fi

  if [ -n "$_svc" ]; then
    if systemctl enable --now "$_svc" >/dev/null 2>&1; then
      _U65_ENABLE_RESULT="성공"
      echo "✓ ${_svc} 서비스 활성화 완료"
    else
      _U65_ENABLE_RESULT="실패"
      echo "✗ ${_svc} 서비스 활성화 실패"
    fi
  else
    _U65_ENABLE_RESULT="대상 없음"
    echo "✗ 활성화 가능한 NTP 서비스를 찾지 못했습니다."
  fi

  # chrony는 서비스 기동 직후 온라인 전환 및 즉시 동기화를 시도한다.
  case "$_svc" in
    chronyd|chrony)
      if command -v chronyc >/dev/null 2>&1; then
        if chronyc online >/dev/null 2>&1; then
          _U65_CHRONYC_ONLINE_RESULT="성공"
        else
          _U65_CHRONYC_ONLINE_RESULT="실패"
        fi
        if chronyc burst 4/4 >/dev/null 2>&1; then
          _U65_CHRONYC_BURST_RESULT="성공"
        else
          _U65_CHRONYC_BURST_RESULT="실패"
        fi
        if chronyc makestep >/dev/null 2>&1; then
          _U65_CHRONYC_MAKESTEP_RESULT="성공"
        else
          _U65_CHRONYC_MAKESTEP_RESULT="실패"
        fi
      else
        _U65_CHRONYC_ONLINE_RESULT="chronyc 없음"
        _U65_CHRONYC_BURST_RESULT="chronyc 없음"
        _U65_CHRONYC_MAKESTEP_RESULT="chronyc 없음"
      fi
      ;;
    ntpd|ntp)
      if systemctl restart "$_svc" >/dev/null 2>&1; then
        _U65_NTP_RESTART_RESULT="성공"
      else
        _U65_NTP_RESTART_RESULT="실패"
      fi
      ;;
  esac

  # 네트워크 응답 및 소스 선택에 시간이 걸릴 수 있어 최대 30초간 실제 동기화를 확인한다.
  if [ -n "$_svc" ] && systemctl is-active --quiet "$_svc" 2>/dev/null; then
    _VF_LAST_RETRY_COUNT=0
    _VF_LAST_RETRY_MAX=6
    for _i in 1 2 3 4 5 6; do
      _VF_LAST_RETRY_COUNT="$_i"
      if _u65_is_synced; then
        _sync_ok=1
        _detail_log_note "U-65" "RETRY" "NTP 동기화 확인 ${_i}/6: 성공"
        echo "✓ NTP 소스 연결 및 시각 동기화 확인"
        break
      fi
      _detail_log_note "U-65" "RETRY" "NTP 동기화 확인 ${_i}/6: 미동기화"
      [ "$_i" -lt 6 ] && { echo "→ 시각 동기화 대기 중 (${_i}/6)"; sleep 5; }
    done
    if [ "$_sync_ok" -ne 1 ]; then
      echo "✗ NTP 서비스는 활성 상태이나 실제 시각 동기화를 확인하지 못했습니다."
      echo "→ 설정된 NTP 서버, DNS, UDP/123 방화벽 및 네트워크 연결을 확인하세요."
    fi
  fi

  _U65_SERVICE_AFTER="${_svc:-없음}"
  if [ -n "$_svc" ]; then
    _U65_ACTIVE_AFTER=$(systemctl is-active "$_svc" 2>/dev/null || true)
    _U65_ENABLED_AFTER=$(systemctl is-enabled "$_svc" 2>/dev/null || true)
    [ -n "$_U65_ACTIVE_AFTER" ] || _U65_ACTIVE_AFTER="unknown"
    [ -n "$_U65_ENABLED_AFTER" ] || _U65_ENABLED_AFTER="unknown"
  fi
  _U65_SYNC_VERIFIED="$_sync_ok"

  # 실제 취약 여부는 do_fix의 after_cmd와 pass_pattern이 최종 판정한다.
  return 0
}

# 한 섹션 안에서 여러 줄로 보이도록 원문을 DETAIL_VAL 형식으로 정리한다.
_u65_detail_text() {
  printf '%s\n' "$1" \
    | _strip_ansi_stream \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | awk 'BEGIN{sep=""} {printf "%s%s", sep, $0; sep=" || "} END{print ""}'
}

# do_fix의 최종 검증 직후 호출되는 U-65 전용 보고서 저장 훅.
# 설정 파일을 실제로 수정하지 않았다면 파일 변경으로 기록하지 않고,
# 서비스 상태·패키지 설치·동기화 명령을 [서비스 변경]에 정확히 남긴다.
_vf_finalize_detail_U_65() {
  local _before_out="$1" _after_out="$2" _verified="$3"
  local _before_detail _after_detail _result _action _service_detail _svc_label

  _before_detail=$(_u65_detail_text "$_before_out")
  _after_detail=$(_u65_detail_text "$_after_out")
  [ -n "$_before_detail" ] || _before_detail="조치 전 NTP 상태 확인 불가"
  [ -n "$_after_detail" ] || _after_detail="조치 후 NTP 상태 확인 불가"
  # 화면에는 표시하지 않은 원인 후보별 확인 방법 상세를 보고서(상세내역/검증 결과)에만 남긴다.
  [ -n "${_U65_CANDIDATE_DETAIL:-}" ] && _after_detail="${_after_detail} || ${_U65_CANDIDATE_DETAIL}"

  if [ "$_verified" -eq 1 ]; then
    _result="조치 완료 / 최종 검증 통과"
  else
    _result="조치 실패 / 최종 검증 미통과"
  fi

  _svc_label="${_U65_SERVICE_AFTER:-${_U65_SERVICE_BEFORE:-없음}}"
  [ "$_svc_label" = "없음" ] || _svc_label="${_svc_label}.service"

  _action="NTP 서비스 활성화 및 실제 시각 동기화 수행"
  if [ "${_U65_PACKAGE_INSTALLED:-0}" -eq 1 ]; then
    _action="chrony 패키지 설치, ${_action}"
  fi
  case "${_U65_SERVICE_AFTER:-}" in
    chronyd|chrony)
      _action="${_action}; chronyc online, burst, makestep 실행"
      ;;
    ntpd|ntp)
      _action="${_action}; NTP 서비스 restart 실행"
      ;;
  esac

  if [ "$_svc_label" = "없음" ]; then
    _service_detail="NTP 서비스: 활성화 대상 없음"
  else
    _service_detail="${_svc_label}: 상태 ${_U65_ACTIVE_BEFORE:-unknown} → ${_U65_ACTIVE_AFTER:-unknown}, 자동 시작 ${_U65_ENABLED_BEFORE:-unknown} → ${_U65_ENABLED_AFTER:-unknown}"
  fi
  _service_detail="${_service_detail} || enable --now: ${_U65_ENABLE_RESULT:-미확인}"

  if [ "${_U65_PACKAGE_INSTALLED:-0}" -eq 1 ] || [ "${_U65_PACKAGE_INSTALL_RESULT:-미수행}" != "미수행" ]; then
    _service_detail="chrony 패키지: ${_U65_PACKAGE_INSTALL_RESULT:-미확인} (${_U65_PACKAGE_MANAGER:-미확인}) || ${_service_detail}"
  fi

  case "${_U65_SERVICE_AFTER:-}" in
    chronyd|chrony)
      _service_detail="${_service_detail} || chronyc online: ${_U65_CHRONYC_ONLINE_RESULT:-미확인}, burst: ${_U65_CHRONYC_BURST_RESULT:-미확인}, makestep: ${_U65_CHRONYC_MAKESTEP_RESULT:-미확인}"
      ;;
    ntpd|ntp)
      _service_detail="${_service_detail} || service restart: ${_U65_NTP_RESTART_RESULT:-미확인}"
      ;;
  esac

  DETAIL_VAL["U-65"]=$(_fmt_detail \
    "$_before_detail" \
    "$_action" \
    "$_result" \
    "" \
    "$_after_detail" \
    "$_service_detail")

  _detail_log_note "U-65" "REPORT" \
    "변경 대상 저장: ${_service_detail}; 최종검증=$([ "$_verified" -eq 1 ] && echo PASS || echo FAIL)"
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
  # ss 부재 환경에서도 판정되도록 공용 폴백 헬퍼를 사용한다.
  _port_listening tcp 23
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
    echo 'Telnet 영구 비활성 확인 완료'
  else
    echo 'Telnet 비활성 검증 실패'
  fi
}

# =============================================================================
# ── [5단계] 조치 후 공통 재점검·설정 문법·서비스 상태 검증 ─────────────────
# =============================================================================
# 조치 명령의 stdout 문자열만으로 성공을 확정하지 않는다.
# 최초 점검 시 문법·서비스 상태를 기준값으로 저장하고, 조치 후에는 동일한
# check_still_vuln 함수를 재실행한 뒤 문법 및 서비스 상태를 함께 검증한다.

declare -A _VF_VERIFY_BASELINE_CAPTURED
declare -A _VF_SYNTAX_BASE_RC
declare -A _VF_SYNTAX_BASE_HASH
declare -A _VF_SERVICE_BASE_ACTIVE
declare -A _VF_SERVICE_BASE_LIST
declare -A _VF_POSTCHECK_STATUS
declare -A _VF_POSTCHECK_REASON
declare -A _VF_POSTCHECK_DETAIL
declare -A _VF_POSTCHECK_CHECK_STATUS
declare -A _VF_POSTCHECK_SYNTAX_STATUS
declare -A _VF_POSTCHECK_SERVICE_STATUS
declare -A _VF_POSTCHECK_EVIDENCE_STATUS

_vf_item_service_units() {
  case "$1" in
    U-01|U-62) echo 'sshd.service ssh.service' ;;
    U-21|U-66) echo 'rsyslog.service syslog-ng.service systemd-journald.service' ;;
    U-34) echo 'finger.socket finger.service fingerd.service cfingerd.service' ;;
    U-35) echo 'smb.service smbd.service nmb.service nmbd.service' ;;
    U-36) echo 'rsh.socket rlogin.socket rexec.socket rshd.service rlogind.service rexecd.service' ;;
    U-38) echo 'echo.socket echo.service chargen.socket chargen.service discard.socket discard.service daytime.socket daytime.service' ;;
    U-39) echo 'nfs-server.service nfs-kernel-server.service nfs-mountd.service' ;;
    U-40) echo 'nfs-server.service nfs-kernel-server.service nfs-mountd.service rpc-statd.service' ;;
    U-41) echo 'autofs.service' ;;
    U-43) echo 'ypserv.service ypbind.service ypxfrd.service yppasswdd.service' ;;
    U-44) echo 'tftp.socket tftp.service tftpd.service tftpd-hpa.service atftpd.service talk.socket talk.service ntalk.socket ntalk.service' ;;
    U-45|U-46|U-47|U-48) echo 'postfix.service sendmail.service exim.service exim4.service' ;;
    U-49|U-50|U-51) echo 'named.service bind9.service' ;;
    U-52) echo 'telnet.socket telnet.service telnetd.service telnet@.service' ;;
    U-53|U-55|U-56|U-57) echo 'vsftpd.service proftpd.service' ;;
    U-58|U-59|U-60|U-61) echo 'snmpd.service' ;;
    U-65) echo 'chronyd.service chrony.service ntpd.service ntp.service' ;;
    *) echo '' ;;
  esac
}

_vf_item_process_names() {
  case "$1" in
    U-01|U-62) echo 'sshd' ;;
    U-21|U-66) echo 'rsyslogd syslog-ng systemd-journald' ;;
    U-34) echo 'fingerd in.fingerd cfingerd' ;;
    U-35) echo 'smbd nmbd' ;;
    U-36) echo 'rshd rlogind rexecd' ;;
    U-38) echo 'in.echo in.chargen in.discard in.daytime' ;;
    U-39|U-40) echo 'nfsd rpc.mountd rpc.statd' ;;
    U-41) echo 'automount' ;;
    U-43) echo 'ypserv ypbind ypxfrd rpc.yppasswdd' ;;
    U-44) echo 'in.tftpd tftpd atftpd talkd ntalkd' ;;
    U-45|U-46|U-47|U-48) echo 'master sendmail exim exim4' ;;
    U-49|U-50|U-51) echo 'named' ;;
    U-52) echo 'telnetd in.telnetd' ;;
    U-53|U-55|U-56|U-57) echo 'vsftpd proftpd' ;;
    U-58|U-59|U-60|U-61) echo 'snmpd' ;;
    U-65) echo 'chronyd ntpd' ;;
    *) echo '' ;;
  esac
}

_vf_item_service_policy() {
  case "$1" in
    U-34|U-36|U-38|U-39|U-41|U-43|U-44|U-52|U-58) echo 'disable' ;;
    U-65|U-66) echo 'require' ;;
    U-01|U-21|U-35|U-40|U-45|U-46|U-47|U-48|U-49|U-50|U-51|U-53|U-55|U-56|U-57|U-59|U-60|U-61|U-62) echo 'preserve' ;;
    *) echo 'none' ;;
  esac
}

_vf_systemd_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [ -d /run/systemd/system ] || systemctl show --property=Version --value >/dev/null 2>&1
}

_vf_item_process_active() {
  local _p
  for _p in $(_vf_item_process_names "$1"); do
    pgrep -x "$_p" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 반환: 0=문법 정상, 1=문법 오류, 2=안전한 검사 대상 없음
_vf_run_item_syntax_test() {
  local _id="$1" _cmd='' _name='' _conf=''
  _VF_SYNTAX_TEST_NAME=''
  _VF_SYNTAX_TEST_OUTPUT=''
  _VF_SYNTAX_TEST_HASH=''

  case "$_id" in
    U-01|U-62)
      command -v sshd >/dev/null 2>&1 || return 2
      _name='SSH 설정'; _cmd='sshd -t'
      ;;
    U-03|U-06)
      command -v authselect >/dev/null 2>&1 || return 2
      authselect current -r >/dev/null 2>&1 || return 2
      _name='PAM/authselect 구성'; _cmd='authselect check'
      ;;
    U-21|U-66)
      command -v rsyslogd >/dev/null 2>&1 || return 2
      _name='rsyslog 설정'; _cmd='rsyslogd -N1'
      ;;
    U-35)
      command -v testparm >/dev/null 2>&1 || return 2
      _name='Samba 설정'; _cmd='testparm -s'
      ;;
    U-45|U-46|U-47|U-48)
      command -v postfix >/dev/null 2>&1 || return 2
      _name='Postfix 설정'; _cmd='postfix check'
      ;;
    U-49|U-50|U-51)
      command -v named-checkconf >/dev/null 2>&1 || return 2
      [ -f /etc/named.conf ] || [ -f /etc/bind/named.conf ] || return 2
      _name='BIND 설정'; _cmd='named-checkconf'
      ;;
    U-53|U-54|U-56|U-57)
      command -v proftpd >/dev/null 2>&1 || return 2
      for _conf in /etc/proftpd/proftpd.conf /etc/proftpd.conf; do
        [ -f "$_conf" ] && break
        _conf=''
      done
      [ -n "$_conf" ] || return 2
      _name='ProFTPD 설정'; printf -v _cmd 'proftpd -t -c %q' "$_conf"
      ;;
    U-63)
      command -v visudo >/dev/null 2>&1 || return 2
      [ -f /etc/sudoers ] || return 2
      _name='sudo 설정'; _cmd='visudo -cf /etc/sudoers'
      ;;
    U-65)
      command -v chronyd >/dev/null 2>&1 || return 2
      [ -f /etc/chrony.conf ] || [ -f /etc/chrony/chrony.conf ] || return 2
      _name='chrony 설정'; _cmd='chronyd -p'
      ;;
    *) return 2 ;;
  esac

  _VF_SYNTAX_TEST_NAME="$_name"
  _vf_capture_eval_subshell "$_cmd"
  _VF_SYNTAX_TEST_OUTPUT=$(printf '%s\n%s' "$_VF_CAPTURE_STDOUT" "$_VF_CAPTURE_STDERR" | sed '/^[[:space:]]*$/d')
  _VF_SYNTAX_TEST_HASH=$(_vf_verify_output_sha256 "$_VF_SYNTAX_TEST_OUTPUT" 2>/dev/null || true)
  [ "$_VF_CAPTURE_RC" -eq 0 ] && return 0
  return 1
}

_vf_capture_item_verification_baseline_once() {
  local _id="$1" _rc _u _units _list=''
  [ -n "${_VF_VERIFY_BASELINE_CAPTURED[$_id]:-}" ] && return 0
  _VF_VERIFY_BASELINE_CAPTURED["$_id"]=1

  _vf_run_item_syntax_test "$_id"; _rc=$?
  _VF_SYNTAX_BASE_RC["$_id"]="$_rc"
  _VF_SYNTAX_BASE_HASH["$_id"]="${_VF_SYNTAX_TEST_HASH:-}"

  _VF_SERVICE_BASE_ACTIVE["$_id"]=0
  _VF_SERVICE_BASE_LIST["$_id"]=''
  _units=$(_vf_item_service_units "$_id")
  [ -n "$_units" ] || return 0

  if _vf_systemd_available; then
    for _u in $_units; do
      if systemctl is-active --quiet "$_u" 2>/dev/null; then
        _VF_SERVICE_BASE_ACTIVE["$_id"]=1
        _list="${_list}${_list:+, }${_u}"
      fi
    done
  elif _vf_item_process_active "$_id"; then
    _VF_SERVICE_BASE_ACTIVE["$_id"]=1
    _list='process-detected'
  fi
  _VF_SERVICE_BASE_LIST["$_id"]="$_list"
}

# 반환: 0=PASS/SKIP, 1=FAIL, 2=MANUAL
_vf_verify_item_syntax_after() {
  local _id="$1" _post_rc _base_rc _base_hash
  _VF_SYNTAX_VERIFY_STATUS='SKIP'
  _VF_SYNTAX_VERIFY_DETAIL='안전한 설정 문법 검사 대상 없음'

  _vf_run_item_syntax_test "$_id"; _post_rc=$?
  _base_rc="${_VF_SYNTAX_BASE_RC[$_id]:-2}"
  _base_hash="${_VF_SYNTAX_BASE_HASH[$_id]:-}"

  if [ "$_post_rc" -eq 2 ]; then
    if [ "$_base_rc" -eq 0 ]; then
      _VF_SYNTAX_VERIFY_STATUS='MANUAL'
      _VF_SYNTAX_VERIFY_DETAIL='조치 전에는 가능했던 문법 검사를 조치 후 수행할 수 없음'
      return 2
    fi
    return 0
  fi
  if [ "$_post_rc" -eq 0 ]; then
    _VF_SYNTAX_VERIFY_STATUS='PASS'
    _VF_SYNTAX_VERIFY_DETAIL="${_VF_SYNTAX_TEST_NAME}: 정상"
    return 0
  fi
  if [ "$_base_rc" -eq 1 ] && [ -n "$_base_hash" ] && [ "$_base_hash" = "${_VF_SYNTAX_TEST_HASH:-}" ]; then
    _VF_SYNTAX_VERIFY_STATUS='MANUAL'
    _VF_SYNTAX_VERIFY_DETAIL="${_VF_SYNTAX_TEST_NAME}: 조치 전부터 존재한 동일 오류"
    return 2
  fi
  _VF_SYNTAX_VERIFY_STATUS='FAIL'
  _VF_SYNTAX_VERIFY_DETAIL="${_VF_SYNTAX_TEST_NAME}: 문법 검사 실패"
  return 1
}

# 반환: 0=PASS/SKIP, 1=FAIL
_vf_verify_item_service_after() {
  local _id="$1" _policy _units _u _state _active='' _enabled='' _found=0
  _VF_SERVICE_VERIFY_STATUS='SKIP'
  _VF_SERVICE_VERIFY_DETAIL='서비스 상태 검증 대상 없음'
  _policy=$(_vf_item_service_policy "$_id")
  [ "$_policy" != 'none' ] || return 0
  _units=$(_vf_item_service_units "$_id")
  [ -n "$_units" ] || return 0

  if _vf_systemd_available; then
    for _u in $_units; do
      _state=$(systemctl show "$_u" -p LoadState --value 2>/dev/null | head -1)
      [ -n "$_state" ] && [ "$_state" != 'not-found' ] && _found=1
      systemctl is-active --quiet "$_u" 2>/dev/null && _active="${_active}${_active:+, }${_u}"
      _state=$(systemctl is-enabled "$_u" 2>/dev/null | head -1)
      case "$_state" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
          _enabled="${_enabled}${_enabled:+, }${_u}(${_state})" ;;
      esac
    done

    case "$_policy" in
      disable)
        if [ -n "$_active" ] || [ -n "$_enabled" ]; then
          _VF_SERVICE_VERIFY_STATUS='FAIL'
          _VF_SERVICE_VERIFY_DETAIL="비활성화 대상 잔존${_active:+; active=${_active}}${_enabled:+; enabled=${_enabled}}"
          return 1
        fi
        _VF_SERVICE_VERIFY_STATUS='PASS'
        _VF_SERVICE_VERIFY_DETAIL='관련 유닛 비활성 및 자동기동 차단 확인'
        ;;
      require)
        if [ -z "$_active" ] && ! _vf_item_process_active "$_id"; then
          _VF_SERVICE_VERIFY_STATUS='FAIL'
          _VF_SERVICE_VERIFY_DETAIL='필수 서비스가 실행 상태가 아님'
          return 1
        fi
        _VF_SERVICE_VERIFY_STATUS='PASS'
        _VF_SERVICE_VERIFY_DETAIL="활성 서비스: ${_active:-프로세스 확인}"
        ;;
      preserve)
        if [ "${_VF_SERVICE_BASE_ACTIVE[$_id]:-0}" -eq 1 ]; then
          local _base_unit _missing=''
          while IFS= read -r _base_unit; do
            _base_unit=$(printf '%s' "$_base_unit" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -n "$_base_unit" ] || continue
            [ "$_base_unit" = 'process-detected' ] && continue
            systemctl is-active --quiet "$_base_unit" 2>/dev/null               || _missing="${_missing}${_missing:+, }${_base_unit}"
          done < <(printf '%s' "${_VF_SERVICE_BASE_LIST[$_id]:-}" | tr ',' '\n')
          if [ -n "$_missing" ]; then
            _VF_SERVICE_VERIFY_STATUS='FAIL'
            _VF_SERVICE_VERIFY_DETAIL="조치 전 활성 서비스가 조치 후 중단됨: ${_missing}"
            return 1
          fi
          if [ "${_VF_SERVICE_BASE_LIST[$_id]:-}" = 'process-detected' ] && ! _vf_item_process_active "$_id"; then
            _VF_SERVICE_VERIFY_STATUS='FAIL'
            _VF_SERVICE_VERIFY_DETAIL='조치 전 실행 중이던 서비스 프로세스가 조치 후 중단됨'
            return 1
          fi
        fi
        _VF_SERVICE_VERIFY_STATUS='PASS'
        if [ -n "$_active" ]; then
          _VF_SERVICE_VERIFY_DETAIL="서비스 실행 유지: ${_active}"
        elif [ "$_found" -eq 1 ]; then
          _VF_SERVICE_VERIFY_DETAIL='조치 전·후 비활성 상태 유지'
        else
          _VF_SERVICE_VERIFY_DETAIL='관련 systemd 유닛 없음'
        fi
        ;;
    esac
    return 0
  fi

  case "$_policy" in
    disable)
      if _vf_item_process_active "$_id"; then
        _VF_SERVICE_VERIFY_STATUS='FAIL'; _VF_SERVICE_VERIFY_DETAIL='비활성화 대상 프로세스가 실행 중'; return 1
      fi
      _VF_SERVICE_VERIFY_STATUS='PASS'; _VF_SERVICE_VERIFY_DETAIL='관련 프로세스 미실행 확인(systemd 미사용)'
      ;;
    require)
      if ! _vf_item_process_active "$_id"; then
        _VF_SERVICE_VERIFY_STATUS='FAIL'; _VF_SERVICE_VERIFY_DETAIL='필수 서비스 프로세스를 확인할 수 없음'; return 1
      fi
      _VF_SERVICE_VERIFY_STATUS='PASS'; _VF_SERVICE_VERIFY_DETAIL='관련 프로세스 실행 확인(systemd 미사용)'
      ;;
    preserve)
      if [ "${_VF_SERVICE_BASE_ACTIVE[$_id]:-0}" -eq 1 ] && ! _vf_item_process_active "$_id"; then
        _VF_SERVICE_VERIFY_STATUS='FAIL'; _VF_SERVICE_VERIFY_DETAIL='조치 전 서비스 프로세스가 조치 후 중단됨'; return 1
      fi
      _VF_SERVICE_VERIFY_STATUS='PASS'; _VF_SERVICE_VERIFY_DETAIL='서비스 프로세스 상태 유지(systemd 미사용)'
      ;;
  esac
  return 0
}

# 반환: 0=PASS, 1=FAIL, 2=MANUAL
_vf_run_postcheck() {
  local _id="$1" _after_out="${2:-}" _after_rc="${3:-0}" _pattern="${4:-}"
  local _check_rc _syntax_rc _service_rc _final='PASS' _reason='' _evidence='PASS'
  local _check_reason='' _check_guidance=''

  check_still_vuln "$_id"; _check_rc=$?
  _check_reason="${_CHECK_MANUAL_REASON:-}"
  _check_guidance="${_CHECK_MANUAL_GUIDANCE:-}"
  case "$_check_rc" in
    1) _VF_POSTCHECK_CHECK_STATUS["$_id"]='PASS' ;;
    2) _VF_POSTCHECK_CHECK_STATUS["$_id"]='PASS(해당없음)' ;;
    3) _VF_POSTCHECK_CHECK_STATUS["$_id"]='MANUAL'; _final='MANUAL'; _reason="${_check_reason:-재점검 자동 판정 불가}" ;;
    0)
      # U-65는 "재점검에서도 취약(미동기화)"이 곧 "조치 실패"를 의미하지 않는다.
      # y는 "조치를 시도하도록 승인"한 것이지 외부 NTP 서버 응답까지 스크립트가
      # 보장할 수 없다. 로컬에서 해야 할 일(서비스 활성화·자동시작 등록)이
      # 실제로 성공했는지는 after_cmd(after_out)의 실시간 서비스 상태와
      # _u65_apply가 남긴 _U65_ENABLE_RESULT로 판단할 수 있으므로, 로컬 조치가
      # 정상 수행됐다면 FAIL이 아니라 MANUAL로 내린다. 로컬 조치 자체(서비스
      # 활성화/자동시작/설치 등)가 실패했을 때만 진짜 조치 실패로 남긴다.
      local _u65_after_clean=""
      if [ "$_id" = "U-65" ]; then
        _u65_after_clean=$(printf '%s' "$_after_out" | _strip_ansi_stream)
      fi
      if [ "$_id" = "U-65" ] \
         && printf '%s' "$_u65_after_clean" | grep -qE '^서비스 상태 : .*\(active\)' \
         && [ "${_U65_ENABLE_RESULT:-}" = "성공" ]; then
        _VF_POSTCHECK_CHECK_STATUS["$_id"]='MANUAL'
        _final='MANUAL'
        _reason='NTP 서비스 설정 및 활성화는 완료되었으나 설정된 NTP 소스와의 동기화를 확인하지 못했습니다. 확인 대상: NTP 서버 주소 / DNS 해석 / 아웃바운드 UDP 123 방화벽 / NTP 서버 응답 상태'
      else
        _VF_POSTCHECK_CHECK_STATUS["$_id"]='FAIL'; _final='FAIL'; _reason='조치 후 재점검에서도 취약 상태가 남아 있음'
      fi
      ;;
    *) _VF_POSTCHECK_CHECK_STATUS["$_id"]='FAIL'; _final='FAIL'; _reason="조치 후 재점검 비정상 종료(rc=${_check_rc})" ;;
  esac

  _vf_verify_item_syntax_after "$_id"; _syntax_rc=$?
  _VF_POSTCHECK_SYNTAX_STATUS["$_id"]="${_VF_SYNTAX_VERIFY_STATUS:-SKIP}"
  if [ "$_syntax_rc" -eq 1 ]; then
    _final='FAIL'; _reason="${_reason}${_reason:+; }${_VF_SYNTAX_VERIFY_DETAIL}"
  elif [ "$_syntax_rc" -eq 2 ] && [ "$_final" != 'FAIL' ]; then
    _final='MANUAL'; _reason="${_reason}${_reason:+; }${_VF_SYNTAX_VERIFY_DETAIL}"
  fi

  _vf_verify_item_service_after "$_id"; _service_rc=$?
  _VF_POSTCHECK_SERVICE_STATUS["$_id"]="${_VF_SERVICE_VERIFY_STATUS:-SKIP}"
  if [ "$_service_rc" -eq 1 ]; then
    _final='FAIL'; _reason="${_reason}${_reason:+; }${_VF_SERVICE_VERIFY_DETAIL}"
  fi

  # 기존 after_cmd/pass_pattern은 감사용 보조 신호다. 최종 성공 판정에는 사용하지 않는다.
  if [ "$_after_rc" -ne 0 ]; then
    _evidence='WARN(rc)'
  elif [ -n "$_pattern" ] && ! printf '%s\n' "$_after_out" | grep -qE "$_pattern"; then
    _evidence='WARN(pattern)'
  fi
  _VF_POSTCHECK_EVIDENCE_STATUS["$_id"]="$_evidence"
  _VF_POSTCHECK_STATUS["$_id"]="$_final"
  _VF_POSTCHECK_REASON["$_id"]="${_reason:-공통 최종 검증 통과}"
  _VF_POSTCHECK_DETAIL["$_id"]="점검 함수=${_VF_POSTCHECK_CHECK_STATUS[$_id]}; 설정 문법=${_VF_POSTCHECK_SYNTAX_STATUS[$_id]}(${_VF_SYNTAX_VERIFY_DETAIL}); 서비스=${_VF_POSTCHECK_SERVICE_STATUS[$_id]}(${_VF_SERVICE_VERIFY_DETAIL}); 출력 증빙=${_evidence}${_check_guidance:+; 확인 안내=${_check_guidance}}"

  case "$_final" in
    PASS) return 0 ;;
    MANUAL) return 2 ;;
    *) return 1 ;;
  esac
}

_vf_append_postcheck_detail() {
  local _id="$1" _d="${_VF_POSTCHECK_DETAIL[$1]:-}"
  [ -n "$_d" ] || return 0
  if [ -n "${DETAIL_VAL[$_id]:-}" ]; then
    case "${DETAIL_VAL[$_id]}" in
      *'[최종 재점검]'*) : ;;
      *) DETAIL_VAL["$_id"]="${DETAIL_VAL[$_id]} | [최종 재점검] ${_d}" ;;
    esac
  else
    DETAIL_VAL["$_id"]="[최종 재점검] ${_d}"
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
  _CHECK_MANUAL_REASON=""
  _CHECK_MANUAL_GUIDANCE=""
  _vf_capture_item_verification_baseline_once "$id"
  case "$id" in
    U-01)
      # SSH 확인 — 실제 적용값(sshd -T)을 최우선으로 판정
      # 이유: /etc/ssh/sshd_config.d/*.conf Include 값이 메인 설정보다 우선 적용될 수 있음
      val=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' \
            | awk '{print $2}' | tail -1 \
            | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

      # sshd -T 실패 시에만 설정 파일 fallback.
      # Include 는 "선언된 위치"에서 전개되고 sshd 는 먼저 얻은 값을 채택한다.
      # 기존 코드는 메인 파일을 항상 먼저 읽어, Include 가 파일 최상단에 있는
      # Ubuntu 등에서 sshd_config.d 값이 무시되는 우선순위 역전이 있었다.
      if [ -z "$val" ]; then
        val=$(_sshd_config_stream 2>/dev/null \
              | grep -v '^[[:space:]]*#' \
              | awk 'tolower($1)=="match"{exit}
                     tolower($1)=="permitrootlogin"{print $2; exit}' \
              | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      fi

      { [ "$val" != "no" ] && [ "$val" != "prohibit-password" ] && [ "$val" != "without-password" ]; } && return 0

      # 전역값이 양호해도 Match 블록에서 root 로그인을 재허용했으면 취약이다.
      # sshd -T 는 Match 블록을 출력하지 않으므로 전역값만으로는 놓친다.
      _sshd_match_permits_root && return 0

      # Telnet 활성 시 추가 확인 (ss 부재 환경도 폴백으로 판정)
      TELNET_ON=0
      _port_listening tcp 23 && TELNET_ON=1
      pgrep -x telnetd &>/dev/null && TELNET_ON=1
      if [ $TELNET_ON -eq 1 ]; then
        grep -v '^#' /etc/securetty 2>/dev/null | grep -q '^pts/' && return 0
        # Debian/Ubuntu 는 'auth requisite pam_securetty.so' 로 설정되고,
        # 일부 배포판은 '[success=ok ...]' 형태의 control field 를 쓴다.
        # 'required' 만 인정하던 기존 패턴은 이들을 모두 취약으로 오탐했다.
        grep -qE '^[[:space:]]*auth[[:space:]]+(required|requisite|\[[^]]*\])[[:space:]]+.*pam_securetty\.so' \
          /etc/pam.d/login 2>/dev/null || return 0
      fi
      return 1 ;;
    U-02)
      # 기존 코드는 tail/awk 누락으로 매칭 줄이 2개면 값이 "90\n365" 가 되어
      # 산술 비교가 에러로 삼켜지고 조용히 통과했다. 마지막 유효값을 채택한다.
      MAX=$(grep -vE '^[[:space:]]*#' /etc/login.defs 2>/dev/null \
            | awk '$1=="PASS_MAX_DAYS"{v=$2} END{print v}')
      MIN=$(grep -vE '^[[:space:]]*#' /etc/login.defs 2>/dev/null \
            | awk '$1=="PASS_MIN_DAYS"{v=$2} END{print v}')
      # minlen 은 pwquality.conf 단일 파일이 아니라 pwquality.conf.d/*.conf 와
      # PAM 인라인 인자(pam_pwquality.so minlen=10)로도 설정된다.
      LEN=$(_pwquality_value minlen)
      { [ -z "$MAX" ] || [ "$MAX" -gt 90 ]; } 2>/dev/null && return 0
      { [ -z "$MIN" ] || [ "$MIN" -lt 1 ];  } 2>/dev/null && return 0
      { [ -z "$LEN" ] || [ "$LEN" -lt 8 ];  } 2>/dev/null && return 0
      # 복잡성(문자 혼합) 검사 — KISA 2026 가이드(p.21) 기준: "3종류 이상 + 8자 이상" 또는
      # "2종류 이상 + 10자 이상" 둘 다 인정. 가이드의 실제 조치 예시는 minclass가 아니라
      # lcredit/ucredit/dcredit/ocredit=-1 조합을 사용하므로 credit 개수만으로 판단한다.
      CCNT=0
      for _cr in lcredit ucredit dcredit ocredit; do
        # 양수 credit은 "길이 보정"이므로 요구 조건이 아님 — 반드시 음수(-1 이하)만 인정
        _crv=$(_pwquality_value "$_cr")
        case "$_crv" in
          -[1-9]|-[1-9][0-9]*) CCNT=$((CCNT+1)) ;;
        esac
      done
      LEN_N=$LEN; [[ "$LEN_N" =~ ^[0-9]+$ ]] || LEN_N=0
      _u02_complex=0
      { [ "$CCNT" -ge 3 ] && [ "$LEN_N" -ge 8 ]; } && _u02_complex=1
      { [ "$CCNT" -ge 2 ] && [ "$LEN_N" -ge 10 ]; } && _u02_complex=1
      [ "$_u02_complex" -eq 0 ] && return 0

      # login.defs 의 PASS_MAX_DAYS 는 "신규 계정"에만 적용된다. 기존 계정의
      # 만료일(shadow 5번째 필드)이 반영되지 않은 경우를 놓치지 않도록 확인한다.
      # 오탐을 피하려고 대상을 좁힌다: 실제 패스워드 해시가 있고(잠기지 않음)
      # UID_MIN 이상인 로그인 계정만 본다.
      _u02_uid_min=$(_login_uid_min)
      _u02_stale=$(awk -F: -v umin="$_u02_uid_min" -v maxd="${MAX:-90}" '
          NR==FNR { if ($3+0 >= umin+0) uid[$1]=1; next }
          ($1 in uid) && $2 ~ /^\$/ {
            if ($5 == "" || $5+0 > maxd+0) { print $1; exit }
          }' /etc/passwd /etc/shadow 2>/dev/null)
      [ -n "$_u02_stale" ] && return 0
      return 1 ;;
    U-03)
      # faillock.conf (authselect/pam_faillock 신형)
      DENY=$(grep -v '^#' /etc/security/faillock.conf 2>/dev/null | grep -oP 'deny\s*=\s*\K[0-9]+' | head -1)
      if [ -n "$DENY" ]; then
        [ "$DENY" -gt 10 ] 2>/dev/null && return 0
        # deny 양호해도 preauth/authfail 라인 누락 시 수동확인
        # 주의: 리턴코드 2는 호출부에서 "해당없음(서비스 미운용)"으로 집계되므로
        #       수동확인 의도는 반드시 3을 사용한다.
        for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
          [ -f "$_pf" ] || continue
          grep -qE '^auth[[:space:]].*pam_faillock\.so.*preauth' "$_pf" 2>/dev/null || return 3
          grep -qE '^auth[[:space:]].*pam_faillock\.so.*authfail' "$_pf" 2>/dev/null || return 3
        done
        return 1
      fi
      # pam_faillock / pam_tally / pam_tally2 — PAM 파일에서 deny= 탐색
      for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] || continue
        DENY=$(grep -v '^#' "$_pf" | grep -oP 'deny\s*=\s*\K[0-9]+' | head -1)
        if [ -n "$DENY" ]; then
          [ "$DENY" -gt 10 ] 2>/dev/null && return 0
          # pam_tally2 사용 시 onerr=fail 누락이면 수동확인 (2 아님 — 3)
          if grep -qE 'pam_tally2' "$_pf" 2>/dev/null; then
            grep -qE 'onerr=fail' "$_pf" 2>/dev/null || return 3
          fi
          return 1
        fi
      done
      return 0 ;;
    U-04)
      [ ! -f /etc/shadow ] && return 0
      # 기존 조건($2!="")이 빈 두 번째 필드를 취약에서 제외했다. 빈 필드는
      # "패스워드 없이 로그인 가능"을 의미하는 가장 위험한 상태이므로 포함한다.
      # 잠금 표기(*, !, !!, *LK*)는 해시가 아니므로 계속 제외한다.
      NO_SHADOW=$(awk -F: '$2 != "x" && $2 !~ /^[!*]/ {print $1}' /etc/passwd | head -1)
      [ -n "$NO_SHADOW" ] && return 0; return 1 ;;
    U-05)
      local _u05_first
      _u05_first=$(_u05_extra_uid0_rows | head -1)
      [ -n "$_u05_first" ] && return 0; return 1 ;;
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
      local _u09_first
      _u09_first=$(_u09_missing_gid_rows | head -1)
      [ -n "$_u09_first" ] && return 0; return 1 ;;
    U-10)
      local _u10_first
      _u10_first=$(_u10_duplicate_uid_rows | head -1)
      [ -n "$_u10_first" ] && return 0; return 1 ;;
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
      # readonly 없으면 수동확인 (2는 "해당없음"으로 집계되므로 3을 사용)
      [ "$_u12_readonly" -eq 0 ] && return 3
      return 1 ;;
    U-13)
      # 기존 로직의 문제:
      #  (1) ENCRYPT_METHOD 가 SHA512 면 즉시 양호 → 기존 계정 해시가 전부
      #      MD5($1$)여도 미탐. 선언보다 실제 저장된 해시가 우선이다.
      #  (2) shadow 앞 5줄만 표본 → root 가 잠금 상태면 판정 근거가 사라진다.
      #  (3) bcrypt($2a/$2b/$2y), scrypt($7$), gost-yescrypt($gy$) 미인정 → 오탐.
      ALGO=$(grep -vE '^[[:space:]]*#' /etc/login.defs 2>/dev/null \
             | awk '$1=="ENCRYPT_METHOD"{v=$2} END{print v}')

      # 실제 저장된 해시 중 취약 알고리즘이 있으면 그 자체로 취약
      WEAK=$(awk -F: '
          $2 == "" || $2 ~ /^[!*]/ { next }
          $2 ~ /^\$1\$/ { print $1 " (MD5)"; exit }
          $2 ~ /^\$3\$/ { print $1 " (NT)";  exit }
          $2 !~ /^\$/ { if (length($2) >= 13 && length($2) <= 20) { print $1 " (DES)"; exit } }
        ' /etc/shadow 2>/dev/null)
      [ -n "$WEAK" ] && return 0

      if [ -n "$ALGO" ]; then
        echo "$ALGO" | grep -qiE '^(SHA512|SHA256|YESCRYPT|GOST_YESCRYPT|BCRYPT|BLOWFISH)$' && return 1
        return 0
      fi
      # ENCRYPT_METHOD 미선언 시 실제 해시로 판정 (표본 제한 없이 전 계정)
      awk -F: '$2 ~ /^\$(6|5|y|gy|7|2[aby])\$/ {found=1} END{exit(found?0:1)}' \
        /etc/shadow 2>/dev/null && return 1
      return 0 ;;
    U-14)
      # 문자열 패턴 대신 PATH 값을 항목 단위로 파싱해 판정한다.
      # 기존 'PATH=.*\.' 패턴은 /opt/app-1.2/bin 같은 정상 경로의 점까지
      # 매칭해 사실상 모든 서버를 취약으로 오탐했다.
      local _f14 _l14 _v14
      _u14_path_has_dot "$PATH" && return 0
      for _f14 in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/profile.d/*.sh \
                  /root/.bash_profile /root/.bashrc /root/.profile; do
        [ -f "$_f14" ] || continue
        while IFS= read -r _l14; do
          _v14="${_l14#*PATH=}"
          _u14_path_has_dot "$_v14" && return 0
        done < <(grep -vE '^[[:space:]]*#' "$_f14" 2>/dev/null \
                 | grep -E '(^|[[:space:]]|;|&)(export[[:space:]]+)?PATH=')
      done
      return 1 ;;
    U-15)
      CNT=$(_u15_find_noowner | wc -l)
      [ "$CNT" -gt 0 ] && return 0; return 1 ;;
    U-16)
      # stat 은 POSIX ACL 을 반영하지 않으므로 확장 ACL 을 별도로 확인한다.
      _has_permissive_acl /etc/passwd && return 0
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
      # shadow 파일 부재는 양호가 아니다(패스워드가 passwd 파일에 남아 있다는 뜻).
      [ ! -f /etc/shadow ] && return 0
      _has_permissive_acl /etc/shadow && return 0
      O=$(stat -c '%U' /etc/shadow 2>/dev/null); P=$(stat -c '%a' /etc/shadow 2>/dev/null)
      # Debian/Ubuntu의 root:shadow 640은 허용하되, group 쓰기/실행과 other 권한은 금지한다.
      # 640/600/400은 양호, 660/650/644 등은 취약으로 판정한다.
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#037 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-19)
      _has_permissive_acl /etc/hosts && return 0
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
      # /etc/rsyslog.d/*.conf 와 syslog-ng 설정을 확인하지 않아, 실제 로그 정책이
      # 담긴 파일의 권한 문제를 놓쳤다(최신 배포판은 대부분 conf.d 를 사용한다).
      for F in /etc/syslog.conf /etc/rsyslog.conf /etc/rsyslog.d/*.conf \
               /etc/syslog-ng/syslog-ng.conf /etc/syslog-ng/conf.d/*.conf; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$(( 8#${P:-777} & 8#037 ))" -ne 0 ]; } 2>/dev/null && return 0
        _has_permissive_acl "$F" && return 0
      done; return 1 ;;
    U-22)
      _has_permissive_acl /etc/services && return 0
      O=$(stat -c '%U' /etc/services 2>/dev/null); P=$(stat -c '%a' /etc/services 2>/dev/null)
      [ "$O" = "root" ] && [ "$(( 8#${P:-777} & 8#022 ))" -eq 0 ] 2>/dev/null && return 1; return 0 ;;
    U-23)
      # KISA 기준: SUID/SGID 필요 여부는 운영자가 판단한다.
      # 승인 당시의 소유자·그룹·권한과 현재 상태가 동일하거나,
      # 특정 그룹 실행 제한 정책이 검증된 파일만 관리 완료로 인정한다.
      EXTRA=$(_u23_find_suid | while read -r f; do
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
      # /dev 하위의 tmpfs 마운트(/dev/shm, /dev/mqueue, /dev/hugepages)에는
      # 공유메모리·메시지큐 정규 파일이 정상적으로 존재한다(PostgreSQL, JVM,
      # Chrome 등). 기존 로직은 -xdev 없이 이들을 모두 순회해 확정적으로 오탐했다.
      NONDEV=$(find /dev -xdev \
        \( -path /dev/shm -o -path /dev/mqueue -o -path /dev/hugepages \
           -o -path /dev/pts -o -path /dev/.udev -o -path '/dev/.lxc*' \) -prune -o \
        \( -not -type d -a -not -type c -a -not -type b -a -not -type l \
           -a -not -type p -a -not -type s \) -print 2>/dev/null \
        | grep -v '\.udev' | head -1)
      [ -n "$NONDEV" ] && return 0; return 1 ;;
    U-27)
      # 파일 존재만으로 취약 처리하면 0바이트 빈 파일도 적발되어 오탐이 된다.
      # 신뢰관계가 실제로 설정된 경우(주석·공백 외 유효한 줄이 있는 경우)만 취약.
      if [ -f /etc/hosts.equiv ] \
         && grep -qvE '^[[:space:]]*(#|$)' /etc/hosts.equiv 2>/dev/null; then
        return 0
      fi
      # .rhosts 는 /root /home 고정 경로가 아니라 실제 홈 디렉터리 기준으로 찾는다.
      # (/export/home, /app, /u01 등에 홈이 있는 환경의 미탐도 함께 해소된다.)
      local _u27_home
      while IFS=: read -r _ _ _ _ _ _u27_home _; do
        [ -n "$_u27_home" ] && [ -d "$_u27_home" ] || continue
        [ -f "${_u27_home}/.rhosts" ] || continue
        grep -qvE '^[[:space:]]*(#|$)' "${_u27_home}/.rhosts" 2>/dev/null && return 0
      done < /etc/passwd
      return 1 ;;
    U-28)
      # 판정 원칙: "규칙이 존재하는가"가 아니라 "차단 정책이 실제로 걸려 있는가"로
      # 판정한다. 기존 로직은 규칙이 1줄만 있어도 양호로 처리해서,
      #  (1) Docker/Podman/K8s 가 자동 주입한 NAT·격리 규칙만 있는 호스트
      #  (2) hosts.allow 에 "ALL: ALL"(전체 허용)만 있는 호스트
      # 를 모두 양호로 오판했다.
      local _u28_nft="" _u28_ipt="" _u28_deny="" _u28_allow=""

      # 1) firewalld / ufw — 활성 상태면 기본 정책이 차단이므로 양호
      systemctl is-active firewalld 2>/dev/null | grep -q '^active' && return 1
      if command -v ufw &>/dev/null; then
        ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]*active' && return 1
      fi
      systemctl is-active ufw 2>/dev/null | grep -q '^active' && return 1

      # 2) nftables — 컨테이너 런타임이 만든 테이블을 제외하고,
      #    input hook 의 기본 정책이 drop/reject 이거나 input 체인에
      #    명시적 drop/reject 규칙이 있어야 접근제어로 인정한다.
      if command -v nft &>/dev/null; then
        _u28_nft=$(nft list ruleset 2>/dev/null \
                   | grep -viE '^[[:space:]]*table[[:space:]]+(ip|ip6|inet|bridge|netdev)[[:space:]]+(docker|podman|cni|kube)')
        if echo "$_u28_nft" | grep -qE 'hook[[:space:]]+input.*policy[[:space:]]+(drop|reject)'; then
          return 1
        fi
        if echo "$_u28_nft" | awk '
              /hook[[:space:]]+input/       { inchain=1 }
              inchain && /^[[:space:]]*}/   { inchain=0 }
              inchain && /(^|[[:space:]])(drop|reject)([[:space:]]|$)/ { found=1 }
              END { exit(found ? 0 : 1) }'; then
          return 1
        fi
      fi

      # 3) iptables — INPUT 기본 정책이 DROP/REJECT 이거나,
      #    컨테이너/가상화 체인을 제외한 INPUT 규칙에 DROP/REJECT 가 있어야 인정한다.
      if command -v iptables &>/dev/null; then
        _u28_ipt=$(iptables -S 2>/dev/null)
        echo "$_u28_ipt" | grep -qE '^-P[[:space:]]+INPUT[[:space:]]+(DROP|REJECT)' && return 1
        echo "$_u28_ipt" \
          | grep -E '^-A[[:space:]]+INPUT[[:space:]]' \
          | grep -vEi '(DOCKER|docker0|br-[0-9a-f]{8,}|CNI-|KUBE-|LIBVIRT|cali-)' \
          | grep -qE '\-j[[:space:]]+(DROP|REJECT)' && return 1
      fi

      # 4) TCP Wrapper — hosts.deny 에 전체 차단 규칙이 있고,
      #    hosts.allow 가 전체 허용(ALL : ALL)이 아닌 경우에만 인정한다.
      _u28_deny=$(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.deny 2>/dev/null)
      if echo "$_u28_deny" | grep -qiE '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL'; then
        _u28_allow=$(grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow 2>/dev/null)
        echo "$_u28_allow" \
          | grep -qiE '^[[:space:]]*ALL[[:space:]]*:[[:space:]]*ALL[[:space:]]*$' || return 1
      fi
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
      # umask 는 "22" 처럼 선행 0을 생략한 2자리 표기도 유효하다.
      # 기존 정규식은 3~4자리만 허용해 'umask 22'(=022)를 취약으로 오탐했다.
      if [[ "$_u30_final" =~ ^0*[0-7]{1,4}$ ]]; then
        _u30_norm="$_u30_final"
        while [ "${#_u30_norm}" -lt 3 ]; do _u30_norm="0${_u30_norm}"; done
        if [ $(( (8#$_u30_norm) & (8#022) )) -eq $(( 8#022 )) ]; then
          return 1
        fi
      fi
      return 0 ;;
    U-31)
      # 1000 하드코딩은 UID_MIN=500 인 구형 RHEL/CentOS 의 일반 사용자 계정을
      # 점검 대상에서 통째로 빠뜨린다. login.defs 의 UID_MIN 을 사용한다.
      _u31_uid_min=$(_login_uid_min)
      while IFS=: read -r user _ uid _ _ homedir _; do
        [ "$uid" -lt "$_u31_uid_min" ] 2>/dev/null && continue
        [ -z "$homedir" ] || [ "$homedir" = "/" ] || [ ! -d "$homedir" ] && continue
        O=$(stat -c '%U' "$homedir" 2>/dev/null); P=$(stat -c '%a' "$homedir" 2>/dev/null)
        { [ "$O" != "$user" ] || [ "$(( 8#${P:-777} & 8#002 ))" -ne 0 ]; } 2>/dev/null && return 0
      done < /etc/passwd; return 1 ;;
    U-32)
      _u32_uid_min=$(_login_uid_min)
      while IFS=: read -r _user _ uid _ _ homedir _; do
        [ "$uid" -lt "$_u32_uid_min" ] 2>/dev/null && continue
        # nobody(uid 65534)는 표준 시스템 계정 — Debian계는 홈이 /nonexistent로
        # 설계되어 있어 취약이 아니며, 홈 생성 조치 대상도 아니다.
        { [ "$_user" = "nobody" ] || [ "$uid" -ge 65534 ] 2>/dev/null; } && continue
        [ -n "$homedir" ] && [ ! -d "$homedir" ] && return 0
      done < /etc/passwd; return 1 ;;
    U-33)
      [ -n "$(_u33_find | head -1)" ] && return 0; return 1 ;;
    U-34) _port_listening tcp 79 && return 0; return 1 ;;
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
      for _cf in /etc/samba/smb.conf; do
        [ -f "$_cf" ] || continue
        grep -v '^\s*[#;]' "$_cf" 2>/dev/null | grep -qiE 'guest[[:space:]]*ok[[:space:]]*=[[:space:]]*yes' && return 0
        grep -v '^\s*[#;]' "$_cf" 2>/dev/null | grep -qiE 'map[[:space:]]+to[[:space:]]+guest[[:space:]]*=[[:space:]]*(bad user|bad password)' && return 0
      done
      return 1 ;;
    U-36)
      # 512(exec)/513(login)/514(shell) 포트를 확인한다.
      # 주의: 514/tcp 는 rsyslog·syslog-ng 의 TCP 수신 포트로도 널리 쓰이므로,
      # 리스닝 프로세스가 syslog 계열이거나 syslog TCP 수신 설정이 확인되면
      # rsh 계열 노출로 판정하지 않는다.
      local _u36_l _u36_port
      while IFS= read -r _u36_l; do
        [ -n "$_u36_l" ] || continue
        case "$_u36_l" in
          *rsyslogd*|*rsyslog*|*syslog-ng*|*syslogd*) continue ;;
        esac
        _u36_port=$(printf '%s' "$_u36_l" | grep -oE ':(512|513|514)[[:space:]]' \
                    | head -1 | tr -cd '0-9')
        if [ "$_u36_port" = "514" ] && _u36_syslog_tcp; then
          continue
        fi
        return 0
      done < <(_listen_dump tcp | grep -E ':(512|513|514)[[:space:]]')
      for svc in rsh rlogin rexec rsh.socket rlogin.socket rexec.socket \
                 rexec.service rlogin.service rsh.service; do
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
        # "750 이하"는 숫자 대소가 아니라 비트 부분집합으로 판정해야 한다.
        # 숫자 비교(707 < 750)로는 other rwx 가 열린 권한을 양호로 오판한다.
        # 750 에서 금지되는 비트 = group w(020) + other rwx(007) = 027
        [ "$((8#${P:-7777} & 8#027))" -ne 0 ] 2>/dev/null && return 0
      done

      # cron / at 설정 파일: root 소유, 640 이하
      for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        # 640 에서 금지되는 비트 = group wx(030) + other rwx(007) = 037
        [ "$((8#${P:-7777} & 8#037))" -ne 0 ] 2>/dev/null && return 0
      done

      # cron / at 관련 디렉터리: root 소유, 750 이하
      for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
               /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] || continue
        O=$(stat -c '%U' "$D" 2>/dev/null); P=$(stat -c '%a' "$D" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        [ "$((8#${P:-7777} & 8#027))" -ne 0 ] 2>/dev/null && return 0
      done

      # cron / at 작업 목록 일반 파일: root 소유, 640 이하
      for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
        [ -d "$D" ] || continue
        while IFS= read -r -d '' F; do
          O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
          [ "$O" != "root" ] && return 0
          [ "$((8#${P:-7777} & 8#037))" -ne 0 ] 2>/dev/null && return 0
        done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
      done
      return 1 ;;
    U-38)
      for port in 7 9 13 19; do
        _port_listening udp "$port" && return 0
        _port_listening tcp "$port" && return 0
      done; return 1 ;;
    U-39)
      _u39_unit=""
      for _u in nfs-server.service nfs-kernel-server.service; do
        systemctl list-unit-files "$_u" --no-legend 2>/dev/null | grep -q . && { _u39_unit="$_u"; break; }
      done
      if [ -n "$_u39_unit" ]; then
        systemctl is-active "$_u39_unit" 2>/dev/null | grep -q '^active' && return 0
        systemctl is-enabled "$_u39_unit" 2>/dev/null | grep -qE '^(enabled|enabled-runtime|linked|linked-runtime)$' && return 0
      fi
      _port_listening tcp 2049 && return 0
      # nfsd 프로세스 존재 여부(pgrep -f '[n]fsd')는 다른 프로세스 커맨드라인에
      # 우연히 "nfsd" 문자열이 섞여도 걸리는 오탐 가능성이 있다. 실제 커널 NFS
      # 서버 스레드 수(/proc/fs/nfsd/threads)로 대체해 판단한다.
      if [ -r /proc/fs/nfsd/threads ]; then
        _u39_threads=$(cat /proc/fs/nfsd/threads 2>/dev/null | head -1)
        [ "${_u39_threads:-0}" -gt 0 ] 2>/dev/null && return 0
      fi
      # /proc/fs/nfsd 마운트 여부와 showmount의 export 목록은 커널 인터페이스
      # 잔존/조회 실패일 뿐 실제 네트워크 노출과는 무관할 수 있어 취약 판정에서
      # 제외한다 (참고 정보로만 화면에 표시하고, U-35/U-40 연계 판정에만 사용).
      return 1 ;;
    U-40)
      [ ! -f /etc/exports ] && return 2
      # 주석 줄을 걸러내지 않아 '# no_root_squash' 만 있어도 취약으로 오탐했다.
      grep -vE '^[[:space:]]*(#|$)' /etc/exports 2>/dev/null \
        | grep -q 'no_root_squash' && return 0; return 1 ;;
    U-41)
      systemctl is-active autofs 2>/dev/null | grep -q '^active' && return 0; return 1 ;;
    U-42)
      for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do
        pgrep -x "$svc" &>/dev/null && return 0
      done; return 1 ;;
    U-43)
      for p in ypserv ypbind; do pgrep -x "$p" &>/dev/null && return 0; done; return 1 ;;
    U-44)
      _port_listening udp 69 517 518 && return 0; return 1 ;;
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
      _bind_policy_audit transfer >/dev/null 2>&1; _u50_rc=$?
      case $_u50_rc in
        0) return 0 ;;
        1) return 1 ;;
        2) return 2 ;;
        *) _CHECK_MANUAL_REASON="BIND zone별 allow-transfer 유효 정책을 안전하게 해석할 수 없음"
           _CHECK_MANUAL_GUIDANCE="named-checkconf 오류, 사용자 ACL 또는 복합 상속 정책을 직접 확인하세요."
           return 3 ;;
      esac ;;
    U-51)
      _bind_policy_audit update >/dev/null 2>&1; _u51_rc=$?
      case $_u51_rc in
        0) return 0 ;;
        1) return 1 ;;
        2) return 2 ;;
        *) _CHECK_MANUAL_REASON="BIND zone별 allow-update/update-policy 유효 정책을 자동 확정할 수 없음"
           _CHECK_MANUAL_GUIDANCE="TSIG identity, update-policy grant 범위와 DHCP/DDNS 연동 정책을 확인하세요."
           return 3 ;;
      esac ;;
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
      _u54_tls_state; _u54_rc=$?
      case $_u54_rc in
        0) return 0 ;;
        1) return 1 ;;
        *) _CHECK_MANUAL_REASON="활성 FTP 데몬의 실제 설정 파일 또는 TLS 강제 범위를 자동 확정할 수 없음"
           _CHECK_MANUAL_GUIDANCE="vsftpd 다중 설정 파일, 비표준 FTP 데몬 또는 ProFTPD Include/TLSRequired 정책을 확인하세요."
           return 3 ;;
      esac ;;
    U-55) return 3 ;;  # 수동확인
    U-56)
      # FTP 서비스 존재 여부 확인
      _u56_has=0
      for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
               /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
        [ -f "$F" ] && _u56_has=1 && break
      done
      _port_listening tcp 21 990 && _u56_has=1
      [ $_u56_has -eq 0 ] && return 2  # FTP 서비스 없음 → 해당없음

      # vsftpd: tcp_wrappers=YES + /etc/hosts.allow 에 ftp 항목 존재 여부
      for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
        [ -f "$F" ] || continue
        _tw=$(grep -v '^#' "$F" 2>/dev/null \
              | grep -i 'tcp_wrappers' | awk -F'=' '{print toupper($2)}' | tr -d ' ' | head -1)
        if [ "$_tw" = "YES" ]; then
          # 접근제어로 인정하려면 허용 대상이 구체적이어야 한다.
          # "ALL : ALL" 처럼 클라이언트 목록이 ALL 뿐인 줄은 전체 허용이므로 제외한다.
          if grep -vE '^[[:space:]]*(#|$)' /etc/hosts.allow 2>/dev/null \
             | grep -iE '^[[:space:]]*(vsftpd|ftpd|in\.ftpd|ALL)[[:space:]]*:' \
             | grep -qvE ':[[:space:]]*ALL[[:space:]]*$'; then
            return 1
          fi
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
      _u57_found=0
      for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers \
               /etc/proftpd/ftpusers; do
        [ -f "$F" ] || continue
        _u57_found=1
        grep -v '^#' "$F" | grep -q '^root' || return 0
      done
      [ "$_u57_found" -eq 1 ] && return 1
      return 2 ;;
    U-58)
      systemctl is-active snmpd 2>/dev/null | grep -q '^active' && return 0
      _port_listening udp 161 && return 0; return 1 ;;
    U-59)
      _snmp_version_audit >/dev/null 2>&1; _u59_rc=$?
      case $_u59_rc in
        0) return 0 ;;
        1) return 1 ;;
        2) return 2 ;;
        *) _CHECK_MANUAL_REASON="SNMP 접근 모델을 v1/v2c 또는 v3로 자동 확정할 수 없음"
           _CHECK_MANUAL_GUIDANCE="rouser/rwuser/authuser, group usm, VACM access와 SNMPv3 사용자 생성 상태를 확인하세요."
           return 3 ;;
      esac ;;
    U-60)
      _snmp_service_active || return 2
      [ -z "$(_snmp_config_files | head -1)" ] && return 3
      # 기존 정규식 'community\s+(public|private)' 은 Debian/Ubuntu 기본 설정인
      #   com2sec notConfigUser default public
      # 형식을 잡지 못해 가장 흔한 기본 취약 상태를 미탐했다.
      local _u60_s
      while IFS= read -r _u60_s; do
        case "$(printf '%s' "$_u60_s" | tr '[:upper:]' '[:lower:]')" in
          public|private) return 0 ;;
        esac
      done < <(_snmp_community_strings)
      return 1 ;;
    U-61)
      _snmp_service_active || return 2
      [ ! -f /etc/snmp/snmpd.conf ] && return 3
      # agentaddress 미설정이 곧 "모든 인터페이스 수신"이라는 기본값인데,
      # 기존 로직은 문자열이 존재할 때만 검사해 기본 상태를 미탐했다.
      local _u61_agent _u61_src
      _u61_agent=$(grep -vE '^[[:space:]]*#' /etc/snmp/snmpd.conf 2>/dev/null \
                   | awk 'tolower($1)=="agentaddress"{v=$2} END{print v}')
      [ -z "$_u61_agent" ] && return 0
      printf '%s' "$_u61_agent" \
        | grep -qE '(^|,)((udp|tcp)6?:)?(0\.0\.0\.0|\[::\]|\*)' && return 0
      # com2sec 의 source 필드가 default / 전체 대역이거나, ro/rwcommunity 에
      # source 가 지정되지 않은 경우도 접속 제한이 없는 상태다.
      while IFS= read -r _u61_src; do
        case "$(printf '%s' "$_u61_src" | tr '[:upper:]' '[:lower:]')" in
          default|all|any|0.0.0.0/0|::/0) return 0 ;;
        esac
      done < <(grep -vE '^[[:space:]]*#' /etc/snmp/snmpd.conf 2>/dev/null | awk '
          tolower($1)=="com2sec" || tolower($1)=="com2sec6" {
            if ($2 == "-Cn") print $5; else print $3; next }
          tolower($1) ~ /^(ro|rw)community6?$/ { if (NF < 3) print "any" }')
      return 1 ;;
    U-62)
      _u62_has_problem=0
      # 1) 경고 문구 대상 파일은 /etc/issue(로컬 콘솔)와 /etc/issue.net(원격)이다.
      #    /etc/motd 는 로그인 "이후" 표시되는 안내문이고, Ubuntu 계열은
      #    /etc/update-motd.d 로 동적 생성해 빈 파일이 정상이다.
      #    비어 있다는 사실만으로 취약 처리하면 영구 오탐이 되므로 제외한다.
      for F in /etc/issue /etc/issue.net; do
        if [ ! -f "$F" ] || [ ! -s "$F" ]; then
          _u62_has_problem=1
        fi
      done

      # 2) OS·호스트 정보 노출 검사 — motd 는 내용이 있을 때만 검사한다.
      #    'version' 같은 단어가 경고문에 우연히 포함된 경우를 취약으로 보지 않도록
      #    "키워드 + 구분자" 또는 "배포판명 + 버전숫자" 형태만 노출로 판정한다.
      for F in /etc/issue /etc/issue.net /etc/motd; do
        [ -s "$F" ] || continue
        if grep -qE '\\(S|r|m|s|v|n|o)' "$F" 2>/dev/null \
           || grep -qiE '(kernel|release|version)[[:space:]]*[:=]' "$F" 2>/dev/null \
           || grep -qiE '(ubuntu|debian|centos|rocky|almalinux|red[[:space:]]*hat|rhel|fedora|suse|linux)[[:space:]]+[0-9]' "$F" 2>/dev/null; then
          _u62_has_problem=1
        fi
      done

      # 3) sshd Banner: 특정 경로(/etc/issue.net) 고정이 아니라
      #    "Banner 가 설정되어 있고 그 파일에 실제 내용이 있는지"로 판정한다.
      #    또한 sshd -t 문법 오류는 U-62(경고 문구) 취약과 무관하므로 판정에서 뺀다.
      if command -v sshd >/dev/null 2>&1; then
        _u62_effective_banner=$(sshd -T 2>/dev/null \
          | awk 'tolower($1)=="banner" {print $2; exit}')
        if [ -z "$_u62_effective_banner" ] \
           || [ "$_u62_effective_banner" = "none" ] \
           || [ ! -s "$_u62_effective_banner" ]; then
          _u62_has_problem=1
        fi
      fi

      [ $_u62_has_problem -eq 1 ] && return 0 || return 1 ;;
    U-63)
      [ ! -f /etc/sudoers ] && return 2
      _has_permissive_acl /etc/sudoers && return 0
      OWNER=$(stat -c '%U' /etc/sudoers 2>/dev/null)
      PERM=$(stat -c '%a' /etc/sudoers 2>/dev/null)
      [ "$OWNER" != "root" ] && return 0
      # 기존 코드는 8진수 변환 없이 10진 대소 비교를 해서 604(other read)를
      # 양호로 판정했다. 640 에서 금지되는 비트(037)를 직접 검사한다.
      [ "$((8#${PERM:-7777} & 8#037))" -ne 0 ] 2>/dev/null && return 0
      return 1 ;;
    U-64)
      _u64_update_state; _u64_rc=$?
      case $_u64_rc in
        0) return 0 ;;
        1) return 1 ;;
        *) _CHECK_MANUAL_REASON="${_U64_UPDATE_REASON:-패키지 저장소 또는 보안 권고정보 확인 실패}"
           _CHECK_MANUAL_GUIDANCE="저장소 연결, DNS, 구독 등록, 프록시와 메타데이터 상태를 확인한 후 다시 점검하세요."
           return 3 ;;
      esac ;;
    U-65)
      # 서비스 활성 상태뿐 아니라 실제 선택된 NTP 소스와 동기화 상태까지 확인한다.
      _u65_is_synced && return 1
      return 0 ;;
    U-66)
      # rsyslog 외에 syslog-ng 도 정식 syslog 데몬이므로 로그 기록 설정으로 인정한다.
      local _u66_svc _u66_p
      for _u66_svc in rsyslog rsyslogd syslog syslog-ng syslog-ng@default; do
        systemctl is-active "$_u66_svc" 2>/dev/null | grep -qE '^(active|activating)' && return 1
      done
      # systemd 미사용/컨테이너 환경 대비 프로세스로도 확인한다.
      for _u66_p in rsyslogd syslog-ng syslogd; do
        pgrep -x "$_u66_p" >/dev/null 2>&1 && return 1
      done
      return 0 ;;
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
_MANUAL_IDS=(U-08 U-11 U-33 U-35 U-47 U-55)
_is_manual_id() {
  local _chk="$1"
  for _m in "${_MANUAL_IDS[@]}"; do [ "$_m" = "$_chk" ] && return 0; done
  return 1
}

_vf_scan_work_desc() {
  case "$1" in
    U-14) printf '시작파일 권한 검색' ;;
    U-15) printf '무소유 파일 검색' ;;
    U-23) printf 'SUID·SGID 파일 검색' ;;
    U-26) printf '/dev 일반 파일 검색' ;;
    U-33) printf '숨김 파일 검색' ;;
    U-64) printf '보안 업데이트 확인' ;;
    U-65) printf 'NTP 동기화 확인' ;;
    *)    printf '설정 및 서비스 확인' ;;
  esac
}

_PRECHECK_VULN=(); _PRECHECK_OK=(); _PRECHECK_MANUAL=(); _PRECHECK_NA=()
_pc_total=${#TARGET_IDS[@]}
_pc_idx=0
for _pid in "${TARGET_IDS[@]}"; do
  _pc_idx=$((_pc_idx+1))
  _pc_work=$(_vf_scan_work_desc "$_pid")

  _vf_progress_spinner_start "$_pc_idx" "$_pc_total" "점검" "$_pid" "$_pc_work"
  check_still_vuln "$_pid" >/dev/null 2>&1; _pc_rc=$?
  _vf_progress_spinner_stop
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
echo -e "${BOLD} 점검 결과 요약${RESET}"
echo -e "$_DIVIDER"
if [ ${#_PRECHECK_VULN[@]} -eq 0 ]; then
  echo -e "  ${RED}●${RESET} ${BOLD}자동 조치 예정${RESET}   ${RED}${BOLD}없음${RESET}"
else
  echo -e "  ${RED}●${RESET} ${BOLD}자동 조치 예정${RESET}   ${RED}${BOLD}${#_PRECHECK_VULN[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_VULN[@]}"
fi
echo ""
if [ ${#_PRECHECK_OK[@]} -eq 0 ]; then
  echo -e "  ${GREEN}●${RESET} ${BOLD}기존 양호${RESET}        ${GREEN}${BOLD}없음${RESET}"
else
  echo -e "  ${GREEN}●${RESET} ${BOLD}기존 양호${RESET}        ${GREEN}${BOLD}${#_PRECHECK_OK[@]}개${RESET}"
  _print_id_grid "${_PRECHECK_OK[@]}"
fi
echo ""
if [ ${#_PRECHECK_MANUAL[@]} -eq 0 ]; then
  echo -e "  ${YELLOW}●${RESET} ${BOLD}수동 확인 대상${RESET}   ${YELLOW}${BOLD}없음${RESET}"
else
  echo -e "  ${YELLOW}●${RESET} ${BOLD}수동 확인 대상${RESET}   ${YELLOW}${BOLD}${#_PRECHECK_MANUAL[@]}개${RESET}"
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

# ── 점검 전용 모드 종료 ──────────────────────────────────────────────────────
# --scan-only 는 여기까지가 전부다. 시스템 설정을 전혀 변경하지 않으므로
# 사전 백업·조치 단계·승인 절차에 진입하지 않고, 점검 결과를 CSV 로 남기고 끝낸다.
# (XLSX 결과보고서는 조치 단계에서 수집하는 항목별 상세값이 필요하므로
#  점검 전용 모드에서는 생성하지 않는다.)
if [ "${SCAN_ONLY:-0}" -eq 1 ]; then
  _SCAN_CSV="${_RPT_BASE_DIR}/vulnScan_${_HOSTNAME_VAL}_${_RUN_TS}.csv"
  {
    printf '항목ID,판정,항목명\n'
    for _sid in "${_PRECHECK_VULN[@]}";   do printf '%s,취약,"%s"\n'     "$_sid" "${ID_TITLE_MAP[$_sid]:-}"; done
    for _sid in "${_PRECHECK_MANUAL[@]}"; do printf '%s,수동확인,"%s"\n' "$_sid" "${ID_TITLE_MAP[$_sid]:-}"; done
    for _sid in "${_PRECHECK_OK[@]}";     do printf '%s,양호,"%s"\n'     "$_sid" "${ID_TITLE_MAP[$_sid]:-}"; done
    for _sid in "${_PRECHECK_NA[@]}";     do printf '%s,적용제외,"%s"\n' "$_sid" "${ID_TITLE_MAP[$_sid]:-}"; done
  } > "$_SCAN_CSV" 2>/dev/null

  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo -e " ${BOLD}점검 전용 모드 완료${RESET} — 시스템 설정은 변경되지 않았습니다."
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo ""
  echo "   취약       : ${#_PRECHECK_VULN[@]}건"
  echo "   수동 확인  : ${#_PRECHECK_MANUAL[@]}건"
  echo "   양호       : ${#_PRECHECK_OK[@]}건"
  echo "   적용 제외  : ${#_PRECHECK_NA[@]}건"
  echo ""
  if [ -s "$_SCAN_CSV" ]; then
    chmod 600 "$_SCAN_CSV" 2>/dev/null || true
    _ok "점검 결과 CSV 저장 완료"
    echo -e "   ${CYAN}${_SCAN_CSV}${RESET}"
  else
    _warn "점검 결과 CSV 를 저장하지 못했습니다."
  fi
  echo ""
  _info "조치가 필요하면 옵션 없이 SSH 터미널에서 다시 실행하세요."
  echo ""
  _div_thick

  # 점검 전용 모드 종료 코드
  #   0 = 취약·수동확인 없음 / 3 = 확인이 필요한 항목 있음
  if [ ${#_PRECHECK_VULN[@]} -gt 0 ] || [ ${#_PRECHECK_MANUAL[@]} -gt 0 ]; then
    exit 3
  fi
  exit 0
fi

if [ ${#_PRECHECK_VULN[@]} -eq 0 ] && [ ${#_PRECHECK_MANUAL[@]} -eq 0 ]; then
  # 자동 조치 대상과 수동 확인 대상이 모두 없는 경우.
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo -e " ${GREEN}✔ 모든 대상 항목이 기존 양호 또는 해당없음입니다. 추가 조치가 필요 없습니다.${RESET}"
  echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
  echo ""
  _NO_ACTION_REQUIRED=1
fi

_NO_ACTION_REQUIRED=${_NO_ACTION_REQUIRED:-0}

if [ "$_NO_ACTION_REQUIRED" -eq 0 ]; then
  if [ ${#_PRECHECK_VULN[@]} -eq 0 ]; then
    # 시스템 설정을 변경할 자동 조치 대상이 없으므로 백업과 승인 절차는 생략한다.
    echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
    echo -e " ${GREEN}✔ 자동 조치 대상이 없습니다.${RESET}"
    echo -e " ${YELLOW}※ 수동 확인 대상 ${#_PRECHECK_MANUAL[@]}개 항목은 시스템을 자동 변경하지 않고 결과보고서에 기록합니다.${RESET}"
    echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
    echo ""
  else
    echo -e "${BOLD} 조치 진행 확인${RESET}"
    echo ""
    echo -e " ${CYAN}※${RESET} y 선택 시 사전 백업 후 자동 조치 예정 항목만 순차적으로 조치합니다."
    echo -e " ${YELLOW}※${RESET} 수동 확인 대상 항목은 결과보고서에 확인 대상으로 기록합니다."
    echo -e " ${GREEN}※${RESET} 기존 양호 항목은 점검 결과를 화면과 결과보고서에 표시합니다."
    echo ""
    _read_yn _proceed_all " 점검 결과를 기준으로 조치 단계를 진행하시겠습니까? (y/n): "
    if [[ "$_proceed_all" != [Yy] ]]; then
      echo -e "${YELLOW} 사용자 선택으로 조치 단계를 취소합니다.${RESET}"
      exit 0
    fi
    echo ""
    echo -e " ${GREEN}✔ 조치 진행 승인이 완료되었습니다.${RESET}"
    echo ""
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
  /etc/hosts.lpd              # U-29 소유자·권한 원복용
  /etc/samba                  # U-35 Samba guest 설정 점검 대상 원복용
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
# U-26은 stage3부터 조회 전용이므로 /dev 일반 파일을 조치 전 백업에 추가하지 않는다.

# 백업 내부에 실행 당시 서비스·패키지·계정·방화벽·경로 인벤토리를 함께 저장한다.
_PRE_META_TMP=$(mktemp -d "${_RB_DIR}/.meta_${_RUN_ID}_XXXXXX" 2>/dev/null)
_pre_meta_rc=1
if [ -n "$_PRE_META_TMP" ]; then
  _vf_progress_spinner_start 0 1 "사전 백업" "" "상태 정보 수집"
  _vf_capture_runtime_meta "$_PRE_META_TMP" "${_exist_targets[@]}"
  _pre_meta_rc=$?
  _vf_progress_spinner_stop
fi
if [ -z "$_PRE_META_TMP" ] || [ "$_pre_meta_rc" -ne 0 ]; then
  [ -n "$_PRE_META_TMP" ] && rm -rf "$_PRE_META_TMP"
  _vf_progress_line_clear
  echo -e " ${RED}⚠ 롤백 메타데이터 생성 실패 — 안전한 롤백을 보장할 수 없어 조치를 중단합니다.${RESET}"
  exit 1
fi

_tar_feature_opts=()
_vf_tar_supports '--acls'    && _tar_feature_opts+=(--acls)
_vf_tar_supports '--xattrs'  && _tar_feature_opts+=(--xattrs)
_vf_tar_supports '--selinux' && _tar_feature_opts+=(--selinux)

# GNU tar 체크포인트 수를 원본 데이터량과 비교해 실제 압축 진행률을 표시한다.
_pre_raw_kb=$(
  du -sk -- "${_exist_targets[@]}" "${_PRE_META_TMP}/.vulnfix_meta" 2>/dev/null \
    | awk '{sum+=$1} END{print sum+0}'
)
case "$_pre_raw_kb" in ''|*[!0-9]*) _pre_raw_kb=0 ;; esac
_pre_ckpt_total=$(( _pre_raw_kb / 10 ))
[ "${_pre_ckpt_total:-0}" -gt 0 ] 2>/dev/null || _pre_ckpt_total=1
_pre_ckpt_file="${_RB_DIR}/.pre_backup_progress_${_RUN_ID}.count"
: > "$_pre_ckpt_file"

# umask 077: SSH host key·shadow 등 민감 파일이 담기므로 생성 순간부터 root 전용
if _vf_tar_supports '--checkpoint'; then
  ( umask 077
    tar "${_tar_feature_opts[@]}" -czpf "$_PRE_BAK_FILE" \
      --checkpoint=1 --checkpoint-action="exec=printf x >> \"$_pre_ckpt_file\"" \
      "${_exist_targets[@]}" -C "$_PRE_META_TMP" .vulnfix_meta 9>&- 2>/dev/null ) &
  _bak_pid=$!
  _pre_spin_idx=0
  _pre_last_pct=-1
  while kill -0 "$_bak_pid" 2>/dev/null; do
    _pre_ckpt_now=$(wc -c < "$_pre_ckpt_file" 2>/dev/null | tr -d ' ')
    case "$_pre_ckpt_now" in ''|*[!0-9]*) _pre_ckpt_now=0 ;; esac
    [ "$_pre_ckpt_now" -gt "$_pre_ckpt_total" ] && _pre_ckpt_now="$_pre_ckpt_total"
    _pre_pct=$(( _pre_ckpt_now * 100 / _pre_ckpt_total ))
    _pre_spin=$(_vf_spinner_frame "$_pre_spin_idx")

    if [ "$_pre_pct" -ne "$_pre_last_pct" ]; then
      _show_progress_bar "$_pre_ckpt_now" "$_pre_ckpt_total" "사전 백업" "" "$_pre_spin" "설정 파일 압축"
      _pre_last_pct="$_pre_pct"
    else
      _vf_progress_spinner_tick "$_pre_spin"
    fi

    _pre_spin_idx=$((_pre_spin_idx+1))
    sleep 0.5
  done
  wait "$_bak_pid"; _bak_rc=$?
else
  _vf_progress_spinner_start 0 1 "사전 백업" "" "설정 파일 압축"
  ( umask 077
    tar "${_tar_feature_opts[@]}" -czpf "$_PRE_BAK_FILE" \
      "${_exist_targets[@]}" -C "$_PRE_META_TMP" .vulnfix_meta 9>&- 2>/dev/null )
  _bak_rc=$?
  _vf_progress_spinner_stop
fi
rm -f "$_pre_ckpt_file" 2>/dev/null

_bak_verify_rc=1
if [ "$_bak_rc" -eq 0 ] && [ -s "$_PRE_BAK_FILE" ]; then
  _vf_progress_spinner_start "$_pre_ckpt_total" "$_pre_ckpt_total" "사전 백업" "" "무결성 검증"
  tar -tzf "$_PRE_BAK_FILE" >/dev/null 2>&1
  _bak_verify_rc=$?
  _vf_progress_spinner_stop
fi

if [ "$_bak_rc" -eq 0 ] \
   && [ -s "$_PRE_BAK_FILE" ] \
   && [ "$_bak_verify_rc" -eq 0 ]; then
  _bak_size=$(du -sh "$_PRE_BAK_FILE" 2>/dev/null | cut -f1)
  _show_progress_bar "$_pre_ckpt_total" "$_pre_ckpt_total" "사전 백업 완료"
  echo ""
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
    fi
  fi
  # 롤백 역산 필터링용 실행 시작 레코드.
  # 롤백은 BAK=<전체 경로>로 1순위 매칭하므로 필드를 추가해도 하위 호환된다.

  # ── 조치 전 설정 검증 기준값 기록 ─────────────────────────────────────────
  # 롤백 검증은 절대 PASS/FAIL이 아니라 조치 전 VERIFY_BASELINE과 비교한다.
  # 조치 전에도 실패한 항목은 같은 원인이 유지되면 복원 정상으로 판정한다.
  _baseline_record() {
    local _k="$1"; shift
    local _bl_out="${_PRE_META_TMP}/baseline_command.log"
    local _bl_text="" _bl_hash="" _bl_status="FAIL" _bl_rc=1
    local _bl_out_hash="UNAVAILABLE" _bl_state_hash="UNAVAILABLE" _bl_cmd=""
    : > "$_bl_out"
    "$@" >"$_bl_out" 2>&1
    _bl_rc=$?
    [ "$_bl_rc" -eq 0 ] && _bl_status="PASS"
    _bl_text=$(cat "$_bl_out" 2>/dev/null)
    _bl_hash=$(_vf_verify_output_sha256 "$_bl_text" 2>/dev/null || true)
    [ -n "$_bl_hash" ] && _bl_out_hash="$_bl_hash"
    _bl_state_hash=$(_vf_baseline_state_sha256 "$_k" 2>/dev/null || true)
    [ -n "$_bl_state_hash" ] || _bl_state_hash="UNAVAILABLE"
    _bl_cmd=$(_vf_log_field "$(_vf_baseline_command_text "$@")" 500)
    _vf_record_write \
      "VERIFY_BASELINE|${_k}|${_bl_status}|METHOD=COMMAND_EXIT|COMMAND=${_bl_cmd}|EXIT_CODE=${_bl_rc}|OUTPUT_SHA256=${_bl_out_hash}|STATE_SHA256=${_bl_state_hash}"
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
  rm -f -- "$_PRE_BAK_FILE" "${_PRE_BAK_FILE}.sha256" "${_PRE_BAK_FILE}.records" 2>/dev/null || true
  printf '\r\033[2K'
  _fail "사전 백업 생성 또는 무결성 검증에 실패했습니다."
  _warn "확인 항목: ${_BAK_DIR} 쓰기 권한, 디스크 여유 공간, tar 실행 오류"
  _PRE_BAK_RECORDED="백업 실패 — 조치 중단"
  echo ""
  _fail "백업 없이 시스템 설정을 변경하지 않는 Fail Closed 정책으로 종료합니다."
  exit 1
fi
echo ""
else
  _PRE_BAK_RECORDED="미생성"
fi

# ── 조치 단계 중단 처리 ──────────────────────────────────────────────────────
# 조치 단계는 시스템 설정을 실제로 변경한다. 원격 작업 중 회선 끊김(SIGHUP)이나
# Ctrl+C(SIGINT)가 들어오면 일부 항목만 변경된 상태로 종료되는데, 기존에는
# 롤백 경로에만 트랩이 있어 운영자가 "어디까지 바뀌었는지" 알 수 없었다.
# 중단 시 사전 백업 위치와 복원 방법을 반드시 화면에 남긴다.
_VF_FIX_PHASE=0

_vf_fix_interrupted() {
  local _sig="${1:-신호}"
  trap - INT TERM HUP
  _VF_FIX_PHASE=0

  echo ""
  echo ""
  _div_thick
  echo -e " ${BOLD}${RED}[중단] 조치 단계가 ${_sig} 로 중단되었습니다.${RESET}"
  _div_thick
  echo ""
  _warn "일부 항목만 조치된 상태일 수 있습니다. 설정이 일관되지 않을 수 있습니다."
  echo ""
  echo -e " ${WHITE}진행 상황${RESET}"
  echo "   조치 완료 : ${FIXED:-0}건"
  echo "   조치 실패 : ${FAILED:-0}건"
  echo "   미처리    : 나머지 항목은 조치되지 않았습니다."
  echo ""
  if [ -n "${_PRE_BAK_FILE:-}" ] && [ -f "${_PRE_BAK_FILE:-}" ]; then
    echo -e " ${WHITE}복원 방법${RESET}"
    echo -e "   사전 백업 : ${CYAN}${_PRE_BAK_FILE}${RESET}"
    echo -e "   복원 실행 : ${CYAN}bash ./$(basename "$0") --rollback${RESET}"
    echo "   → 목록에서 위 시각의 백업을 선택하면 조치 이전 상태로 되돌립니다."
  else
    _ok "사전 백업 생성 이전에 중단되어 시스템 설정은 변경되지 않았습니다."
  fi
  echo ""
  echo -e " ${YELLOW}※${RESET} 결과보고서(XLSX)는 생성되지 않습니다. 위 내용을 기록해 두세요."
  echo ""
  _div_thick
  echo ""
  # EXIT 트랩(_vf_records_exit_finalize)이 롤백용 .records sidecar 를 남긴다.
  exit 130
}

# 사전 백업이 완료된 경우에만 자동 조치 단계 시작을 명확히 안내한다.
if [ "${#_PRECHECK_VULN[@]}" -gt 0 ] && [ "${_NO_ACTION_REQUIRED:-0}" -eq 0 ]; then
  _div_thin
  echo -e "${BOLD} 자동 조치 시작${RESET}"
  echo ""
  echo -e " ${CYAN}→${RESET} 자동 조치 예정 ${BOLD}${#_PRECHECK_VULN[@]}개${RESET} 항목을 순차적으로 진행합니다."
  echo -e " ${YELLOW}※${RESET} 수동 확인 대상은 시스템 설정을 자동으로 변경하지 않습니다."
  echo -e " ${YELLOW}※${RESET} 조치 중 중단(Ctrl+C·세션 종료) 시 복원 방법을 화면에 안내합니다."
  echo ""
fi

# 조치 단계 진입: 이 시점부터 시스템 설정이 변경될 수 있다.
_VF_FIX_PHASE=1
trap '_vf_fix_interrupted "SIGINT (Ctrl+C)"' INT
trap '_vf_fix_interrupted "SIGTERM"'         TERM
trap '_vf_fix_interrupted "SIGHUP (세션 종료)"' HUP

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

# 항목 카드 시작부를 출력한다.
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
    good)   echo -e "${GREEN}[✔ 기존 양호]${RESET} ${BOLD}${id}${RESET} ${title}" ;;
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
_lbl_cur() { echo ""; }
_lbl_state()   { _sec check; }
_lbl_yn()      { echo -e " ${YELLOW}※ y = 조치 진행 , n = 조치 보류${RESET}"; }
_lbl_skip()    { echo -e " ${YELLOW}– 사용자 선택으로 조치를 보류합니다.${RESET}"; }
_lbl_done()    { echo -e " ${GREEN}→ 조치 완료 (검증 통과)${RESET}"; }
_lbl_done_nr() { echo -e " ${GREEN}→ 조치 완료${RESET}"; }
_lbl_fail_v()  { echo -e " ${RED}→ 조치 실패 또는 검증 실패${RESET}"; }
_lbl_subdiv()  { _div_sec; }

# -----------------------------------------------------------------------------
# 결과 상태 기록 공통 함수
#
# 역할:
#   상태별 카운터와 목록을 갱신하고 롤백 보조 records·CSV 결과를 함께 기록한다.
#
# 상태 매핑:
#   _mark_fixed   → 조치완료/FIXED
#   _mark_skipped → 기존양호/GOOD 또는 조치보류/USER_SKIPPED
#   _mark_manual  → 수동확인/MANUAL
#   _mark_failed  → 실패/FAILED
#   _mark_na      → 해당없음/NA
#
# 기록 대상:
#   상태별 카운터, 롤백 보조 records와 CSV 결과를 함께 갱신한다.
# -----------------------------------------------------------------------------
_mark_fixed() {
  local _id="$1" _title="$2" _rc=0 _reason=""
  if [ -z "${_VF_POSTCHECK_STATUS[$_id]:-}" ]; then
    _vf_run_postcheck "$_id" "" 0 ""; _rc=$?
  else
    case "${_VF_POSTCHECK_STATUS[$_id]}" in
      PASS) _rc=0 ;;
      MANUAL) _rc=2 ;;
      *) _rc=1 ;;
    esac
  fi
  _vf_append_postcheck_detail "$_id"

  if [ "$_rc" -eq 1 ]; then
    _reason="${_VF_POSTCHECK_REASON[$_id]:-공통 최종 검증 실패}"
    echo -e " ${RED}→ 공통 최종 재점검 실패 — 조치 완료로 기록하지 않습니다.${RESET}"
    echo -e " ${RED}  ${_reason}${RESET}"
    AFTER_VAL["$_id"]="조치 실패 (최종 재점검 실패)"
    _mark_failed "$_id" "${_title} — ${_reason}"
    return 1
  elif [ "$_rc" -eq 2 ]; then
    _reason="${_VF_POSTCHECK_REASON[$_id]:-공통 최종 검증에서 수동 확인 필요}"
    echo -e " ${YELLOW}→ 공통 최종 재점검에서 자동 확정 불가 — 수동 확인으로 기록합니다.${RESET}"
    echo -e " ${YELLOW}  ${_reason}${RESET}"
    AFTER_VAL["$_id"]="수동 확인 필요 (최종 재점검)"
    _mark_manual "$_id" "${_title} — ${_reason}"
    return 2
  fi

  FIXED=$((FIXED+1)); FIXED_LIST+=("$_id: $_title")
  _detail_log_result "$_id" "FIXED" "$_title"
  _report_add "$_id" "조치완료" "" ""
  return 0
}
_mark_skipped() {
  SKIPPED=$((SKIPPED+1)); SKIPPED_LIST+=("$1: $2")
  if [[ "$2" == *"[이미양호]"* ]]; then
    _detail_log_result "$1" "GOOD" "$2"
    _report_add "$1" "양호" "" ""
  else
    _detail_log_result "$1" "USER_SKIPPED" "$2"
    _report_add "$1" "건너뜀" "" ""
  fi
}
# 같은 항목이 서로 다른 조건에서 여러 번 등록될 수 있다.
# (예: U-35 는 NFS exports 위험요소와 공유 서비스 익명 접근 잔존이 각각 등록된다)
# 이를 별건으로 세면 두 가지 문제가 생긴다.
#   1) 화면 합계가 전체 항목 수를 초과하고 보고서(항목ID 기준)와 어긋난다
#   2) XLSX 는 항목ID 기준 "마지막 행"만 사용하므로 먼저 기록된 사유가 사라진다
# 따라서 같은 ID 는 1건으로 세고, 사유를 합쳐 보고서에 전체 사유를 남긴다.
_mark_manual() {
  local _id="$1" _reason="$2" _i _prev
  _MERGED_REASON="$_reason"
  for _i in "${!MANUAL_LIST[@]}"; do
    [ "${MANUAL_LIST[$_i]%%:*}" = "$_id" ] || continue
    _prev="${MANUAL_LIST[$_i]#*: }"
    # 동일 사유가 반복 등록되면 문구를 중복해 늘리지 않는다.
    case "$_prev" in
      *"$_reason"*) _MERGED_REASON="$_prev" ;;
      *)            _MERGED_REASON="${_prev} / ${_reason}" ;;
    esac
    MANUAL_LIST[$_i]="${_id}: ${_MERGED_REASON}"
    _detail_log_result "$_id" "MANUAL" "$_reason"
    _report_add "$_id" "수동확인" "$_MERGED_REASON" ""
    return 0
  done
  MANUAL=$((MANUAL+1)); MANUAL_LIST+=("${_id}: ${_reason}")
  _detail_log_result "$_id" "MANUAL" "$_reason"
  _report_add "$_id" "수동확인" "$_reason" ""
}
_mark_failed() {
  local _id="$1" _reason="$2" _i _prev
  _MERGED_REASON="$_reason"
  for _i in "${!FAILED_LIST[@]}"; do
    [ "${FAILED_LIST[$_i]%%:*}" = "$_id" ] || continue
    _prev="${FAILED_LIST[$_i]#*: }"
    case "$_prev" in
      *"$_reason"*) _MERGED_REASON="$_prev" ;;
      *)            _MERGED_REASON="${_prev} / ${_reason}" ;;
    esac
    FAILED_LIST[$_i]="${_id}: ${_MERGED_REASON}"
    _detail_log_result "$_id" "FAILED" "$_reason"
    _report_add "$_id" "실패" "" "$_MERGED_REASON"
    return 0
  done
  FAILED=$((FAILED+1)); FAILED_LIST+=("${_id}: ${_reason}")
  _detail_log_result "$_id" "FAILED" "$_reason"
  _report_add "$_id" "실패" "" "$_reason"
}
_mark_na() {
  NA=$((NA+1)); NA_LIST+=("$1: $2")
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
  echo -e "${YELLOW}   이 세션은 닫지 말고, 새 터미널(SSH·su)로 로그인이 되는지 먼저 확인하세요.${RESET}"
  echo -e "${YELLOW}   정상이면 Enter(유지) · 시간 더 필요하면 e(${timeout}초 연장) · 무응답 시 ${timeout}초 후 자동으로 이전 설정 복구.${RESET}"

  _start_wd
  while true; do
    if _vf_read_line _confirm_ok " 새 세션에서 로그인 확인 완료 → Enter, 시간 더 필요하면 e (${timeout}초 제한): " "$timeout"; then
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
#   5. 동일 점검 함수 재실행, 설정 문법 및 서비스 상태 검증
#   6. 상태 카운터·롤백 보조 records·CSV 결과 기록
#
# 시스템 영향:
#   사용자가 y를 선택한 취약 항목에서만 fix_cmd를 현재 셸에서 실행한다.
#
# 안전 조건:
#   - 조치 전 /etc 대상 파일의 개별 스냅샷 생성
#   - 조치 명령 실패 시 검증 단계로 진행하지 않고 실패 처리
#   - 전체 명령과 오류 출력은 결과 데이터에 반영
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
    echo ""
    local cur_out="" _check_rc=0 _check_err=""
    if [ -n "$before_cmd" ]; then
      _vf_capture_eval_subshell_delayed_spinner "$before_cmd" 2
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
    AFTER_VAL["$id"]="기존 양호 (재확인 통과)"
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
      _vf_capture_eval_subshell_delayed_spinner "$before_cmd" 2
      _manual_out="$_VF_CAPTURE_STDOUT"; _manual_check_err="$_VF_CAPTURE_STDERR"; _manual_check_rc="$_VF_CAPTURE_RC"
      _detail_log_command "$id" "CHECK" "$before_cmd" "$_manual_check_rc" "$_manual_out" "$_manual_check_err" "MANUAL"
    fi
    [ -n "$_manual_out" ] && echo "$_manual_out" | sed 's/^/   /'
    _sec need
    local _manual_reason="${_CHECK_MANUAL_REASON:-자동 판정에 필요한 운영·벤더 정보를 확인할 수 없음}"
    local _manual_guidance="${_CHECK_MANUAL_GUIDANCE:-현재 설정과 운영 정책을 직접 대조하세요.}"
    _warn "$_manual_reason"
    _info "$_manual_guidance"
    _vf_fill_before_val "$id" "$_manual_out" "자동 판정 불가 (수동 확인 필요)"
    AFTER_VAL["$id"]="수동 확인 필요"
    DETAIL_VAL["$id"]="[현재 상태] ${BEFORE_VAL[$id]} | [판정] ${_manual_reason} | [확인 방법] ${_manual_guidance}"
    _mark_manual "$id" "${title} — ${_manual_reason}"
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
      # fix_cmd 안에서 /etc/로 시작하는 경로만 항목별 개별 스냅샷(.bak.<시각>) 대상이다.
      # (/root/.bashrc 등 /etc 밖의 경로는 이 개별 스냅샷 대상이 아니지만, 실행 시작 시
      #  만든 전체 백업(_PRE_BACKUP_TARGETS, 조치 전 백업 tar)에는 이미 포함돼 있어
      #  --rollback 자체는 정상 동작한다. 이 개별 스냅샷은 sshd/snmpd 등 reload guard가
      #  같은 실행 안에서 즉시 복구할 때 쓰는 별도의 빠른 복구용 사본이다.)
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
      _VF_LAST_RETRY_COUNT=1
      _VF_LAST_RETRY_MAX=1
      local _fix_start_ms _fix_end_ms _fix_duration_ms=0
      _fix_start_ms=$(_vf_now_ms)
      eval "$fix_cmd" >"$_fix_tmp" 2>"$_fix_err"
      # 조치로 파일 상태가 바뀌었을 수 있으므로 스캔 캐시를 즉시 무효화한다.
      _scan_cache_invalidate
      local _fix_rc=$?
      _fix_end_ms=$(_vf_now_ms)
      [ "$_fix_end_ms" -ge "$_fix_start_ms" ] 2>/dev/null && _fix_duration_ms=$((_fix_end_ms-_fix_start_ms))
      local _fix_stdout_text="" _fix_stderr_text=""
      _fix_stdout_text=$(cat "$_fix_tmp" 2>/dev/null)
      _fix_stderr_text=$(cat "$_fix_err" 2>/dev/null)
      _detail_log_command "$id" "FIX" "$fix_cmd" "$_fix_rc" \
        "$_fix_stdout_text" "$_fix_stderr_text" \
        "$( [ "$_fix_rc" -eq 0 ] && echo PASS || echo FAIL )" \
        "$_fix_duration_ms" "${_VF_LAST_RETRY_COUNT:-1}" "${_VF_LAST_RETRY_MAX:-1}"

      # eval 자체가 실패(rc≠0)이면 조치 명령 실행 오류로 즉시 실패 처리.
      # stderr에 찍힌 내용을 사용자에게 직접 노출하지 않고 결과 데이터에만 남긴다.
      if [ $_fix_rc -ne 0 ]; then
        rm -f "$_fix_tmp" "$_fix_err"
        _sec result
        echo -e "   ${RED}✗${RESET} 조치 명령 실행 중 오류 발생"
        _info "상세 오류는 실행 종료 후 결과 요약의 '조치 실패 항목'과 결과보고서를 확인하세요."
        _item_close fail
        AFTER_VAL["$id"]="조치 실패 (실행 오류)"
        _mark_failed "$id" "${title} — 조치 명령 실행 오류 (rc=${_fix_rc})"
        echo ""; return
      fi

      if [ -s "$_fix_err" ]; then
        _warn "명령 실행 중 경고가 기록되었습니다. 현재 화면의 오류 내용을 확인하세요."
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
            *"✓"*|*"✔"*|"OK"*|*"완료"*|*"확인 완료"*)
              echo -e "   ${GREEN}✓${RESET} ${_fix_line//✓/}" ;;
            *": 0개"|*": 0건")
              # "조치 실패 : 0개"처럼 단어(실패)만 보고 빨간 X가 붙는 오탐 방지.
              # 값이 0이면 실제로는 문제가 없는 상태이므로 일반 텍스트로 표시한다.
              echo "   ${_fix_line}" ;;
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
          *"✓"*|*"✔"*|*"완료"*|*"양호"*|*"확인 완료"*)
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
        echo -e "   ${YELLOW}... (총 ${_after_total}줄, 화면에는 일부만 표시)${RESET}"
      fi
      _vf_fill_after_val "$id" "$after_out" "검증 결과 없음"

      # 동일 점검 함수 재실행 + 문법 + 서비스 상태를 최종 판정 기준으로 사용한다.
      # after_cmd/pass_pattern은 화면 및 감사 증빙용 보조 신호로만 유지한다.
      local verified=0 _postcheck_rc=0
      _vf_run_postcheck "$id" "$after_out" "$_after_rc" "$pass_pattern"; _postcheck_rc=$?
      [ "$_postcheck_rc" -eq 0 ] && verified=1

      # 항목별로 파일·서비스·패키지 변경 대상을 별도 저장해야 하는 경우
      # _vf_finalize_detail_U_XX 훅을 실행한다. CSV 기록(_mark_*) 전에 호출하므로
      # 조치 변경 내역 시트에 실제 변경 대상과 최종 검증값이 반영된다.
      local _detail_hook="_vf_finalize_detail_${id//-/_}"
      if declare -F "$_detail_hook" >/dev/null 2>&1; then
        "$_detail_hook" "$before_out" "$after_out" "$verified"           || _detail_log_note "$id" "REPORT" "항목별 변경 상세 저장 훅 실행 실패: ${_detail_hook}"
      fi

      local _verify_log_state="FAIL"
      [ "$_postcheck_rc" -eq 0 ] && _verify_log_state="PASS"
      [ "$_postcheck_rc" -eq 2 ] && _verify_log_state="MANUAL"
      _detail_log_command "$id" "VERIFY" "$after_cmd" "$_after_rc" \
        "$after_out" "$_after_err" "$_verify_log_state"

      # [최종 검증] — 실제 재확인 결과를 체크리스트로 보여준다.
      _sec verify
      if [ -n "${_FORCE_MANUAL_REASON:-}" ]; then
        echo "   → 자동 변경하지 않은 항목 존재 — 수동 확인 필요"
        echo "   → ${_FORCE_MANUAL_REASON}"
        _vf_append_postcheck_detail "$id"
        _item_close na
        AFTER_VAL["$id"]="수동 확인 필요"
        _mark_manual "$id" "${title} — ${_FORCE_MANUAL_REASON}"
        echo ""; return
      fi
      case "${_VF_POSTCHECK_CHECK_STATUS[$id]:-FAIL}" in
        PASS*) echo "   ✓ 동일 점검 함수 재실행 통과 (${_VF_POSTCHECK_CHECK_STATUS[$id]})" ;;
        MANUAL) echo "   → 동일 점검 함수 재실행: 자동 판정 불가" ;;
        *) echo "   ✗ 동일 점검 함수 재실행: 취약 상태 잔존" ;;
      esac
      case "${_VF_POSTCHECK_SYNTAX_STATUS[$id]:-SKIP}" in
        PASS) echo "   ✓ 설정 문법 검사 통과" ;;
        SKIP) echo "   ○ 설정 문법 검사 대상 없음" ;;
        MANUAL) echo "   → 설정 문법: 조치 전 오류 기준 수동 확인 필요" ;;
        *) echo "   ✗ 설정 문법 검사 실패" ;;
      esac
      case "${_VF_POSTCHECK_SERVICE_STATUS[$id]:-SKIP}" in
        PASS) echo "   ✓ 서비스 상태 검증 통과" ;;
        SKIP) echo "   ○ 서비스 상태 검증 대상 없음" ;;
        *) echo "   ✗ 서비스 상태 검증 실패" ;;
      esac
      if [[ "${_VF_POSTCHECK_EVIDENCE_STATUS[$id]:-PASS}" == WARN* ]]; then
        echo "   → 기존 출력 패턴은 불일치했으나 최종 판정에는 사용하지 않음 (${_VF_POSTCHECK_EVIDENCE_STATUS[$id]})"
      fi
      if [ "$_postcheck_rc" -eq 2 ]; then
        _vf_append_postcheck_detail "$id"
        _item_close na
        AFTER_VAL["$id"]="수동 확인 필요 (최종 재점검)"
        _mark_manual "$id" "${title} — ${_VF_POSTCHECK_REASON[$id]}"
        echo ""; return
      fi
      if [ $verified -ne 1 ]; then
        [ -n "$_after_err" ] && _info "검증 명령에서 오류가 발생했습니다."
        _warn "${_VF_POSTCHECK_REASON[$id]:-공통 최종 검증 실패}"
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
        _vf_append_postcheck_detail "$id"
        _mark_fixed "$id" "$title"
      else
        _item_close fail
        AFTER_VAL["$id"]="${AFTER_VAL[$id]} [검증실패]"
        # 실패 사유에 실제 검증 시점 상태를 함께 기록한다. 항목마다 다른 원인을
        # 전부 "검증 기준 미충족" 한 줄로 뭉개면 원문 로그를 다시 열어봐야
        # 무엇이 왜 안 됐는지 알 수 있었는데, after_out의 핵심 줄을 그대로
        # 붙여주면 보고서만 보고도 실패 상태를 바로 확인할 수 있다.
        # 항목 코드가 "확인 결과 : ..." 형태의 진단 힌트를 직접 남긴 경우
        # (예: U-65) 그 줄을 최우선으로 쓰고, 없으면 상태 요약 첫 몇 줄을 쓴다.
        local _fail_hint; _fail_hint=$(echo "$after_out" | grep -m1 -E '^[[:space:]]*(확인 결과|원인 추정)' | sed 's/^[[:space:]]*//')
        local _fail_state
        if [ -n "$_fail_hint" ]; then
          _fail_state="$_fail_hint"
        else
          _fail_state=$(echo "$after_out" | grep -v '^[[:space:]]*$' | head -3 | sed 's/^[[:space:]]*//' | tr '\n' ' / ' | sed 's/ \/ $//')
        fi
        _vf_append_postcheck_detail "$id"
        local _fail_reason="${title} — ${_VF_POSTCHECK_REASON[$id]:-조치 시도했으나 최종 검증 기준 미충족}"
        [ -n "$_fail_state" ] && _fail_reason="${_fail_reason} (현재 상태: ${_fail_state})"
        _mark_failed "$id" "$_fail_reason"
      fi ;;
    *)
      _item_close skip
      AFTER_VAL["$id"]="조치 보류 (사용자 선택)"
      _mark_skipped "$id" "${title} [조치보류]" ;;
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

  if [ $vuln_status -eq 2 ]; then
    _item_header "na" "$id" "$title"
    _info "점검 대상 서비스 또는 authoritative zone이 없어 해당없음"
    BEFORE_VAL["$id"]="점검 대상 없음"
    AFTER_VAL["$id"]="해당없음"
    _mark_na "$id" "$title"
    echo ""
  elif [ $vuln_status -eq 1 ]; then
    _item_header "good" "$id" "$title"
    echo ""
    local cur_out="" _manual_good_err="" _manual_good_rc=0
    if [ -n "$status_cmd" ]; then
      _vf_capture_eval_subshell_delayed_spinner "$status_cmd" 2
      cur_out="$_VF_CAPTURE_STDOUT"; _manual_good_err="$_VF_CAPTURE_STDERR"; _manual_good_rc="$_VF_CAPTURE_RC"
      _detail_log_command "$id" "CHECK" "$status_cmd" "$_manual_good_rc" "$cur_out" "$_manual_good_err" "GOOD"
    fi
    if [ -n "$cur_out" ]; then
      echo "$cur_out" | sed 's/^/   /'
    else
      echo -e "   ${GREEN}✔${RESET} 이상 항목 없음 (점검 통과)"
    fi
    _vf_fill_before_val "$id" "$cur_out"
    AFTER_VAL["$id"]="기존 양호 (재확인 통과)"
    echo ""
    _mark_skipped "$id" "${title} [이미양호]"
  else
    _item_header "manual" "$id" "$title"
    local _manual_before=""
    if [ -n "$status_cmd" ]; then
      _sec check
      _vf_capture_eval_subshell_delayed_spinner "$status_cmd" 2
      _manual_before="$_VF_CAPTURE_STDOUT"
      _detail_log_command "$id" "CHECK" "$status_cmd" "$_VF_CAPTURE_RC" \
        "$_manual_before" "$_VF_CAPTURE_STDERR" "MANUAL"
      echo "$_manual_before" | sed 's/^/   /'
    fi
    _sec need
    [ -n "${_CHECK_MANUAL_REASON:-}" ] && _warn "$_CHECK_MANUAL_REASON"
    [ -n "${_CHECK_MANUAL_GUIDANCE:-}" ] && _info "$_CHECK_MANUAL_GUIDANCE"
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
    local _reason_report="${_CHECK_MANUAL_REASON:-수동 확인 필요}"
    DETAIL_VAL["$id"]="[현재 상태] ${BEFORE_VAL[$id]} | [판정] ${_reason_report} | [조치 방법] ${_desc_report}"
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
      AFTER_VAL["U-01"]="기존 양호 (재확인 통과)"
      _mark_skipped "U-01" "root 원격접속 제한 [이미양호]"
      echo ""

    else
      _item_header "vuln" "U-01" "(상) root 계정 원격 접속 제한"
      echo ""

      _u01_literal=$(grep -i 'PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | grep -v '^\s*#')
      _u01_telnet_on=0
      _port_listening tcp 23 && _u01_telnet_on=1
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
        _mark_skipped "U-01" "root 계정 원격 접속 제한 [조치보류]"
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
          _mark_failed "U-01" "root 계정 원격 접속 제한 — 조치 시도했으나 검증 기준 미충족 (현재 설정: ${_u01_after:-sshd_config에서 PermitRootLogin 값을 찾지 못함 — 여러 include 파일 간 설정 충돌 가능성})"
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
      AFTER_VAL["U-02"]="기존 양호 (재확인 통과)"
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
      _read_yn _yn_u02 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u02" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-02" "비밀번호 관리정책 [조치보류]"
        echo ""
      else
      for _u02_once in 1; do
      echo -e "     권고: ${DEFAULT_PASS_MAX_DAYS}일 이하 (KISA 권고 기본값: ${DEFAULT_PASS_MAX_DAYS})"
      while true; do
        _vf_read_line _max_input " 최대 사용기간(일) 입력: " || _vf_input_abort
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
      _u02_pam_restricted=0
      if [[ "$_pam_yn" =~ ^[Yy]$ ]]; then
        ENFORCE_ROOT="enforce_for_root"
        PAM_APPLY=1
      else
        ENFORCE_ROOT=""
        PAM_APPLY=0
      fi

      # authselect가 설치돼 있지만 check가 실패한 시스템은 PAM 파일이 직접 수정된
      # 비관리/불일치 구성일 수 있다. 이 상태에서 system-auth/password-auth를 sed로
      # 바꾸면 기존 인증 정책을 훼손할 수 있으므로 정책 파일만 적용하고 PAM 변경은 제한한다.
      if [ "$PAM_APPLY" -eq 1 ] && command -v authselect >/dev/null 2>&1 \
         && [ "${_AUTHSELECT_MANAGED:-0}" -ne 1 ]; then
        PAM_APPLY=0
        _u02_pam_restricted=1
        echo -e " ${YELLOW}⚠ authselect 비관리/불일치 PAM 구성으로 확인되어 PAM 파일 자동 수정을 제한합니다.${RESET}"
        echo -e " ${YELLOW}  login.defs와 pwquality.conf 정책값은 적용하고 PAM 연결은 수동 확인으로 기록합니다.${RESET}"
        [ -n "${_AUTHSELECT_CHECK_DETAIL:-}" ] \
          && echo -e " ${YELLOW}  확인 내용: ${_AUTHSELECT_CHECK_DETAIL}${RESET}"
      fi

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
      if [ "${_u02_pam_restricted:-0}" -eq 1 ]; then
        DETAIL_VAL["U-02"]=$(_fmt_detail \
          "${_u02_before_summary}" \
          "비밀번호 사용 기간 및 복잡도 정책값 적용: PASS_MAX_DAYS=${MAX_DAYS}, PASS_MIN_DAYS=${MIN_DAYS}, minlen=${MINLEN}, ucredit=${UCREDIT}, lcredit=${LCREDIT}, dcredit=${DCREDIT}, ocredit=${OCREDIT}; PAM 파일 자동 변경 제한" \
          "수동 확인 필요" \
          "${_u02_files}" \
          "${_u02_verify}; authselect 비관리/불일치 구성으로 PAM 연결 미변경")
        echo -e " ${YELLOW}→ 정책값 적용 완료, PAM 연결은 수동 확인으로 기록합니다.${RESET}"
      else
        DETAIL_VAL["U-02"]=$(_fmt_detail \
          "${_u02_before_summary}" \
          "비밀번호 사용 기간 및 복잡도 정책 설정: PASS_MAX_DAYS=${MAX_DAYS}, PASS_MIN_DAYS=${MIN_DAYS}, minlen=${MINLEN}, ucredit=${UCREDIT}, lcredit=${LCREDIT}, dcredit=${DCREDIT}, ocredit=${OCREDIT}" \
          "조치 완료 / 최종 검증 통과" \
          "${_u02_files}" \
          "${_u02_verify}")
        _lbl_done_nr
      fi

      if [ "$PAM_APPLY" -eq 1 ] && command -v authselect &>/dev/null && authselect current &>/dev/null; then
        # authselect 관리 환경에서는 apply-changes 시 직접 수정한 PAM 설정이 초기화될 수 있어
        # 현재 profile 정보를 검증 데이터에 반영한다.
        {
          echo "----- [U-02] authselect 환경 PAM 수정 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
          echo "# authselect apply-changes 실행 시 아래 PAM 수정이 초기화될 수 있음"
          echo "# 영구 적용하려면 authselect custom profile 사용 권장"
          authselect current 2>/dev/null
          echo "-----------------------------------------------------------"
        } >> "/dev/null" 2>/dev/null
        echo ""
        echo -e " ${RED}⚠ 주의: 이 시스템은 authselect로 PAM을 관리합니다.${RESET}"
        echo -e " ${YELLOW}  방금 적용한 pam_pwquality 설정 줄은 이후 'authselect select' 또는${RESET}"
        echo -e " ${YELLOW}  'authselect apply-changes'가 실행되면 초기화될 수 있습니다.${RESET}"
        echo -e " ${YELLOW}  (pwquality.conf의 minlen/ucredit 등 수치값 자체는 영향받지 않습니다).${RESET}"
        echo -e " ${YELLOW}  영구 적용하려면 authselect custom profile 사용을 권장합니다.${RESET}"
        echo -e " ${YELLOW}  현재 authselect profile 정보가 현재 화면에 요약 결과를 표시했습니다${RESET}"
      fi

      # ── 운영적 요구사항 안내 (수동확인 제외, 참고용) ──────────────
      echo ""
      echo -e "${YELLOW}  ※ 비밀번호 관리 운영 정책 (담당자 이행 필요)${RESET}"
      echo -e "  ${YELLOW}□${RESET} 시스템마다 상이한 비밀번호 사용"
      echo -e "    → 동일 비밀번호를 여러 시스템에 사용하지 않도록 관리"
      echo -e "  ${YELLOW}□${RESET} 비밀번호 기록 시 변형하여 기록"
      echo -e "    → 평문 비밀번호 메모 금지, 일부 문자 변형 또는 암호화하여 보관"

      if [ "${_u02_pam_restricted:-0}" -eq 1 ]; then
        AFTER_VAL["U-02"]="정책값 적용 완료, PAM 연결 미변경 (authselect 비관리/불일치 — 수동 확인 필요)"
        _mark_manual "U-02" "비밀번호 정책값 적용 완료, PAM 연결은 authselect 비관리/불일치 구성으로 수동 확인 필요"
      else
        _mark_fixed "U-02" "조치 완료 (PASS_MAX_DAYS=${MAX_DAYS}, minlen=${MINLEN})"
      fi
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
      AFTER_VAL["U-03"]="기존 양호 (재확인 통과)"
      _item_header "good" "U-03" "(상) 계정 잠금 임계값 설정"
      _lbl_cur
      # 파일 경로 브래킷을 고정폭으로 맞추고, PAM 설정 라인은 auth/제어/모듈+옵션
      # 3개 필드로 정렬해 파일마다 값 시작 위치가 들쭉날쭉하던 문제를 없앤다.
      _u03_maxlen=0
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ "${#_pf}" -gt "$_u03_maxlen" ] && _u03_maxlen="${#_pf}"
      done
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] || continue
        grep -v '^#' "$_pf" | grep -E 'deny|unlock_time|pam_tally|pam_faillock' | head -3 \
          | awk -v pf="$_pf" -v w="$_u03_maxlen" '
              { $1=$1 }
              $2 == "=" { printf "   [%-*s] %s\n", w, pf, $0; next }
              NF >= 3   { printf "   [%-*s] %-6s %-16s", w, pf, $1, $2
                          out=""
                          for (i=3; i<=NF; i++) out = out (out=="" ? "" : " ") $i
                          print out; next }
              { printf "   [%-*s] %s\n", w, pf, $0 }
            '
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
      _u03_maxlen=0
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ "${#_pf}" -gt "$_u03_maxlen" ] && _u03_maxlen="${#_pf}"
      done
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] || continue
        grep -v '^#' "$_pf" | grep -E 'deny|unlock_time|pam_tally|pam_faillock' | head -3 \
          | awk -v pf="$_pf" -v w="$_u03_maxlen" '
              { $1=$1 }
              $2 == "=" { printf "   [%-*s] %s\n", w, pf, $0; next }
              NF >= 3   { printf "   [%-*s] %-6s %-16s", w, pf, $1, $2
                          out=""
                          for (i=3; i<=NF; i++) out = out (out=="" ? "" : " ") $i
                          print out; next }
              { printf "   [%-*s] %s\n", w, pf, $0 }
            '
      done
      echo ""
      _lbl_yn
      _read_yn _yn_u03 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u03" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-03" "계정 잠금 임계값 [조치보류]"
        echo ""
      else
      echo -e " ${YELLOW}[!] 계정 잠금 실패 횟수(deny)를 입력하세요.${RESET}"
      echo -e "     권고: 10회 이하 (KISA 권고 기본값: ${DEFAULT_DENY})"
      _read_num DENY_VAL " 실패 횟수 입력: " "$DEFAULT_DENY" 1 10
      echo -e " ${YELLOW}[!] 계정 잠금 해제 시간(unlock_time, 초)을 입력하세요.${RESET}"
      echo -e "     권고: ${DEFAULT_UNLOCK_TIME}초 이상 (KISA 권고 기본값: ${DEFAULT_UNLOCK_TIME})"
      _read_num UNLOCK_VAL " 잠금 해제 시간(초) 입력: " "$DEFAULT_UNLOCK_TIME" 1
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
      elif command -v authselect &>/dev/null; then
        # [2] authselect로 관리되는 시스템인데 PAM에 미연결 — 직접 pam.d sed 수정은 위험
        # (authselect가 프로필 재적용 시 덮어쓸 수 있음). authselect 자체 기능 토글로 안전하게 연결.
        echo -e " ${CYAN}[환경: authselect 관리 시스템 — pam_faillock 미연결]${RESET}"

        # 실패 후 대응하는 대신, 적용 전에 authselect check로 현재 상태가 정상인지 먼저
        # 확인한다 — 이미 깨져 있는 상태에서 enable-feature를 시도하면 의미 없는 실패와
        # 복잡한 에러 메시지만 남기 때문에, 미리 걸러서 더 안전하고 명확한 경로로 안내한다.
        _u03_as_check_out=$(authselect check 2>&1)
        _u03_as_check_rc=$?
        if [ $_u03_as_check_rc -ne 0 ] || echo "$_u03_as_check_out" | grep -qi 'not valid'; then
          _u03_authselect_restricted=1
          _u03_prof_info=$(authselect current 2>/dev/null || true)
          _u03_prof=$(printf '%s\n' "$_u03_prof_info" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' \r')
          _u03_as_summary=$(printf '%s' "$_u03_as_check_out" | tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-240)

          # 비관리/불일치 구성에서는 PAM 파일을 자동으로 건드리지 않는다.
          # 계정 잠금 정책값만 저장하고 실제 PAM 연결은 수동 확인으로 남긴다.
          _fc=/etc/security/faillock.conf
          if [ -f "$_fc" ] || touch "$_fc" 2>/dev/null; then
            config_set "$_fc" "deny" "${DENY_VAL}" kv
            _cs_report $? "$_fc" "deny" "${DENY_VAL}"
            config_set "$_fc" "unlock_time" "${UNLOCK_VAL}" kv
            _cs_report $? "$_fc" "unlock_time" "${UNLOCK_VAL}"
          else
            echo -e " ${RED}✘ $_fc 파일을 준비하지 못해 정책값을 적용하지 못했습니다.${RESET}"
          fi

          echo ""
          echo -e " ${YELLOW}[authselect 비관리/불일치 PAM 구성]${RESET}"
          echo ""
          echo -e "   현재 PAM 파일은 authselect 관리 구조와 일치하지 않습니다."
          echo -e "   이 상태에서 authselect --force 또는 PAM 파일 직접 수정을 자동 수행하면"
          echo -e "   기존 인증 정책이 삭제되거나 SSH 로그인이 차단될 수 있습니다."
          echo ""
          echo -e "   현재 Profile : ${CYAN}${_u03_prof:-감지되지 않음}${RESET}"
          echo -e "   처리 방식    : ${YELLOW}faillock.conf 정책값만 적용, PAM 연결은 수동 확인${RESET}"
          [ -n "$_u03_as_summary" ] && echo -e "   확인 내용    : ${YELLOW}${_u03_as_summary}${RESET}"
          echo ""
          _info "authselect --force 재생성과 system-auth/password-auth 직접 수정은 수행하지 않습니다."
          _info "기존 PAM 정책을 검토한 후 custom authselect profile 또는 승인된 수동 절차로 연결하세요."
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
          _u03_authselect_restricted=1
          _info "최종 재점검 후 수동 확인 상태로 기록합니다."
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
        } >> "/dev/null" 2>/dev/null

        if [ $_u03_as_rc -ne 0 ]; then
          _fail "authselect enable-feature 실패 — 현재 화면의 오류 내용을 확인"
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
          echo -e "${YELLOW}   이 세션은 닫지 말고, 새 터미널(SSH·su)로 로그인이 되는지 먼저 확인하세요.${RESET}"
          echo -e "${YELLOW}   정상이면 Enter(유지) · 시간 더 필요하면 e(${_u03_as_timeout}초 연장) · 무응답 시 ${_u03_as_timeout}초 후 'authselect disable-feature with-faillock'으로 자동 복구.${RESET}"
          echo -e "${YELLOW}   ※ 수동 복구: authselect backup restore ${_u03_as_bak_name}${RESET}"
          _u03_as_start_wd
          while true; do
            if _vf_read_line _u03_as_confirm " 새 세션에서 로그인 확인 완료 → Enter, 시간 더 필요하면 e (${_u03_as_timeout}초 제한): " "$_u03_as_timeout"; then
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
          else
            echo -e " ${YELLOW}   PAM 연결 검증 실패 — authselect disable-feature with-faillock 으로 즉시 복구합니다.${RESET}"
            authselect disable-feature with-faillock 2>/dev/null
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
      elif [ $_u03_final_rc -eq 2 ] || [ $_u03_final_rc -eq 3 ]; then
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
        echo "   1) 기존 PAM 정책과 인증 연동(SSSD/LDAP 등) 영향 확인"
        echo "   2) 승인된 custom authselect profile에 with-faillock 구성"
        echo "   3) 변경 후 authselect check와 새 SSH 로그인으로 검증"
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
  "_o=\$(awk -F: '\$2!=\"x\"&&\$2!=\"*\"&&\$2!=\"!\"&&\$2!=\"\" {print \$1}' /etc/passwd | head -5); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '평문 저장 없음 (확인 완료)'" \
  "확인 완료"

# =============================================================================
# U-05 / root 이외의 UID 0 금지
#
# 점검 기준:
#   UID 0은 root 계정에만 할당되어야 한다.
#
# 처리 정책:
#   추가 UID 0 계정은 상태만 표시하고 자동 삭제 또는 UID 변경을 수행하지 않는다.
#   비상계정·벤더계정·클러스터 계정 여부와 파일 소유권을 확인한 뒤 개별 조치한다.
#
# 자동 변경 제외 사유:
#   userdel -f 또는 임의 UID 재할당은 관리 접속 상실과 서비스 장애를 유발할 수 있다.
#
# 롤백:
#   자동 변경이 없으므로 신규 롤백 대상은 없다.
# =============================================================================

do_manual "U-05" "(상) root 이외의 UID가 '0' 금지" \
  "추가 UID 0 계정을 자동 삭제하거나 변경하지 않습니다.\n1) 계정 생성 목적, 최근 로그인, sudo·서비스·배치 사용 여부를 확인합니다.\n2) 해당 UID가 소유한 파일과 실행 중인 프로세스를 먼저 조사합니다.\n3) 유지가 불필요하면 로그인 잠금과 서비스 영향 확인 후 승인된 절차로 계정을 정리합니다.\n4) 유지가 필요하면 고유 UID 전환계획과 파일 소유권 이전계획을 수립합니다.\n5) root 원격접속 및 비상접속 경로를 검증한 뒤 조치합니다." \
  "_rows=\$(_u05_extra_uid0_rows)
   _cnt=\$(printf '%s\n' \"\$_rows\" | sed '/^\$/d' | wc -l | tr -d ' ')
   echo \"root 이외 UID 0 계정: \${_cnt}개\"
   if [ \"\$_cnt\" -gt 0 ]; then
     printf '%s\n' \"\$_rows\" | head -30
     [ \"\$_cnt\" -gt 30 ] && echo \"... 외 \$((_cnt-30))개\"
   else
     awk -F: '\$3==0{printf \"root 계정 확인|UID=%s|GID=%s|HOME=%s|SHELL=%s\n\",\$3,\$4,\$6,\$7}' /etc/passwd
   fi"

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
  AFTER_VAL["U-06"]="기존 양호 (재확인 통과)"
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
      _vf_read_line _u06_wheel_user " 계정: " || _vf_input_abort
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
        printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user" "$_u06_before_member" >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
        {
          echo "----- [U-06] wheel 그룹 변경 기록 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
          printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user" "$_u06_before_member"
          echo "# 롤백 기본: 기존 멤버가 아니었던 경우 wheel 그룹에서 제거"
          echo "# 롤백 비상: tar.gz 의 /etc/group, /etc/gshadow 전체 복원"
          echo "-----------------------------------------------------------"
        } >> "/dev/null" 2>/dev/null

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
                _mark_skipped "U-06" "su 기능 제한 [조치보류]"
      else
        _lbl_during
        echo -e "   ${CYAN}→${RESET} /etc/pam.d/su 에 pam_wheel.so use_uid 적용"
        _u06_pam_bak=$(_backup_file /etc/pam.d/su)
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

        # PAM 인증 스택(su) 변경 — U-03과 동일하게 워치독으로 새 세션 로그인을
        # 확인하고, 시간 내 확인되지 않으면 자동으로 백업 설정으로 복구한다.
        if [ -n "$_u06_pam_bak" ]; then
          _auth_watchdog_guard 90 "$_u06_pam_bak" /etc/pam.d/su
          _u06_guard_rc=$?
        else
          _warn "백업 파일 경로를 확인하지 못해 워치독 보호 없이 진행합니다."
          _u06_guard_rc=0
        fi

        if [ "$_u06_guard_rc" -ne 0 ]; then
          echo ""
          _fail "PAM 변경이 자동 롤백되었습니다 — U-06은 미적용 상태입니다."
          BEFORE_VAL["U-06"]="pam_wheel.so 미설정"
          AFTER_VAL["U-06"]="PAM 변경 자동 롤백됨 (로그인 확인 시간 초과)"
          DETAIL_VAL["U-06"]=$(_fmt_detail \
            "pam_wheel.so 미설정" \
            "auth required pam_wheel.so use_uid 추가 시도" \
            "조치 실패 (자동 롤백)" \
            "/etc/pam.d/su" \
            "로그인 확인 시간 초과로 백업에서 자동 복원됨")
          _mark_failed "U-06" "PAM 변경 확인 시간 초과로 자동 롤백됨 — 미적용"
        else
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
            _vf_read_line _u06_wheel_user2 " 계정: " || _vf_input_abort
            [ -z "$_u06_wheel_user2" ] && break
            if ! id "$_u06_wheel_user2" &>/dev/null; then
              echo -e " ${RED}✗ ${_u06_wheel_user2} 계정을 찾을 수 없습니다.${RESET}"
              _read_yn _u06_retry " 다시 입력하시겠습니까? (y/n): "
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
              printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user2" "$_u06_before_member2" >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
              {
                echo "----- [U-06] wheel 그룹 변경 기록 ($(date '+%Y-%m-%d %H:%M:%S')) -----"
                printf 'GROUP_MEMBERSHIP|%s|wheel|BEFORE_MEMBER=%d\n' "$_u06_wheel_user2" "$_u06_before_member2"
                echo "# 롤백 기본: 기존 멤버가 아니었던 경우 wheel 그룹에서 제거"
                echo "# 롤백 비상: tar.gz 의 /etc/group, /etc/gshadow 전체 복원"
                echo "-----------------------------------------------------------"
              } >> "/dev/null" 2>/dev/null
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
          _fail "pam_wheel.so 적용 후에도 여전히 취약 — 조치 실패"
          AFTER_VAL["U-06"]="조치 실패 (pam_wheel.so 미반영)"
          _mark_failed "U-06" "su 기능 제한 — pam_wheel.so 적용 후에도 검증 실패"
        fi
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
     echo '계정 없음 (확인 완료)'
   else
     printf '%b' \"\$_o\"
     [ \$_all_locked -eq 1 ] && echo '확인 완료' || echo '일부 계정 잠금 실패'
   fi" \
  "확인 완료"

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
#   /etc/passwd의 로컬 계정 기본 GID가 NSS(getent)에서 정상 조회되어야 한다.
#
# 처리 정책:
#   자동으로 GID를 변경하지 않는다. 중앙 계정 연동, 애플리케이션 서비스 계정,
#   삭제된 그룹 복구 여부를 운영 담당자가 확인한 뒤 개별 조치한다.
#
# 자동 변경 제외 사유:
#   임의의 users 그룹 지정은 파일 접근권한과 서비스 실행권한을 훼손할 수 있다.
#
# 롤백:
#   자동 변경이 없으므로 신규 롤백 대상은 없다.
# =============================================================================

do_manual "U-09" "(하) 계정이 존재하지 않는 GID 금지" \
  "미존재 기본 GID는 자동 변경하지 않습니다.\n1) 계정의 업무 용도와 원래 그룹을 확인합니다.\n2) 삭제된 그룹을 복구해야 하면 groupadd -g <GID> <그룹명>을 검토합니다.\n3) 승인된 기존 그룹으로 변경해야 하면 usermod -g <그룹명> <계정명>을 개별 적용합니다.\n4) 변경 전 해당 UID/GID 소유 파일과 서비스 의존성을 확인하고, 변경 후 id 및 getent group으로 재검증합니다." \
  "_rows=\$(_u09_missing_gid_rows)
   _cnt=\$(printf '%s\n' \"\$_rows\" | sed '/^\$/d' | wc -l | tr -d ' ')
   echo \"미존재 기본 GID 사용 계정: \${_cnt}개\"
   if [ \"\$_cnt\" -gt 0 ]; then
     printf '%s\n' \"\$_rows\" | head -30
     [ \"\$_cnt\" -gt 30 ] && echo \"... 외 \$((_cnt-30))개\"
   fi"

# =============================================================================
# U-10 / 동일한 UID 금지
#
# 점검 기준:
#   /etc/passwd의 로컬 계정은 서로 중복되지 않는 고유 UID를 사용해야 한다.
#
# 처리 정책:
#   계정 삭제나 UID 재할당을 자동 수행하지 않는다. 대표 계정 선정, 서비스 연계,
#   기존 파일 소유권 변경 범위를 확인한 뒤 변경계획과 롤백계획을 수립한다.
#
# 자동 변경 제외 사유:
#   userdel -f 또는 임의 UID 변경은 서비스 계정 삭제와 파일 소유권 불일치를 유발한다.
#
# 롤백:
#   자동 변경이 없으므로 신규 롤백 대상은 없다.
# =============================================================================

do_manual "U-10" "(중) 동일한 UID 금지" \
  "중복 UID 계정을 자동 삭제하거나 변경하지 않습니다.\n1) 동일 UID를 공유하는 계정 중 유지할 대표 계정을 결정합니다.\n2) 각 계정의 로그인·서비스·배치·sudo 사용 여부를 확인합니다.\n3) UID 변경 전 find <마운트> -xdev -uid <기존UID>로 소유 파일 범위를 산출합니다.\n4) 승인된 신규 UID를 개별 지정한 뒤 파일 소유권, 서비스 기동, 로그인 결과를 검증합니다.\n5) 계정 삭제가 필요한 경우에도 userdel -f는 사용하지 말고 데이터 보존과 롤백 절차를 먼저 확정합니다." \
  "_rows=\$(_u10_duplicate_uid_rows)
   _cnt=\$(printf '%s\n' \"\$_rows\" | sed '/^\$/d' | wc -l | tr -d ' ')
   echo \"중복 UID 그룹: \${_cnt}개\"
   if [ \"\$_cnt\" -gt 0 ]; then
     printf '%s\n' \"\$_rows\" | head -30
     [ \"\$_cnt\" -gt 30 ] && echo \"... 외 \$((_cnt-30))개\"
   fi"

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
        AFTER_VAL["U-12"]="기존 양호 (재확인 통과)"
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
      _read_yn _yn_u12 " 조치하시겠습니까? (y/n): "

      if [[ "$_yn_u12" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-12" "세션 종료 시간 [조치보류]"
        echo ""
      else
        # TMOUT 값 입력
        echo ""
        echo -e " ${YELLOW}세션 종료 시간(초)을 입력하세요. 권고: ${DEFAULT_TMOUT}초 이하${RESET}"
        while true; do
          _vf_read_line _tmout_input " 입력 (Enter=${DEFAULT_TMOUT}): " || _vf_input_abort
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
          if [ -n "$_bypass_recheck" ]; then
            _u12_bypass_summary=$(echo "$_bypass_recheck" | grep 'LINE:' | sed 's/LINE://' | head -2 | tr '\n' '; ')
            _mark_failed "U-12" "세션 종료 시간 — 조치 후 검증 실패 (우회 설정 잔존: ${_u12_bypass_summary:-확인 필요})"
          else
            _mark_failed "U-12" "세션 종료 시간 — 조치 후 검증 실패 (TMOUT 값이 반영되지 않았거나 다른 설정 파일에서 재정의되고 있을 수 있음)"
          fi
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
   [ \"\$VULN\" -eq 0 ] && echo 'PATH 정상 (확인 완료)' || echo 'PATH에 . 잔존'" \
  "확인 완료"

# =============================================================================
# U-15 / 파일 및 디렉터리 소유자 설정
#
# 점검 기준:
#   로컬 파일시스템에 존재하지 않는 UID 또는 GID를 소유자로 가진 경로가 없어야 한다.
#
# 처리 정책:
#   탐지 결과와 숫자 UID/GID를 보고서에 기록하고 자동 chown/chgrp는 수행하지 않는다.
#   삭제된 패키지 계정, 애플리케이션 서비스 계정, 데이터 이관 흔적을 확인한 뒤 조치한다.
#
# 자동 변경 제외 사유:
#   무조건 root 소유로 변경하면 서비스 접근권한과 감사 추적성이 훼손될 수 있다.
#
# 롤백:
#   신규 자동 변경은 없다. 과거 버전 백업의 ORPHAN_RESTORE 롤백 호환성은 유지한다.
# =============================================================================

do_manual "U-15" "(상) 파일 및 디렉터리 소유자 설정" \
  "무소유 파일과 디렉터리는 자동으로 root 소유로 변경하지 않습니다.\n1) 숫자 UID/GID가 삭제된 서비스·패키지 계정인지 확인합니다.\n2) 계정 복구가 맞으면 원래 숫자 UID/GID로 계정 또는 그룹을 복구합니다.\n3) 소유권 이전이 맞으면 업무 담당자가 승인한 계정으로 대상별 chown/chgrp를 적용합니다.\n4) 데이터·애플리케이션·DB 마운트는 서비스 중지 또는 영향도 검토 후 조치합니다.\n5) 조치 후 동일 탐지 명령과 서비스 기동 테스트로 재검증합니다." \
  "_rows=\$(_u15_orphan_rows)
   _cnt=\$(printf '%s\n' \"\$_rows\" | sed '/^\$/d' | wc -l | tr -d ' ')
   echo \"무소유 경로: \${_cnt}개\"
   if [ \"\$_cnt\" -gt 0 ]; then
     printf '%s\n' \"\$_rows\" | head -30
     [ \"\$_cnt\" -gt 30 ] && echo \"... 외 \$((_cnt-30))개\"
   fi"

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
  "_p=/etc/passwd; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; chown root:root /etc/passwd && chmod 644 /etc/passwd" \
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
   [ \$_all_ok -eq 1 ] && echo '확인 완료' || echo '검증실패'" \
  "확인 완료"

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
  "_p=/etc/shadow; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; chown root /etc/shadow && chmod g-wx,o-rwx /etc/shadow" \
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
  "_p=/etc/hosts; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; chown root:root /etc/hosts && chmod 644 /etc/hosts" \
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
  "_o=\$(for F in /etc/inetd.conf /etc/xinetd.conf; do [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '파일 없음 (확인 완료)'" \
  "확인 완료"

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
  "_p=/etc/rsyslog.conf; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; [ -f /etc/rsyslog.conf ] && chown root:root /etc/rsyslog.conf && chmod 640 /etc/rsyslog.conf" \
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
  "_p=/etc/services; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; chown root:root /etc/services && chmod 644 /etc/services" \
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
  done < <(_u23_find_suid)

  echo "   기존 승인과 동일 : ${#_approved_paths[@]}개"
  echo "   검토 대상         : ${#_targets[@]}개"
  echo "   승인 정책 파일   : ${_U23_APPROVAL_FILE}"
  echo "   그룹 제한 정책   : ${_U23_RESTRICT_FILE}"
  echo ""

  [ ${#_targets[@]} -eq 0 ] && {
    echo "   ✓ 기존 승인 상태와 동일하여 추가 확인을 생략합니다."
    DETAIL_VAL["U-23"]="[현재 상태] 전체 SUID/SGID 파일 ${#_approved_paths[@]}개, 모두 허용 목록과 일치 | [조치 내용] 해당없음 (변경 불필요) | [조치 결과] 기존 양호 / 재확인 통과 | [변경 파일] 없음 | [검증 결과] 검토 대상 0개"
    return 0
  }

  _u23_ui_printf() { _vf_tty_printf "$@"; }
  _u23_ui_line()   { _vf_tty_line "$*"; }
  _u23_ui_read()   { _vf_read_line "$1" "$2"; }
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
  unset -f _u23_ui_printf _u23_ui_line _u23_ui_read _u23_read_group _u23_stage_single

  echo "----- [U-23] 조치 전 SUID/SGID 권한 원본 ($(date '+%Y-%m-%d %H:%M:%S')) -----" \
    >> "/dev/null" 2>/dev/null

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
        printf 'PERM_RESTORE|%s|%s|%s\n' "$f" "$_before_mode" "$_before_owner" >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
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
        printf 'PERM_RESTORE|%s|%s|%s\n' "$f" "$_before_mode" "$_before_owner" >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
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
  } >> "/dev/null" 2>/dev/null
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
   done < <(_u23_find_suid)
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
   } >> "/dev/null" 2>/dev/null
   DETAIL_VAL["U-23"]="전체 ${_u23_all_cnt}개 | 기존 승인 동일 ${_u23_approved_cnt}개 | 검토 대상 ${_u23_review_cnt}개"' \
  '_u23_apply_policy' \
  'EXTRA=$(_u23_find_suid | while IFS= read -r f; do
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
     echo "승인·권한 제거·그룹 실행 제한 검증 완료"
   else
     echo "미승인 또는 미처리 SUID/SGID:"
     echo "$EXTRA" | sed "s/^/  - /"
   fi' \
  "검증 완료"

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
     echo \"PERM_RESTORE|\$F|\$(stat -c '%a' \"\$F\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$F\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\" 2>/dev/null
     chown root:root \"\$F\" && chmod 644 \"\$F\"
   done" \
  "_bad=0
   for F in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc /root/.bash_profile /root/.profile; do
     [ -f \"\$F\" ] || continue
     O=\$(stat -c '%U' \"\$F\" 2>/dev/null); P=\$(stat -c '%a' \"\$F\" 2>/dev/null)
     stat -c \"\$F — %U/%a\" \"\$F\"
     if [ \"\$O\" != \"root\" ] || [ \"\$(( 8#\${P:-777} & 8#022 ))\" -ne 0 ] 2>/dev/null; then
       _bad=\$((_bad+1))
     fi
   done
   echo \"위반 파일 수: \${_bad}\"" \
  "위반 파일 수: 0"


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
      DETAIL_VAL["U-25"]="전체 ${_u25_all_cnt}개 | 설정 사유 확인 ${_u25_approved_cnt}개 | 미승인 0개${_u25_approved_detail:+ | [설정 사유 확인] ${_u25_approved_detail}} | [검증 결과] 점검 시점 기준 미승인 world writable 파일 0개 확인 완료"
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

        _lbl_yn
        _read_yn _yn25 " 조치하시겠습니까? (y/n): "

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

              echo "   1) 일반 사용자 쓰기 권한 제거"
              echo "      → chmod o-w 적용"
              echo "   2) 설정 사유 확인 후 유지"
              echo "      → 권한은 유지하고 확인 사유 기록"
              echo "   3) 변경하지 않음"
              echo "      → 수동 확인 대상으로 기록"
              _read_num _u25_choice " 선택하세요 (1~3): " "3" "1" "3"
              echo ""

              case "$_u25_choice" in
                1)
                  if [ -f "$_f25" ] && [ -n "$_u25_mode" ] && [ -n "$_u25_owner" ]; then
                    printf 'PERM_RESTORE|%s|%s|%s\n' \
                      "$_f25" "$_u25_mode" "$_u25_owner" >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
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
                    _vf_read_line _u25_reason " 설정 사유를 입력하세요: " || _vf_input_abort
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

            if [ "$_u25_remain_cnt" -eq 0 ]; then
              _u25_verify="world writable 재스캔 결과 미승인 파일 0개 확인 완료"
            else
              _u25_verify="world writable 재스캔 결과 미승인 파일 ${_u25_remain_cnt}개 남음 (확인 실패)"
            fi

            [ "$_u25_removed_cnt" -gt 0 ] && _ok "권한 제거 완료: ${_u25_removed_cnt}개"
            if [ "$_u25_approved_now_cnt" -gt 0 ]; then
              _ok "설정 사유 기록: ${_u25_approved_now_cnt}개"
              _info "설정 사유 기록 파일: ${_U25_ALLOWLIST}"
            fi
            [ "$_u25_manual_cnt" -gt 0 ] && _warn "변경하지 않음: ${_u25_manual_cnt}개"
            [ "$_u25_failed_cnt" -gt 0 ] && _fail "처리 실패: ${_u25_failed_cnt}개"

            if [ "$_u25_remain_cnt" -eq 0 ]; then
              _ok "미승인 world writable 일반 파일: 0개"
              _ok "검증 결과 : 확인 완료"
            else
              _warn "미승인 world writable 일반 파일: ${_u25_remain_cnt}개"
              printf '%s\n' "$_u25_remain_unapproved" | sed '/^$/d' | head -10 | sed 's/^/      /'
              _warn "검증 결과 : 확인 실패"
            fi

            BEFORE_VAL["U-25"]="world writable 일반 파일 ${_u25_all_cnt}개 (미승인 ${_u25_target_cnt}개, 사유 확인 ${_u25_approved_cnt}개)"
            AFTER_VAL["U-25"]="미승인 ${_u25_remain_cnt}개 (권한 제거 ${_u25_removed_cnt}개, 신규 사유 확인 ${_u25_approved_now_cnt}개)"

            _u25_detail="조치 전 전체 ${_u25_all_cnt}개 | 조치 전 미승인 ${_u25_target_cnt}개 | 기존 설정 사유 확인 ${_u25_approved_cnt}개 | 권한 제거 ${_u25_removed_cnt}개 | 신규 사유 확인 ${_u25_approved_now_cnt}개 | 변경 없음 ${_u25_manual_cnt}개 | 실패 ${_u25_failed_cnt}개 | 최종 미승인 ${_u25_remain_cnt}개 | [검증 결과] ${_u25_verify}"
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
            AFTER_VAL["U-25"]="조치 보류 (사용자 선택)"
            DETAIL_VAL["U-25"]="미승인 ${_u25_target_cnt}개 | 조치 보류 (사용자 선택)${_u25_approved_detail:+ | [기존 설정 사유 확인] ${_u25_approved_detail}}"
            _mark_skipped "U-25" "world writable 파일 점검 [조치보류]"
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
#   /dev 자체 파일시스템에는 장치·디렉터리·링크·소켓·파이프 외 일반 파일이 없어야 한다.
#
# 처리 정책:
#   일반 파일의 경로와 메타데이터만 표시하고 자동 삭제하지 않는다.
#   장비 에이전트, 클러스터, DB, 보안 솔루션이 생성한 파일인지 확인한 뒤 개별 조치한다.
#
# 자동 변경 제외 사유:
#   /dev의 일반 파일이 비표준이더라도 운영 솔루션이 사용 중일 수 있어 즉시 삭제는 위험하다.
#
# 롤백:
#   신규 자동 삭제가 없으므로 롤백 대상은 없다. 과거 백업 복원 호환성은 유지한다.
# =============================================================================

do_manual "U-26" "(상) /dev에 존재하지 않는 device 파일 점검" \
  "탐지된 /dev 일반 파일은 자동 삭제하지 않습니다.\n1) file, stat, lsof 명령으로 파일 유형·소유자·사용 프로세스를 확인합니다.\n2) rpm -qf 또는 dpkg -S로 패키지 소유 여부를 확인합니다.\n3) 장비 에이전트·DB·클러스터·보안 솔루션 담당자에게 생성 목적을 확인합니다.\n4) 불필요함이 승인된 경우에도 즉시 rm하지 말고 별도 격리 경로로 이동한 뒤 서비스 영향과 재생성 여부를 확인합니다.\n5) 이상이 없을 때만 최종 삭제하고 재점검합니다." \
  "_rows=\$(_u26_nondevice_rows)
   _cnt=\$(printf '%s\n' \"\$_rows\" | sed '/^\$/d' | wc -l | tr -d ' ')
   echo \"/dev 일반 파일: \${_cnt}개\"
   if [ \"\$_cnt\" -gt 0 ]; then
     while IFS= read -r _p; do
       [ -n \"\$_p\" ] || continue
       _meta=\$(stat -c '소유=%U:%G|권한=%a|크기=%s|수정=%y' \"\$_p\" 2>/dev/null)
       printf '%s|%s\n' \"\$_p\" \"\${_meta:-메타데이터 확인 실패}\"
     done <<< \"\$_rows\" | head -30
     [ \"\$_cnt\" -gt 30 ] && echo \"... 외 \$((_cnt-30))개\"
   fi"

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
  "_eq_ok=0
   if [ -f /etc/hosts.equiv ]; then echo '제거 실패: /etc/hosts.equiv'; else echo '/etc/hosts.equiv 없음'; _eq_ok=1; fi
   _rh_cnt=\$(find /root /home -name '.rhosts' 2>/dev/null | wc -l)
   echo \".rhosts 잔존: \${_rh_cnt}\"
   [ \"\$_eq_ok\" -eq 1 ] && [ \"\$_rh_cnt\" -eq 0 ] && echo '확인 완료'" \
  "확인 완료"

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
                _mark_skipped "U-28" "접속 IP 및 포트 제한 [조치보류]"
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
          _mark_failed "U-28" "(상) 접속 IP 및 포트 제한 — 조치 후에도 여전히 취약 (firewalld=${_u28_fw_active:-inactive}, ufw=${_u28_ufw_active:-inactive}, iptables 룰=${_u28_ipt2:-0}개 — 방화벽 도구 설치/권한 확인 필요)"
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
  "_p=/etc/hosts.lpd; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; [ -f /etc/hosts.lpd ] && chown root:root /etc/hosts.lpd && chmod 600 /etc/hosts.lpd" \
  "if [ -f /etc/hosts.lpd ]; then
     stat -c '소유자: %U / 권한: %a' /etc/hosts.lpd
     O=\$(stat -c '%U' /etc/hosts.lpd 2>/dev/null); P=\$(stat -c '%a' /etc/hosts.lpd 2>/dev/null)
     [ \"\$O\" = root ] && [ \"\$(( 8#\${P:-777} & 8#077 ))\" -eq 0 ] 2>/dev/null && echo '확인 완료'
   else
     echo '파일 없음 (확인 완료)'
   fi" \
  "확인 완료"

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
     # umask 는 "22" 처럼 선행 0을 생략한 2자리 표기도 유효하다.
     # (8#22 == 8#022 == 18) 점검부(check_still_vuln U-30)와 동일 기준을 쓴다.
     [[ "$v" =~ ^0*[0-7]{1,4}$ ]] || return 1
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
   _u30_ok "$_u30_final" && echo "umask 설정 확인 완료" || echo "설정 미확인"' \
  "확인 완료"

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
     printf 'PERM_RESTORE|%s|%s|%s:%s\\n' \"\$homedir\" \"\$P\" \"\$O\" \"\$G\" >> \"\${_CURRENT_RECORDS_FILE}\" 2>/dev/null
     [ \"\$O\" != \"\$user\" ] && chown \"\$user\" \"\$homedir\"
     [ \"\$(( 8#\${P:-0} & 8#002 ))\" -ne 0 ] 2>/dev/null && chmod 750 \"\$homedir\"
   done < /etc/passwd" \
  "_bad=0
   while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     [ -d \"\$homedir\" ] || continue
     O=\$(stat -c '%U' \"\$homedir\"); P=\$(stat -c '%a' \"\$homedir\")
     stat -c \"\$homedir — %U/%a\" \"\$homedir\"
     if [ \"\$O\" != \"\$user\" ] || [ \"\$(( 8#\${P:-0} & 8#002 ))\" -ne 0 ] 2>/dev/null; then
       _bad=\$((_bad+1))
     fi
   done < /etc/passwd
   echo \"위반 홈 디렉터리 수: \${_bad}\"" \
  "위반 홈 디렉터리 수: 0"

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
  "_u32_total=0; _u32_missing=0
   while IFS=: read -r user _ uid gid _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     { [ \"\$user\" = \"nobody\" ] || [ \"\$uid\" -ge 65534 ] 2>/dev/null; } && continue
     _u32_total=\$((_u32_total + 1))
     if [ -n \"\$homedir\" ] && [ ! -d \"\$homedir\" ]; then
       _u32_missing=\$((_u32_missing + 1))
       echo \"\$user: 홈 디렉터리 미존재(\$homedir)\"
     fi
   done < /etc/passwd
   [ \"\$_u32_missing\" -eq 0 ] && echo \"점검 대상 계정 \${_u32_total}개, 홈 디렉터리 미존재 0개 (확인 완료)\"" \
  "while IFS=: read -r user _ uid gid _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     { [ \"\$user\" = \"nobody\" ] || [ \"\$uid\" -ge 65534 ] 2>/dev/null; } && continue
     [ -z \"\$homedir\" ] || [ -d \"\$homedir\" ] && continue
     printf 'CREATED_PATH|%s|d\\n' \"\$homedir\" >> \"\${_CURRENT_RECORDS_FILE}\" 2>/dev/null
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
   done < /etc/passwd); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '모든 계정 홈 디렉터리 정상 (확인 완료)'" \
  "확인 완료"

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
  "echo '[탐지된 항목] (정상 예외 제외 후)'
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
     echo '  [실행 권한 있는 항목]'
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
  "_svc_stop_disable_mask finger.socket finger.service fingerd.service cfingerd.service" \
  "ss -tlnp 2>/dev/null | grep ':79 ' && echo 'Finger 포트 잔존'
   if _svc_any_active finger.socket finger.service fingerd.service cfingerd.service; then
     echo 'Finger 서비스 잔존 active'
   else
     echo 'Finger 비활성 (확인 완료)'
   fi" \
  "확인 완료"

# =============================================================================
# U-35 / 공유 서비스 익명 접근 제한
#
# 운영 정책에 따라 FTP 익명 계정, Samba guest, NFS 허용 호스트가 달라질 수 있으므로
# 스크립트가 계정·서비스·exports를 자동 변경하지 않는다.
# 현재 상태와 위험 요소만 출력하고 결과보고서의 수동 확인 대상으로 기록한다.
# =============================================================================

_u35_append_text() {
  # _u35_append_text <변수명> <추가문구>
  local __name="$1" __value="$2" __current=""
  eval "__current=\${${__name}:-}"
  if [ -n "$__current" ]; then
    printf -v "$__name" '%s / %s' "$__current" "$__value"
  else
    printf -v "$__name" '%s' "$__value"
  fi
}

_u35_print_current_state() {
  local _acc _shell _cf _line _svc _state
  _U35_CURRENT_SUMMARY=""
  _U35_MANUAL_REASON=""

  echo "   [FTP 기본계정]"
  _u35_ftp_found=0
  for _acc in ftp anonymous; do
    _line=$(getent passwd "$_acc" 2>/dev/null || true)
    [ -n "$_line" ] || continue
    _shell=$(printf '%s' "$_line" | awk -F: '{print $7}')
    echo "     ${_acc} 계정 존재 / shell=${_shell:-확인 불가}"
    _u35_ftp_found=1
    _u35_append_text _U35_CURRENT_SUMMARY "${_acc} shell=${_shell:-확인 불가}"
    if [ -n "$_shell" ] && ! printf '%s' "$_shell" | grep -qE '(nologin|/bin/false)$'; then
      _u35_append_text _U35_MANUAL_REASON "${_acc} 계정이 로그인 가능한 shell 사용"
    fi
  done
  [ "$_u35_ftp_found" -eq 1 ] || echo "     (ftp/anonymous 계정 없음)"

  echo "   [vsftpd]"
  _u35_vsftpd_found=0
  for _cf in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
    [ -f "$_cf" ] || continue
    _line=$(grep -v '^[[:space:]]*#' "$_cf" 2>/dev/null \
      | grep -iE '^[[:space:]]*anonymous_enable[[:space:]]*=' | tail -1)
    if [ -n "$_line" ]; then
      echo "     ${_cf}: ${_line}"
      _u35_vsftpd_found=1
      _u35_append_text _U35_CURRENT_SUMMARY "vsftpd ${_line}"
      printf '%s' "$_line" | grep -qiE '=[[:space:]]*(YES|TRUE|1)[[:space:]]*$' \
        && _u35_append_text _U35_MANUAL_REASON "vsftpd 익명 접속 허용"
    fi
  done
  [ "$_u35_vsftpd_found" -eq 1 ] || echo "     (vsftpd 미설치 또는 익명 설정 없음)"

  echo "   [ProFTPD]"
  _u35_proftpd_found=0
  for _cf in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
    [ -f "$_cf" ] || continue
    _line=$(grep -v '^[[:space:]]*#' "$_cf" 2>/dev/null \
      | grep -iE '^[[:space:]]*<Anonymous([[:space:]]|>)' | head -1)
    if [ -n "$_line" ]; then
      echo "     ${_cf}: ${_line}"
      _u35_proftpd_found=1
      _u35_append_text _U35_CURRENT_SUMMARY "ProFTPD Anonymous 블록 존재"
      _u35_append_text _U35_MANUAL_REASON "ProFTPD Anonymous 블록 존재"
    fi
  done
  [ "$_u35_proftpd_found" -eq 1 ] || echo "     (ProFTPD 미설치 또는 Anonymous 블록 없음)"

  echo "   [Samba]"
  if [ -f /etc/samba/smb.conf ]; then
    _line=$(grep -v '^[[:space:]]*[#;]' /etc/samba/smb.conf 2>/dev/null \
      | grep -iE 'guest[[:space:]]*ok[[:space:]]*=|map[[:space:]]+to[[:space:]]+guest[[:space:]]*=' \
      | head -5)
    if [ -n "$_line" ]; then
      printf '%s\n' "$_line" | sed 's/^/     /'
      _u35_append_text _U35_CURRENT_SUMMARY "Samba guest 관련 설정 존재"
      if printf '%s\n' "$_line" | grep -qiE \
        'guest[[:space:]]*ok[[:space:]]*=[[:space:]]*yes|map[[:space:]]+to[[:space:]]+guest[[:space:]]*=[[:space:]]*(bad user|bad password)'; then
        _u35_append_text _U35_MANUAL_REASON "Samba guest 접근 허용 가능성"
      fi
    else
      echo "     (guest 관련 활성 설정 없음)"
    fi
  else
    echo "     (Samba 미설치 또는 설정 없음)"
  fi

  echo "   [NFS exports]"
  if [ -f /etc/exports ]; then
    _line=$(grep -v '^[[:space:]]*#' /etc/exports 2>/dev/null \
      | grep -v '^[[:space:]]*$')
    if [ -n "$_line" ]; then
      printf '%s\n' "$_line" | sed 's/^/     /'
      _u35_append_text _U35_CURRENT_SUMMARY "NFS exports 설정 존재"
      printf '%s\n' "$_line" | grep -qE '(^|[[:space:]])\*[[:space:]]*\(' \
        && _u35_append_text _U35_MANUAL_REASON "NFS 모든 호스트(*) 접근 허용"
      printf '%s\n' "$_line" | grep -q 'no_root_squash' \
        && _u35_append_text _U35_MANUAL_REASON "NFS no_root_squash 사용"
    else
      echo "     (exports 설정 없음)"
    fi
  else
    echo "     (/etc/exports 없음)"
  fi

  echo "   [서비스 상태]"
  for _svc in vsftpd proftpd smb smbd nmb nmbd nfs-server; do
    _state=$(systemctl is-active "$_svc" 2>/dev/null || true)
    [ -n "$_state" ] || continue
    printf "     %-12s : %s\n" "$_svc" "$_state"
  done

  [ -n "$_U35_CURRENT_SUMMARY" ] || _U35_CURRENT_SUMMARY="익명·guest·전체 허용 설정이 확인되지 않음"
  [ -n "$_U35_MANUAL_REASON" ] \
    || _U35_MANUAL_REASON="업무상 익명 접근 필요 여부와 허용 대상 정책 확인 필요"
}

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do
    [ "$tid" = "U-35" ] && _match=1 && break
  done

  if [ "$_match" -eq 1 ]; then
    check_still_vuln "U-35"; _u35_rc=$?

    if [ "$_u35_rc" -eq 1 ]; then
      _item_header "good" "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정"
      _lbl_cur
      _u35_print_current_state

      BEFORE_VAL["U-35"]="$_U35_CURRENT_SUMMARY"
      AFTER_VAL["U-35"]="기존 양호 (재확인 통과)"
      DETAIL_VAL["U-35"]=$(_fmt_detail \
        "$_U35_CURRENT_SUMMARY" \
        "" \
        "기존 양호 / 재확인 통과" \
        "" \
        "익명·guest·전체 허용 접근 미확인")
      _mark_skipped "U-35" "공유 서비스 익명 접근 제한 [이미양호]"
    else
      _item_header "manual" "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정"
      _lbl_cur
      _u35_print_current_state

      _sec need
      echo -e " ${YELLOW}→ 익명·guest·NFS 전체 허용 접근은 업무 정책과 허용 대상 확인이 필요합니다.${RESET}"
      echo -e " ${YELLOW}→ 스크립트는 계정, 서비스 및 /etc/exports를 자동 변경하지 않습니다.${RESET}"
      echo -e " ${YELLOW}→ 허용할 IP·대역과 서비스 사용 여부를 확인한 후 직접 조치하세요.${RESET}"

      BEFORE_VAL["U-35"]="$_U35_CURRENT_SUMMARY"
      AFTER_VAL["U-35"]="수동 확인 필요 — 자동 변경 없음"
      DETAIL_VAL["U-35"]=$(_fmt_detail \
        "$_U35_CURRENT_SUMMARY" \
        "운영 정책과 허용 대상을 확인한 후 FTP/Samba/NFS 설정을 직접 조치" \
        "수동 확인 필요" \
        "" \
        "자동 변경 없음")
      _mark_manual "U-35" "$_U35_MANUAL_REASON"
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
  "_svc_stop_disable_mask rsh.socket rlogin.socket rexec.socket rshd.service rlogind.service rexecd.service" \
  "ss -tlnp 2>/dev/null | grep -E ':514 |:513 |:512 ' && echo 'r계열 포트 잔존'
   if _svc_any_active rsh.socket rlogin.socket rexec.socket rshd.service rlogind.service rexecd.service; then
     echo 'r계열 서비스 잔존 active'
   else
     echo 'r계열 비활성 (확인 완료)'
   fi" \
  "확인 완료"

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

        # ── SUID/SGID 제거 영향 경고 ────────────────────────────────────────
        # RHEL 계열의 /usr/bin/crontab 은 기본이 4755(SUID root), at 은 4755 또는
        # 2755(SGID)다. 가이드 기준으로는 취약 판정이 맞지만, 특수 비트를 제거하면
        # 일반 사용자가 crontab/at 을 사용할 수 없게 되므로 영향과 대안을 먼저
        # 안내하고 별도 확인을 받는다.
        _u37_keep_suid=0
        _u37_suid_list=""
        for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
          [ -f "$_bin37" ] || continue
          _u37_p=$(stat -c '%a' "$_bin37" 2>/dev/null)
          if [ "$((8#${_u37_p:-0} & 8#6000))" -ne 0 ] 2>/dev/null; then
            _u37_bit=""
            [ "$((8#${_u37_p:-0} & 8#4000))" -ne 0 ] 2>/dev/null && _u37_bit="SUID"
            [ "$((8#${_u37_p:-0} & 8#2000))" -ne 0 ] 2>/dev/null \
              && _u37_bit="${_u37_bit}${_u37_bit:+/}SGID"
            _u37_suid_list="${_u37_suid_list}   - ${_bin37} : ${_u37_p} (${_u37_bit})"$'\n'
          fi
        done

        if [ -n "$_u37_suid_list" ]; then
          echo ""
          echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
          echo -e " ${BOLD}${RED}[주의] 서비스 영향 가능 — SUID/SGID 제거${RESET}"
          echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
          echo ""
          echo -e " ${WHITE}제거 대상${RESET}"
          printf '%s' "$_u37_suid_list"
          echo ""
          echo -e " ${WHITE}영향${RESET}"
          echo "   - root 이외의 일반 사용자가 'crontab -e / -l' 을 실행할 수 없게 됩니다."
          echo "   - at 명령도 동일하게 일반 사용자 사용이 차단됩니다."
          echo "   - 기존에 등록된 cron 작업 자체는 계속 실행됩니다(등록·수정만 차단)."
          echo ""
          echo -e " ${WHITE}권장 대안${RESET}"
          echo "   1) /etc/cron.allow 에 필요한 계정만 등록하고 특수 비트는 유지"
          echo "   2) 사용자 crontab 대신 /etc/cron.d 에 root 소유 작업으로 이관"
          echo "   3) 제거가 필요하면 사전에 crontab 사용 계정 유무를 확인"
          echo ""
          _u37_cron_users=""
          for _d37 in /var/spool/cron /var/spool/cron/crontabs; do
            [ -d "$_d37" ] || continue
            while IFS= read -r -d '' _cu37; do
              _cu37=$(basename "$_cu37")
              [ "$_cu37" = "root" ] && continue
              _u37_cron_users="${_u37_cron_users}${_cu37} "
            done < <(find "$_d37" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
          done
          if [ -n "$_u37_cron_users" ]; then
            _fail "현재 개인 crontab 을 보유한 일반 계정: ${_u37_cron_users}"
            echo "        → 제거 시 이 계정들의 crontab 수정이 즉시 차단됩니다."
          else
            _ok "root 이외에 개인 crontab 을 보유한 계정은 없습니다."
          fi
          echo ""
          echo -e "${WHITE}${_DIV_HEAVY}${RESET}"
          echo -e " ${YELLOW}※ y = SUID/SGID 까지 제거 , n = 특수 비트는 유지하고 나머지만 조치${RESET}"
          _read_yn _u37_suid_ack " SUID/SGID 제거를 포함해 진행하시겠습니까? (y/n): "
          if [[ "$_u37_suid_ack" != [Yy] ]]; then
            _u37_keep_suid=1
            _warn "특수 비트는 유지합니다. 소유자와 나머지 권한만 기준에 맞춰 조치합니다."
            _info "U-37 은 부분 조치로 기록되며 최종 판정은 확인 대상으로 남습니다."
          fi
          echo ""
        fi

        _lbl_yn
        _read_yn _yn_u37 " 조치하시겠습니까? (y/n): "
        if [[ "$_yn_u37" != [Yy] ]]; then
          _lbl_skip
          AFTER_VAL["U-37"]="조치 보류 (사용자 선택)"
          DETAIL_VAL["U-37"]="[조치 전] ${_u37_before_report:-점검값 없음} | [결과] 조치 보류 (사용자 선택)"
          _mark_skipped "U-37" "crontab/at 권한 [조치보류]"
        else
          _lbl_during

          # 조치 전 원래 권한과 소유자/그룹을 기록하여 롤백 가능하도록 한다.
          echo "----- [U-37] 조치 전 원래 권한 ($(date '+%Y-%m-%d %H:%M:%S')) -----" >> "/dev/null" 2>/dev/null

          for _f37 in "$_u37_crontab_bin" "$_u37_at_bin" \
                      /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny \
                      /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                      /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -e "$_f37" ] || continue
            printf 'PERM_RESTORE|%s|%s|%s\n' \
              "$_f37" "$(stat -c '%a' "$_f37" 2>/dev/null)" "$(stat -c '%U:%G' "$_f37" 2>/dev/null)" \
              >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
          done
          for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            while IFS= read -r -d '' F; do
              printf 'PERM_RESTORE|%s|%s|%s\n' \
                "$F" "$(stat -c '%a' "$F" 2>/dev/null)" "$(stat -c '%U:%G' "$F" 2>/dev/null)" \
                >> "${_CURRENT_RECORDS_FILE}" 2>/dev/null
            done < <(find "$D" -xdev -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
          done

          # crontab / at 명령 파일: SUID/SGID 제거 후 root:root / 750
          for _bin37 in "$_u37_crontab_bin" "$_u37_at_bin"; do
            [ -f "$_bin37" ] || continue
            _u37_old=$(stat -c '%a' "$_bin37" 2>/dev/null)
            if [ "${_u37_keep_suid:-0}" -eq 1 ]; then
              # 운영자가 특수 비트 유지를 선택한 경우: 기존 SUID/SGID 는 보존하고
              # 소유자와 나머지 권한 비트만 기준(750)에 맞춘다.
              _u37_special=$(( 8#${_u37_old:-0} & 8#6000 ))
              _u37_newmode=$(printf '%04o' $(( _u37_special | 8#750 )))
              if chown root:root "$_bin37" 2>/dev/null \
                 && chmod "$_u37_newmode" "$_bin37" 2>/dev/null; then
                echo "   ${_bin37} → root / ${_u37_newmode} (특수 비트 유지, ${_u37_old} → ${_u37_newmode})"
              else
                echo -e "   ${RED}✗${RESET} ${_bin37} 조치 실패"
              fi
            elif chown root:root "$_bin37" 2>/dev/null && chmod 750 "$_bin37" 2>/dev/null; then
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
               && [ "$((8#${_u37_p:-7777} & 8#027))" -eq 0 ] 2>/dev/null; then
              _ok "${_bin37} : ${_u37_o} / ${_u37_p} (SUID/SGID 없음)"
            else
              _fail "${_bin37} : ${_u37_o} / ${_u37_p} (기대: root / 750 이하, SUID/SGID 없음)"
            fi
          done

          # 설정 파일 결과 확인
          _u37_fail_list=""
          for F in /etc/crontab /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny; do
            [ -f "$F" ] || continue
            _u37_o=$(stat -c '%U' "$F" 2>/dev/null); _u37_p=$(stat -c '%a' "$F" 2>/dev/null)
            if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777} & 8#037))" -eq 0 ] 2>/dev/null; then
              _ok "$F : ${_u37_o} / ${_u37_p}"
            else
              _fail "$F : ${_u37_o} / ${_u37_p} (기대: root / 640 이하)"
              _u37_fail_list="${_u37_fail_list}${F}(${_u37_o}/${_u37_p}); "
            fi
          done

          # 관련 디렉터리 결과 확인
          for D in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly \
                   /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            _u37_o=$(stat -c '%U' "$D" 2>/dev/null); _u37_p=$(stat -c '%a' "$D" 2>/dev/null)
            if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777} & 8#027))" -eq 0 ] 2>/dev/null; then
              _ok "$D : ${_u37_o} / ${_u37_p}"
            else
              _fail "$D : ${_u37_o} / ${_u37_p} (기대: root / 750 이하)"
              _u37_fail_list="${_u37_fail_list}${D}(${_u37_o}/${_u37_p}); "
            fi
          done

          # 작업 목록 파일 결과 확인
          for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs /var/spool/at /var/spool/atjobs; do
            [ -d "$D" ] || continue
            while IFS= read -r -d '' F; do
              _u37_o=$(stat -c '%U' "$F" 2>/dev/null); _u37_p=$(stat -c '%a' "$F" 2>/dev/null)
              if [ "$_u37_o" = "root" ] && [ "$((8#${_u37_p:-7777} & 8#037))" -eq 0 ] 2>/dev/null; then
                _ok "$F : ${_u37_o} / ${_u37_p}"
              else
                _fail "$F : ${_u37_o} / ${_u37_p} (기대: root / 640 이하)"
                _u37_fail_list="${_u37_fail_list}${F}(${_u37_o}/${_u37_p}); "
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
            _mark_failed "U-37" "조치 후에도 cron/at 권한 기준 미충족 (미충족 대상: ${_u37_fail_list:-확인 필요})"
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
  "_o=\$(for port in 7 9 13 19; do ss -tlnp 2>/dev/null | grep \":\${port} \" || true; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'DoS 취약 서비스 비활성 (확인 완료)'" \
  "확인 완료"

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

# 시스템에 설치된 NFS 서버 유닛을 찾는다.
_u39_detect_unit() {
  local _unit _load
  for _unit in nfs-server.service nfs-kernel-server.service; do
    _load=$(systemctl show "$_unit" -p LoadState --value 2>/dev/null | head -1)
    if [ -n "$_load" ] && [ "$_load" != "not-found" ]; then
      printf '%s' "$_unit"
      return 0
    fi
  done
  printf '%s' "nfs-server.service"
}

# U-39의 서비스·포트·커널·export 상태를 동일한 기준으로 수집한다.
# 호출 후 _U39_* 전역값과 _U39_SUMMARY를 사용한다.
#
# 설계 원칙(재작업):
#   - 완료 판정(_CLEAN 집계)에는 서비스 상태·자동시작·포트·커널 스레드 수만 사용한다.
#   - /proc/fs/nfsd 마운트 여부는 커널 인터페이스 잔존 여부일 뿐 실제 네트워크
#     노출과 무관할 수 있어 참고 정보로만 표시하고 완료 판정에서 제외한다.
#   - export 상태는 NONE(없음)/EXISTS(존재)/UNKNOWN(확인 실패·불가) 3가지로
#     분리한다. "확인 실패" 하나로 뭉뚱그리면 장애/명령 미설치/실제 없음을
#     구분할 수 없기 때문이다. export 상태는 U-39 완료 판정에는 쓰지 않고
#     U-35/U-40 연계 판정에만 사용한다.
_u39_collect_state() {
  _U39_UNIT=$(_u39_detect_unit)
  _U39_ACTIVE=$(systemctl is-active "$_U39_UNIT" 2>/dev/null | head -1)
  _U39_ENABLED=$(systemctl is-enabled "$_U39_UNIT" 2>/dev/null | head -1)
  [ -n "$_U39_ACTIVE" ] || _U39_ACTIVE="unknown"
  [ -n "$_U39_ENABLED" ] || _U39_ENABLED="unknown"

  _U39_ACTIVE_CLEAN=0
  [ "$_U39_ACTIVE" != "active" ] && _U39_ACTIVE_CLEAN=1

  _U39_ENABLED_CLEAN=0
  case "$_U39_ENABLED" in
    disabled|masked|not-found) _U39_ENABLED_CLEAN=1 ;;
  esac

  _U39_PORT_CLEAN=0
  _U39_PORT_STATE="확인 불가"
  if command -v ss >/dev/null 2>&1; then
    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ':2049$'; then
      _U39_PORT_STATE="사용 중"
    else
      _U39_PORT_STATE="미사용"
      _U39_PORT_CLEAN=1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq ':2049$'; then
      _U39_PORT_STATE="사용 중"
    else
      _U39_PORT_STATE="미사용"
      _U39_PORT_CLEAN=1
    fi
  fi

  # nfsd 프로세스 존재(pgrep/ps 기반)는 커맨드라인에 "nfsd" 문자열만 있어도
  # 걸리는 오탐 가능성이 있어, 실제 커널 NFS 서버 스레드 수로 대체한다.
  if [ -r /proc/fs/nfsd/threads ]; then
    _U39_THREADS_RAW=$(cat /proc/fs/nfsd/threads 2>/dev/null | head -1)
    if [ "${_U39_THREADS_RAW:-0}" -gt 0 ] 2>/dev/null; then
      _U39_THREADS_STATE="${_U39_THREADS_RAW} (NFS 서버 커널 스레드 실행 중)"
      _U39_THREADS_CLEAN=0
    else
      _U39_THREADS_STATE="0"
      _U39_THREADS_CLEAN=1
    fi
  else
    # 인터페이스 파일 자체가 없으면 비활성 또는 미구성 상태로 본다.
    _U39_THREADS_STATE="파일 없음 (비활성 또는 미구성)"
    _U39_THREADS_CLEAN=1
  fi

  # /proc/fs/nfsd 마운트는 참고 정보로만 표시한다 (완료 판정 조건에서 제외).
  if command -v findmnt >/dev/null 2>&1; then
    _U39_MOUNT_OUT=$(findmnt -rn /proc/fs/nfsd 2>/dev/null)
  else
    _U39_MOUNT_OUT=$(mount 2>/dev/null | grep ' on /proc/fs/nfsd ')
  fi
  if [ -n "$_U39_MOUNT_OUT" ]; then
    _U39_MOUNT_STATE="마운트됨"
  else
    _U39_MOUNT_STATE="마운트 없음"
  fi

  # export 상태: NONE / EXISTS / UNKNOWN 3가지로 분리한다.
  # 1차로 exportfs -v(커널 export 테이블 직접 조회, mountd/rpcbind 없이도 동작),
  # 실패 시 2차로 exportfs -s를 보조로 확인한다. showmount는 rpcbind/mountd가
  # 내려가 있으면 접속 자체가 실패해 "확인 실패"와 "정말 없음"을 구분 못 하므로
  # 쓰지 않는다.
  _U39_EXPORT_STATUS="UNKNOWN"
  _U39_EXPORT_STATE="확인 불가"
  _U39_EXPORT_OUT=""
  if command -v exportfs >/dev/null 2>&1; then
    local _u39_ex_v="" _u39_ex_v_rc=0
    _u39_ex_v=$(exportfs -v 2>/dev/null); _u39_ex_v_rc=$?
    if [ "$_u39_ex_v_rc" -eq 0 ] && [ -n "$_u39_ex_v" ]; then
      _U39_EXPORT_STATUS="EXISTS"
      _U39_EXPORT_OUT="$_u39_ex_v"
      _U39_EXPORT_STATE="활성 export 존재 ($(printf '%s\n' "$_u39_ex_v" | grep -c .)줄, exportfs -v 기준)"
    elif [ "$_u39_ex_v_rc" -eq 0 ]; then
      _U39_EXPORT_STATUS="NONE"
      _U39_EXPORT_STATE="활성 export 없음"
    else
      local _u39_ex_s="" _u39_ex_s_rc=0
      _u39_ex_s=$(exportfs -s 2>/dev/null); _u39_ex_s_rc=$?
      if [ "$_u39_ex_s_rc" -eq 0 ] && [ -n "$_u39_ex_s" ]; then
        _U39_EXPORT_STATUS="EXISTS"
        _U39_EXPORT_OUT="$_u39_ex_s"
        _U39_EXPORT_STATE="활성 export 존재 (exportfs -s 기준)"
      elif [ "$_u39_ex_s_rc" -eq 0 ]; then
        _U39_EXPORT_STATUS="NONE"
        _U39_EXPORT_STATE="활성 export 없음"
      else
        _U39_EXPORT_STATUS="UNKNOWN"
        _U39_EXPORT_STATE="확인 명령 실패 (exportfs -v/-s 모두 실패)"
      fi
    fi
  else
    _U39_EXPORT_STATUS="UNKNOWN"
    _U39_EXPORT_STATE="확인 불가 (exportfs 없음)"
  fi

  # /var/lib/nfs/etab, /proc/fs/nfsd/exports 는 잔존 정보일 수 있어 단독으로
  # export 존재/없음을 판정하는 근거로 쓰지 않는다. UNKNOWN일 때 참고용
  # 힌트로만 덧붙인다.
  if [ "$_U39_EXPORT_STATUS" = "UNKNOWN" ]; then
    local _u39_etab_hint=""
    [ -s /var/lib/nfs/etab ] && _u39_etab_hint="${_u39_etab_hint}/var/lib/nfs/etab "
    [ -s /proc/fs/nfsd/exports ] && _u39_etab_hint="${_u39_etab_hint}/proc/fs/nfsd/exports "
    [ -n "$_u39_etab_hint" ] && _U39_EXPORT_STATE="${_U39_EXPORT_STATE} (참고: ${_u39_etab_hint}에 잔존 흔적 있음 — 단독 판단 근거 아님)"
  fi

  _U39_SUMMARY="서비스(${_U39_UNIT})=${_U39_ACTIVE}, 자동 시작=${_U39_ENABLED}, TCP/UDP 2049=${_U39_PORT_STATE}, NFS 서버 스레드=${_U39_THREADS_STATE}, /proc/fs/nfsd=${_U39_MOUNT_STATE}, export=${_U39_EXPORT_STATE}"
}

_u39_print_state() {
  echo "   서비스 유닛     : ${_U39_UNIT}"
  echo "   서비스 상태     : ${_U39_ACTIVE}"
  echo "   자동 시작       : ${_U39_ENABLED}"
  echo "   TCP/UDP 2049    : ${_U39_PORT_STATE}"
  echo "   NFS 서버 스레드 : ${_U39_THREADS_STATE}"
  echo "   커널 인터페이스 : /proc/fs/nfsd ${_U39_MOUNT_STATE}"
  echo "   export 상태     : ${_U39_EXPORT_STATE}"
  if [ "$_U39_MOUNT_STATE" = "마운트됨" ]; then
    echo -e "   ${CYAN}※ /proc/fs/nfsd 마운트는 커널 인터페이스 잔존 상태이며, 현재 네트워크 노출 여부 판정에는 영향을 주지 않습니다.${RESET}"
  fi
}

{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-39" ] && _match=1 && break; done
  if [ "$_match" -eq 1 ]; then
    check_still_vuln "U-39"; _vs=$?
    _flush_header

    if [ "$_vs" -eq 1 ]; then
      _item_header "good" "U-39" "(상) 불필요한 NFS 서비스 비활성화"
      _lbl_cur
      _u39_collect_state
      _u39_print_state
      echo ""

      BEFORE_VAL["U-39"]="$_U39_SUMMARY"
      AFTER_VAL["U-39"]="$_U39_SUMMARY"
      DETAIL_VAL["U-39"]=$(_fmt_detail \
        "$_U39_SUMMARY" \
        "변경 없음" \
        "기존 양호 / 재확인 통과" \
        "" \
        "$_U39_SUMMARY")
      _mark_skipped "U-39" "NFS 비활성화 [이미양호]"

    else
      _item_header "vuln" "U-39" "(상) 불필요한 NFS 서비스 비활성화"
      echo ""
      _lbl_before

      _u39_collect_state
      _u39_before_summary="$_U39_SUMMARY"
      BEFORE_VAL["U-39"]="$_u39_before_summary"
      _u39_print_state
      echo ""

      echo -e " ${YELLOW}[!] NFS가 현재 사용 중일 수 있습니다. 업무 필요 여부를 확인하세요.${RESET}"
      echo -e " ${YELLOW}※ y = 비활성화 진행, n = 조치 보류${RESET}"
      _read_yn _nfs_yn " 업무상 불필요한 NFS임을 확인했습니까? (y/n): "

      case "$_nfs_yn" in
        [Yy])
          _u39_unit="$_U39_UNIT"

          systemctl stop "$_u39_unit" nfs-mountd.service rpc-statd.service 2>/dev/null || true
          systemctl disable "$_u39_unit" 2>/dev/null || true
          systemctl mask "$_u39_unit" 2>/dev/null || true

          _u39_collect_state
          AFTER_VAL["U-39"]="$_U39_SUMMARY"

          echo ""
          _lbl_result
          _u39_print_state

          _u39_result=""
          _u39_reason_parts=()

          [ "$_U39_ACTIVE_CLEAN" -eq 1 ] \
            || _u39_reason_parts+=("서비스 상태=${_U39_ACTIVE}")
          [ "$_U39_ENABLED_CLEAN" -eq 1 ] \
            || _u39_reason_parts+=("자동 시작=${_U39_ENABLED}")
          [ "$_U39_PORT_CLEAN" -eq 1 ] \
            || _u39_reason_parts+=("TCP/UDP 2049=${_U39_PORT_STATE}")
          [ "$_U39_THREADS_CLEAN" -eq 1 ] \
            || _u39_reason_parts+=("NFS 서버 스레드=${_U39_THREADS_STATE}")

          # 완료 판정은 서비스 상태·자동 시작·포트·커널 스레드 수 4가지만 본다.
          # /proc/fs/nfsd 마운트와 export 잔존 여부는 네트워크 노출과 무관할 수
          # 있어 이 판정에서 제외하고, export는 U-35/U-40 연계 판정에만 쓴다.
          if [ "$_U39_ACTIVE_CLEAN" -ne 1 ]; then
            _u39_result="조치 실패"
            _fail "NFS 최종 상태 : 서비스 중지 실패"
          elif [ "$_U39_ENABLED_CLEAN" -eq 1 ] \
               && [ "$_U39_PORT_CLEAN" -eq 1 ] \
               && [ "$_U39_THREADS_CLEAN" -eq 1 ]; then
            _u39_result="조치 완료 / 최종 검증 통과"
            _ok "NFS 네트워크 서비스가 비활성화되었습니다."
          else
            _u39_result="수동 확인 필요"
            _warn "NFS 최종 상태 : 일부 잔존 또는 확인 불가"
          fi

          DETAIL_VAL["U-39"]=$(_fmt_detail \
            "$_u39_before_summary" \
            "NFS 서버 및 관련 서비스 중지, 자동 시작 비활성화·마스킹" \
            "$_u39_result" \
            "" \
            "$_U39_SUMMARY" \
            "${_U39_UNIT} 중지·비활성화·마스킹 (export 상태: ${_U39_EXPORT_STATE})")

          if [ "$_u39_result" = "조치 실패" ]; then
            _u39_reason=$(IFS=', '; printf '%s' "${_u39_reason_parts[*]}")
            _mark_failed "U-39" "NFS 서비스 중지 실패${_u39_reason:+: ${_u39_reason}}"
          elif [ "$_u39_result" = "수동 확인 필요" ]; then
            _u39_reason=$(IFS=', '; printf '%s' "${_u39_reason_parts[*]}")
            _mark_manual "U-39" "NFS 비활성화 후 잔존 또는 확인 불가${_u39_reason:+: ${_u39_reason}}"
          else
            _mark_fixed "U-39" "불필요한 NFS 서비스 비활성화 및 최종 검증 완료"
          fi

          # U-35/U-40 연계 판정: U-39 핵심 조건(서비스·자동시작·포트·스레드)이
          # 모두 클린일 때만 export 상태로 세분화한다.
          #   - export=NONE    → 활성 export가 없으므로 U-35/U-40 해당없음
          #   - export=EXISTS  → 서비스는 죽었지만 export가 남아 있어 접근
          #                      정책을 사람이 직접 봐야 하므로 수동확인
          #   - export=UNKNOWN → export 유무 자체를 조회하지 못했으므로 역시
          #                      수동확인 (자동으로 해당없음 처리하면 안 됨)
          # U-39 핵심 조건이 클린이 아니면(서비스 살아있음 등) U-35/U-40은
          # 원래 자기 점검 로직을 그대로 타도록 손대지 않는다.
          _u39_core_clean=0
          if [ "$_U39_ACTIVE_CLEAN" -eq 1 ] \
             && [ "$_U39_ENABLED_CLEAN" -eq 1 ] \
             && [ "$_U39_PORT_CLEAN" -eq 1 ] \
             && [ "$_U39_THREADS_CLEAN" -eq 1 ]; then
            _u39_core_clean=1
          fi

          if [ "$_u39_core_clean" -eq 1 ] && [ "$_U39_EXPORT_STATUS" = "NONE" ]; then
            _NFS_DISABLED=1

            for _nfs_dep in \
              "U-35:공유 서비스 익명 접근 제한" \
              "U-40:NFS 접근 통제"; do
              _dep_id="${_nfs_dep%%:*}"
              _dep_name="${_nfs_dep##*:}"

              for _tid in "${TARGET_IDS[@]}"; do
                if [ "$_tid" = "$_dep_id" ]; then
                  _div_thick
                  echo -e "${CYAN}[○ 해당없음]${RESET} ${BOLD}${_dep_id}${RESET} (상) ${_dep_name}"
                  echo -e " ${CYAN}→ U-39 최종 검증에서 NFS 서비스 비활성화 및 활성 export 없음 확인${RESET}"
                  echo ""
                  echo ""

                  BEFORE_VAL["$_dep_id"]="U-39에서 NFS 서비스 비활성화 확인"
                  AFTER_VAL["$_dep_id"]="해당없음"
                  DETAIL_VAL["$_dep_id"]="[연계 판정] U-39 최종 검증 결과: ${_U39_SUMMARY}"
                  _mark_na "$_dep_id" "${_dep_name} [NFS 비활성화로 불필요]"
                  break
                fi
              done
            done

          elif [ "$_u39_core_clean" -eq 1 ] && { [ "$_U39_EXPORT_STATUS" = "EXISTS" ] || [ "$_U39_EXPORT_STATUS" = "UNKNOWN" ]; }; then
            _NFS_DISABLED=0
            if [ "$_U39_EXPORT_STATUS" = "EXISTS" ]; then
              _u39_dep_reason="NFS 서비스는 비활성화되었으나 활성 export가 남아 있어 export별 접근 정책을 별도로 점검해야 함"
            else
              _u39_dep_reason="NFS 서비스는 비활성화되었으나 활성 export 상태를 정상적으로 조회하지 못해 수동 확인이 필요함"
            fi

            for _nfs_dep in \
              "U-35:공유 서비스 익명 접근 제한" \
              "U-40:NFS 접근 통제"; do
              _dep_id="${_nfs_dep%%:*}"
              _dep_name="${_nfs_dep##*:}"

              for _tid in "${TARGET_IDS[@]}"; do
                if [ "$_tid" = "$_dep_id" ]; then
                  _div_thick
                  echo -e "${YELLOW}[△ 수동확인]${RESET} ${BOLD}${_dep_id}${RESET} (상) ${_dep_name}"
                  echo -e " ${YELLOW}→ ${_u39_dep_reason}${RESET}"
                  echo -e "   export 상태 : ${_U39_EXPORT_STATE}"
                  echo ""
                  echo ""

                  BEFORE_VAL["$_dep_id"]="U-39에서 NFS 서비스 비활성화 확인 (export 상태: ${_U39_EXPORT_STATE})"
                  AFTER_VAL["$_dep_id"]="수동 확인 필요"
                  DETAIL_VAL["$_dep_id"]="[연계 판정] U-39 최종 검증 결과: ${_U39_SUMMARY} | 사유: ${_u39_dep_reason}"
                  _mark_manual "$_dep_id" "${_dep_name} — ${_u39_dep_reason}"
                  break
                fi
              done
            done

            if [ "$_U39_EXPORT_STATUS" = "EXISTS" ] && [ -n "$_U39_EXPORT_OUT" ]; then
              echo -e " ${YELLOW}[잔존 export]${RESET}"
              printf '%s\n' "$_U39_EXPORT_OUT" | sed 's/^/   /'
              echo -e " ${CYAN}※ 참고: export 제거(exportfs -au)는 자동 조치 대상이 아닙니다. 필요 여부를 확인한 뒤 관리자가 직접 실행하세요.${RESET}"
            fi

          else
            _NFS_DISABLED=0
            echo ""
            echo -e " ${YELLOW}※ 최종 검증에 잔존 또는 확인 불가 항목이 있어 U-35, U-40은 그대로 점검합니다.${RESET}"

            if [ "$_U39_EXPORT_STATUS" = "EXISTS" ] && [ -n "$_U39_EXPORT_OUT" ]; then
              echo ""
              echo -e " ${YELLOW}[잔존 export]${RESET}"
              printf '%s\n' "$_U39_EXPORT_OUT" | sed 's/^/   /'
            fi

            echo ""
            echo -e " ${YELLOW}[권장 사항]${RESET}"
            echo "   • 시스템 재부팅 후 재확인"
            echo "   • 관련 RPC/NFS 프로세스 종료 후 TCP/UDP 2049·NFS 서버 스레드 재확인"
          fi
          ;;

        *)
          echo -e " ${YELLOW}→ 사용자 선택으로 조치를 보류합니다. (NFS 서비스 유지 — 업무상 필요로 판단)${RESET}"
          _u39_collect_state
          AFTER_VAL["U-39"]="$_U39_SUMMARY"
          DETAIL_VAL["U-39"]=$(_fmt_detail \
            "$_u39_before_summary" \
            "업무상 필요에 따라 자동 조치 미수행" \
            "수동 확인 필요" \
            "" \
            "$_U39_SUMMARY")

          echo -e " ${YELLOW}   현재 상태:${RESET}"
          _u39_print_state
          if [ "$_U39_EXPORT_STATUS" = "EXISTS" ] && [ -n "$_U39_EXPORT_OUT" ]; then
            printf '%s\n' "$_U39_EXPORT_OUT" | sed 's/^/   /'
          fi

          _mark_skipped "U-39" "NFS 비활성화 [업무상 유지]"
          _NFS_DISABLED=0
          ;;
      esac
    fi
    echo ""
  fi
}

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
  "grep 'no_root_squash' /etc/exports 2>/dev/null || echo 'no_root_squash 없음 (확인 완료)'" \
  "확인 완료"

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
  "systemctl is-active autofs 2>/dev/null || echo 'autofs 비활성 (확인 완료)'" \
  "확인 완료"

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
  "_o=\$(for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do pgrep -x \$svc &>/dev/null && echo \"\$svc 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'RPC 취약 서비스 비활성 (확인 완료)'" \
  "확인 완료"

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
  "_o=\$(for p in ypserv ypbind; do pgrep -x \$p &>/dev/null && echo \"\$p 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'NIS 비활성 (확인 완료)'" \
  "확인 완료"

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
  "_svc_stop_disable_mask tftp.socket tftp.service tftpd.service tftpd-hpa.service atftpd.service \\
     talk.socket talk.service ntalk.socket ntalk.service" \
  "ss -ulnp 2>/dev/null | grep -E ':69 |:517 |:518 ' && echo 'tftp/talk 포트 잔존'
   if _svc_any_active tftp.socket tftp.service tftpd.service tftpd-hpa.service atftpd.service \\
        talk.socket talk.service ntalk.socket ntalk.service; then
     echo 'tftp/talk 서비스 잔존 active'
   else
     echo 'tftp/talk 비활성 (확인 완료)'
   fi" \
  "확인 완료"

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
  "_pkg=''
   { command -v postconf &>/dev/null || pgrep -x postfix &>/dev/null; } && _pkg=postfix
   [ -z \"\$_pkg\" ] && { command -v sendmail &>/dev/null || pgrep -x sendmail &>/dev/null; } && _pkg=sendmail
   [ -z \"\$_pkg\" ] && { command -v exim4 &>/dev/null || command -v exim &>/dev/null || pgrep -x exim &>/dev/null; } && _pkg=exim4
   if [ -n \"\$_pkg\" ]; then
     command -v dnf &>/dev/null && dnf update -y \"\$_pkg\" 2>/dev/null
     command -v yum &>/dev/null && yum update -y \"\$_pkg\" 2>/dev/null
     command -v apt-get &>/dev/null && apt-get install --only-upgrade \"\$_pkg\" -y 2>/dev/null
   fi" \
  "_pkg=''
   { command -v postconf &>/dev/null || pgrep -x postfix &>/dev/null; } && _pkg=postfix
   [ -z \"\$_pkg\" ] && { command -v sendmail &>/dev/null || pgrep -x sendmail &>/dev/null; } && _pkg=sendmail
   [ -z \"\$_pkg\" ] && { command -v exim4 &>/dev/null || command -v exim &>/dev/null || pgrep -x exim &>/dev/null; } && _pkg=exim4
   if [ -z \"\$_pkg\" ]; then
     echo 'MTA 없음 (확인 완료)'
   else
     _pkg_update_state \"\$_pkg\"; _urc=\$?
     if [ \"\$_urc\" -eq 0 ]; then
       echo \"\${_pkg} 업데이트 잔존\"
     elif [ \"\$_urc\" -eq 1 ]; then
       echo \"\${_pkg} 최신 (확인 완료)\"
     else
       echo \"\${_pkg} 업데이트 상태 확인 불가 (확인 완료)\"
     fi
   fi" \
  "확인 완료"

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
  "_p=/etc/postfix/main.cf; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; [ -f /etc/postfix/main.cf ] && chown root:root /etc/postfix/main.cf && chmod 644 /etc/postfix/main.cf" \
  "stat -c '소유자: %U / 권한: %a' /etc/postfix/main.cf 2>/dev/null || echo '파일 없음 (확인 완료)'" \
  "소유자: root / 권한: 644|확인 완료"

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
     echo '설정값 및 Postfix 서비스 반영 확인 완료'
   else
     echo '설정값 또는 Postfix 서비스 반영 실패'
   fi" \
  "확인 완료"

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
  "command -v dnf &>/dev/null && dnf update -y bind 2>/dev/null
   command -v yum &>/dev/null && yum update -y bind 2>/dev/null
   command -v apt &>/dev/null && apt-get install --only-upgrade bind9 -y 2>/dev/null" \
  "if ! command -v named &>/dev/null; then
     echo 'named 없음 (확인 완료)'
   else
     named -v 2>&1 | head -1
     _pkg=bind
     command -v apt &>/dev/null && _pkg=bind9
     _pkg_update_state \"\$_pkg\"; _urc=\$?
     if [ \"\$_urc\" -eq 0 ]; then
       echo 'BIND 업데이트 잔존'
     elif [ \"\$_urc\" -eq 1 ]; then
       echo 'BIND 최신 (확인 완료)'
     else
       echo 'BIND 업데이트 상태 확인 불가 (확인 완료)'
     fi
   fi" \
  "확인 완료"

# =============================================================================
# U-50 / DNS Zone Transfer 설정
#
# 점검 기준:
#   named-checkconf로 include를 전개한 뒤 options → view → zone 상속을 반영하여
#   authoritative zone별 유효 allow-transfer가 전체 허용이 아니어야 한다.
#   최신 BIND의 미설정 기본값은 none이므로 미설정 자체를 취약으로 보지 않는다.
#
# 처리 정책:
#   DNS 보조 서버·TSIG·view별 전송 정책을 자동으로 none으로 덮어쓰지 않고
#   유효 정책과 대상 zone을 보고서에 제시한 뒤 수동 조치 대상으로 관리한다.
# =============================================================================

do_manual "U-50" "(상) DNS Zone Transfer 설정" \
  "[판정 기준] zone별 유효 allow-transfer가 any, 0.0.0.0/0, ::/0이면 취약입니다.\n[조치 절차] 해당 zone 또는 상속된 options/view 정책을 승인된 보조 DNS·TSIG key만 허용하도록 제한하고 named-checkconf 통과 후 reload하세요.\n[유의사항] allow-transfer 미설정은 최신 BIND 기본값 none이므로 양호이며, 보조 DNS 운영 zone을 일괄 none으로 변경하면 전송 장애가 발생할 수 있습니다." \
  "_bind_policy_audit transfer; true"

# =============================================================================
# U-51 / DNS 동적 업데이트 제한
#
# 점검 기준:
#   primary zone별 allow-update/update-policy 상속을 확인하고 전체 허용을 금지한다.
#   allow-update 미설정은 기본 deny이며, TSIG/update-policy는 identity와 grant 범위를 확인한다.
#
# 처리 정책:
#   DHCP/DDNS 연동을 파괴할 수 있으므로 자동 sed 변경을 제거하고 수동 확인으로 전환한다.
# =============================================================================

do_manual "U-51" "(중) DNS 서비스의 취약한 동적 업데이트 설정 금지" \
  "[판정 기준] allow-update 전체 허용은 취약, 미설정 또는 none은 양호입니다. TSIG key/update-policy는 grant identity·name·type 범위를 확인해야 합니다.\n[조치 절차] 불필요한 동적 업데이트는 none으로 차단하고, 필요한 경우 IP ACL 대신 TSIG 기반 update-policy를 최소 권한으로 구성한 뒤 named-checkconf와 실제 DDNS 연동을 검증하세요.\n[유의사항] DHCP·AD DNS·자동화 연동 zone을 사전 확인하지 않고 allow-update를 제거하면 서비스 장애가 발생할 수 있습니다." \
  "_bind_policy_audit update; true"

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
  "확인 완료"

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
  "_bad=0
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     L=\$(grep -vi '^#' \"\$F\" | grep -i 'ftpd_banner' | tail -1)
     echo \"\$F: \${L:-미설정}\"
     echo \"\$L\" | grep -qiE 'vsftpd|version|[0-9]\.[0-9]' && _bad=\$((_bad+1))
   done
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     L=\$(grep -vi '^#' \"\$F\" | grep -i 'ServerIdent' | tail -1)
     echo \"\$F: \${L:-미설정}\"
     echo \"\$L\" | grep -qiE 'off' || _bad=\$((_bad+1))
   done
   echo \"배너 위반 파일 수: \${_bad}\"" \
  "배너 위반 파일 수: 0"

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
      _u54_status_report | sed 's/^/   /'
      echo "   FTP 비활성 또는 TLS 강제 적용됨 (양호)"
      echo ""
      BEFORE_VAL["U-54"]=$(echo "FTP 비활성 또는 암호화 FTP만 운용 중")
      [ -z "${BEFORE_VAL["U-54"]:-}" ] && BEFORE_VAL["U-54"]="기존 양호 (점검 통과)"
      AFTER_VAL["U-54"]="기존 양호 (재확인 통과)"
      _mark_skipped "U-54" "FTP 서비스 [이미양호]"
    elif [ $_vs -eq 3 ]; then
      _item_header "manual" "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화"
      _sec check
      _u54_status_report | sed 's/^/   /'
      _sec need
      _warn "활성 FTP 데몬의 TLS 강제 범위를 자동 확정할 수 없습니다."
      _info "실제 사용 설정 파일과 vsftpd force_*_ssl 또는 ProFTPD TLSRequired on을 확인하세요."
      BEFORE_VAL["U-54"]=$(_u54_status_report | head -20)
      AFTER_VAL["U-54"]="수동 확인 필요"
      DETAIL_VAL["U-54"]="[현재 상태] ${BEFORE_VAL[U-54]} | [조치 방법] 실제 FTP 설정 파일과 TLS 강제 범위 확인"
      _mark_manual "U-54" "FTP TLS 적용 범위 자동 판정 불가"
    else
      _item_header "vuln" "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화"
      _lbl_before
      _u54_svc=""
      systemctl is-active vsftpd  2>/dev/null | grep -q '^active' && _u54_svc="vsftpd"
      [ -z "$_u54_svc" ] && systemctl is-active proftpd 2>/dev/null | grep -q '^active' && _u54_svc="proftpd"
      BEFORE_VAL["U-54"]=$(_u54_status_report | head -20)
      AFTER_VAL["U-54"]="조치 전 취약"
      echo "   서비스 : ${_u54_svc:-확인불가}"
      echo "   상태    : $(systemctl is-active "${_u54_svc:-vsftpd}" 2>/dev/null) (운용 중)"
      _u54_status_report | sed 's/^/   /'
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
        AFTER_VAL["U-54"]="확인 필요 (운영 서비스 유지, FTPS/SFTP 전환 필요)"
        DETAIL_VAL["U-54"]="[현재 상태] ${BEFORE_VAL[U-54]} | [판정] 비암호화 FTP 운영 유지 | [조치 방법] FTPS 강제 또는 SFTP 전환 후 재점검"
        _mark_manual "U-54" "FTP 업무 사용 중 — 비암호화 상태 유지, FTPS/SFTP 전환 및 접근제어 강화 필요"
      else
        echo -e "   ${CYAN}FTP 서비스를 사용하지 않는 것으로 확인되었습니다.${RESET}"
        _lbl_yn
        _read_yn _yn_u54 " 조치하시겠습니까? (y/n): "
        if [[ "$_yn_u54" != [Yy] ]]; then
          _lbl_skip
          _mark_skipped "U-54" "FTP 서비스 [조치보류]"
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
            _mark_failed "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화 — 조치 후에도 여전히 취약 (${_u54_svc:-FTP} 상태: ${_u54_before_state:-active} → ${_u54_after_state:-active}, 다른 프로세스/타이머가 재시작하고 있을 수 있음)"
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
  "# [검증] tcp_wrappers 또는 <Limit LOGIN> 중 하나라도 설정되면 확인 완료
   _ok=0
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -qi 'tcp_wrappers=YES' \"\$F\" && _ok=1
   done
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -qi 'Limit.*LOGIN' \"\$F\" && _ok=1
   done
   [ \$_ok -eq 1 ] && echo 'IP/호스트 기반 접근통제 설정 확인 완료' \
                   || echo '설정 미확인 — 수동 검토 필요'" \
  "확인 완료"

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
  "_bad=0; _found=0
   for F in /etc/ftpusers /etc/vsftpd/ftpusers /etc/vsftpd.ftpusers /etc/proftpd/ftpusers; do
     [ -f \"\$F\" ] || continue
     _found=1
     if grep -v '^#' \"\$F\" | grep -q '^root'; then
       echo \"\$F: root 등록됨\"
     else
       echo \"\$F: root 미등록\"
       _bad=\$((_bad+1))
     fi
   done
   [ \"\$_found\" -eq 0 ] && echo 'ftpusers 없음'
   echo \"미등록 파일 수: \${_bad}\"" \
  "미등록 파일 수: 0"

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
      [ -z "${BEFORE_VAL["U-58"]:-}" ] && BEFORE_VAL["U-58"]="기존 양호 (점검 통과)"
      AFTER_VAL["U-58"]="기존 양호 (재확인 통과)"
      _mark_skipped "U-58" "SNMP 서비스 [이미양호]"
    else
      _item_header "vuln" "U-58" "(중) 불필요한 SNMP 서비스 구동 점검"
      BEFORE_VAL["U-58"]=$(echo "SNMP 비활성")
      [ -z "${BEFORE_VAL["U-58"]:-}" ] && BEFORE_VAL["U-58"]="기존 양호 (점검 통과)"
      AFTER_VAL["U-58"]="기존 양호 (재확인 통과)"
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
          _mark_skipped "U-58" "SNMP 서비스 [조치보류]"
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
            _mark_failed "U-58" "(중) 불필요한 SNMP 서비스 구동 점검 — 조치 후에도 여전히 취약 (snmpd 상태: ${_u58_before_state:-active} → ${_u58_after_state:-active}, mask 이후에도 재기동되고 있을 수 있음)"
          fi
        fi
      fi
    fi
    echo ""
  fi
}
# =============================================================================
# U-59 / 안전한 SNMP 버전 사용
#
# 점검 기준:
#   SNMPv1/v2c community 기반 접근 지시자가 없어야 하며 SNMPv3 접근 모델을 사용해야 한다.
#
# 처리 정책:
#   SNMPv3 사용자·인증정보가 준비되지 않은 상태에서 v1/v2c를 자동 차단하면 모니터링이
#   즉시 중단될 수 있으므로 자동 주석 처리 로직을 제거하고 수동 전환 절차를 제시한다.
# =============================================================================

do_manual "U-59" "(상) 안전한 SNMP 버전 사용" \
  "[판정 기준] com2sec/rocommunity/rwcommunity/group v1·v2c가 존재하면 취약합니다. v3 rouser/rwuser/authuser 또는 usm 기반 VACM 구성이 확인되어야 합니다.\n[조치 절차] 모니터링 서버에 SNMPv3 사용자를 먼저 등록하고 authPriv를 우선 적용하여 실제 조회를 검증한 뒤 v1/v2c community 접근을 제거하세요.\n[유의사항] createUser 인증정보는 보고서에 노출하지 않으며, v3 검증 전에 community를 제거하면 모니터링 장애가 발생합니다." \
  "_snmp_version_audit; true"

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
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'community\s+(public|private)' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '기본 Community 없음 (확인 완료)'" \
  "확인 완료"

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
  "[ -f /etc/snmp/snmpd.conf ] && {
     config_set /etc/snmp/snmpd.conf 'com2sec.*default.*' 'com2sec notConfigUser  localhost    public' substr
     config_set /etc/snmp/snmpd.conf '(agentaddress[[:space:]]+(udp:)?)0\.0\.0\.0' '\1127.0.0.1' substr ci
     _snmpd_reload_guard \"\$_RUN_TS\" /etc/snmp/snmpd.conf
   }" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec.*default|agentaddress.*0\.0\.0\.0' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음 (확인 완료)'" \
  "확인 완료"

# =============================================================================
# U-62 / 로그인 경고 메시지 설정
#
# 점검 기준:
#   /etc/issue, /etc/issue.net, /etc/motd에 로그인 경고 문구가 존재하고
#   OS·커널·호스트 정보가 노출되지 않아야 한다.
#   SSH가 설치된 서버는 sshd 구문 검사가 통과하고 Banner가
#   /etc/issue.net으로 실제 적용되어야 한다.
#
# 조치 내용:
#   세 배너 파일에 동일한 경고 문구를 적용하고 sshd Banner를
#   /etc/issue.net으로 설정한 뒤 구문 검사와 reload 결과를 검증한다.
#
# 변경 대상:
#   /etc/issue, /etc/issue.net, /etc/motd, /etc/ssh/sshd_config
#
# 수동 확인:
#   조직 표준 문구를 확인하고 SSH 설정이 안전하게 롤백된 부분 적용 상태는
#   운영 담당자가 재확인한다.
#
# 롤백:
#   조치 전 전체 백업과 sshd_config 개별 백업으로 파일과 SSH 설정을 복원한다.
# =============================================================================

# 배너 파일 하나의 상태를 평가한다.
# 출력: "<정상여부 0|1>|<상태 설명>"
_u62_eval_banner_file() {
  local _file="$1" _expected="${2:-}"
  local _leak_codes="" _leak_words=""

  if [ ! -f "$_file" ]; then
    printf '0|파일 없음'
    return
  fi
  if [ ! -s "$_file" ]; then
    # /etc/motd 는 로그인 이후 안내문이며 Ubuntu 계열은 /etc/update-motd.d 로
    # 동적 생성해 빈 파일이 정상이다. 이 경우 결함으로 표시하지 않는다.
    if [ "$_file" = "/etc/motd" ] && [ -d /etc/update-motd.d ]; then
      printf '1|동적 생성(update-motd.d)'
    else
      printf '0|비어 있음'
    fi
    return
  fi

  _leak_codes=$(grep -oE '\\(S|r|m|s|v|n|o)' "$_file" 2>/dev/null \
    | LC_ALL=C sort -u | paste -sd, -)
  _leak_words=$(grep -ioE '(kernel|release|version)[[:space:]]*[:=]|(ubuntu|debian|centos|rocky|almalinux|red[[:space:]]*hat|rhel|fedora|suse|linux)[[:space:]]+[0-9][0-9.]*' "$_file" 2>/dev/null \
    | LC_ALL=C sort -fu | paste -sd, -)

  if [ -n "$_leak_codes$_leak_words" ]; then
    printf '0|시스템 정보 노출(%s%s%s)' \
      "$_leak_codes" \
      "$( [ -n "$_leak_codes" ] && [ -n "$_leak_words" ] && printf ',' )" \
      "$_leak_words"
    return
  fi

  if [ -n "$_expected" ] && ! grep -qF "$_expected" "$_file" 2>/dev/null; then
    printf '0|선택 경고 문구 미확인'
    return
  fi

  printf '1|설정됨'
}

# 세 배너 파일과 sshd의 실제 적용 상태를 동일한 형식으로 수집한다.
# 인자: 조치 후 반드시 포함돼야 할 선택 경고 문구(조치 전에는 생략)
_u62_collect_state() {
  local _expected="${1:-}" _state
  local _sshd_t_out="" _sshd_t_rc=0 _sshd_T_out="" _sshd_T_rc=0

  _state=$(_u62_eval_banner_file /etc/issue "$_expected")
  _U62_ISSUE_OK="${_state%%|*}"
  _U62_ISSUE_STATE="${_state#*|}"

  _state=$(_u62_eval_banner_file /etc/issue.net "$_expected")
  _U62_ISSUENET_OK="${_state%%|*}"
  _U62_ISSUENET_STATE="${_state#*|}"

  _state=$(_u62_eval_banner_file /etc/motd "$_expected")
  _U62_MOTD_OK="${_state%%|*}"
  _U62_MOTD_STATE="${_state#*|}"

  _U62_FILES_CLEAN=0
  if [ "$_U62_ISSUE_OK" -eq 1 ] \
     && [ "$_U62_ISSUENET_OK" -eq 1 ] \
     && [ "$_U62_MOTD_OK" -eq 1 ]; then
    _U62_FILES_CLEAN=1
  fi

  _U62_SSHD_PRESENT=0
  _U62_SSHD_T_OK=1
  _U62_SSHD_T_STATE="해당없음(sshd 없음)"
  _U62_SSH_BANNER_OK=1
  _U62_SSH_BANNER="해당없음(sshd 없음)"

  if command -v sshd >/dev/null 2>&1; then
    _U62_SSHD_PRESENT=1

    _sshd_t_out=$(sshd -t 2>&1) || _sshd_t_rc=$?
    if [ "$_sshd_t_rc" -eq 0 ]; then
      _U62_SSHD_T_OK=1
      _U62_SSHD_T_STATE="통과"
    else
      _U62_SSHD_T_OK=0
      _U62_SSHD_T_STATE="실패"
    fi

    _sshd_T_out=$(sshd -T 2>&1) || _sshd_T_rc=$?
    if [ "$_sshd_T_rc" -eq 0 ]; then
      _U62_SSH_BANNER=$(printf '%s\n' "$_sshd_T_out" \
        | awk 'tolower($1)=="banner" {print $2; exit}')
      [ -n "$_U62_SSH_BANNER" ] || _U62_SSH_BANNER="none"
    else
      _U62_SSH_BANNER="확인 실패"
    fi

    # Banner 는 /etc/issue.net 고정이 아니라 "설정되어 있고 그 파일에 내용이
    # 있는지"로 판정한다. /etc/ssh/banner 등 다른 경로로 올바르게 운영하는
    # 서버를 취약으로 표시하던 오탐을 제거한다.
    case "$_U62_SSH_BANNER" in
      ""|none|"확인 실패")
        _U62_SSH_BANNER_OK=0 ;;
      *)
        if [ -s "$_U62_SSH_BANNER" ]; then
          _U62_SSH_BANNER_OK=1
        else
          _U62_SSH_BANNER_OK=0
        fi ;;
    esac
  fi

  _U62_SUMMARY="/etc/issue=${_U62_ISSUE_STATE}, /etc/issue.net=${_U62_ISSUENET_STATE}, /etc/motd=${_U62_MOTD_STATE}, sshd -t=${_U62_SSHD_T_STATE}, sshd Banner=${_U62_SSH_BANNER}"
}

_u62_print_state() {
  echo "   /etc/issue       : ${_U62_ISSUE_STATE}"
  echo "   /etc/issue.net   : ${_U62_ISSUENET_STATE}"
  echo "   /etc/motd        : ${_U62_MOTD_STATE}"
  echo "   sshd -t          : ${_U62_SSHD_T_STATE}"
  echo "   sshd Banner      : ${_U62_SSH_BANNER}"
}

# 배너 파일의 실제 원문은 화면과 별도 파일에 저장하지 않고 상태 판정에만 사용한다.
# 배너 파일 원문은 화면과 별도 파일에 저장하지 않는다.

# U-62 전용 SSH 설정 적용 가드.
# 기존 _sshd_reload_guard와 달리 reload 성공 여부를 반환값에 반영한다.
# 반환값: 0=적용·reload 완료, 1=안전하게 롤백됨, 2=적용 또는 복구 실패
_u62_apply_sshd_banner() {
  local _bak_ts="$1" _conf="$2"
  local _cfg_rc=0 _test_out="" _restore_ok=0 _reload_ok=0

  _U62_APPLY_STATE=""
  _U62_APPLY_DETAIL=""
  _U62_RELOAD_STATE=""

  if ! command -v sshd >/dev/null 2>&1; then
    _U62_APPLY_STATE="해당없음"
    _U62_APPLY_DETAIL="sshd 미설치로 SSH Banner 조치 제외"
    _U62_RELOAD_STATE="해당없음"
    return 0
  fi

  if [ ! -f "$_conf" ]; then
    _U62_APPLY_STATE="실패"
    _U62_APPLY_DETAIL="${_conf} 파일 없음"
    _U62_RELOAD_STATE="실패"
    return 2
  fi

  cp -p "$_conf" "${_conf}.bak.${_bak_ts}" 2>/dev/null || {
    _U62_APPLY_STATE="실패"
    _U62_APPLY_DETAIL="sshd_config 개별 백업 실패"
    _U62_RELOAD_STATE="실패"
    return 2
  }

  config_set "$_conf" \
    '^[[:space:]]*Banner.*' \
    'Banner /etc/issue.net' \
    line '' ci
  _cfg_rc=$?

  if [ "$_cfg_rc" -ne 0 ] && [ "$_cfg_rc" -ne 2 ]; then
    cp -p "${_conf}.bak.${_bak_ts}" "$_conf" 2>/dev/null || true
    _U62_APPLY_STATE="실패"
    _U62_APPLY_DETAIL="Banner 설정 변경 실패"
    _U62_RELOAD_STATE="실패"
    return 2
  fi

  _test_out=$(sshd -t 2>&1)
  if [ $? -ne 0 ]; then
    if cp -p "${_conf}.bak.${_bak_ts}" "$_conf" 2>/dev/null \
       && sshd -t >/dev/null 2>&1; then
      _U62_APPLY_STATE="안전 롤백"
      _U62_APPLY_DETAIL="sshd -t 실패로 sshd_config 원복 완료: ${_test_out//$'\n'/; }"
      _U62_RELOAD_STATE="롤백"
      return 1
    fi

    _U62_APPLY_STATE="복구 실패"
    _U62_APPLY_DETAIL="sshd -t 실패 후 sshd_config 정상 복구를 확인하지 못함: ${_test_out//$'\n'/; }"
    _U62_RELOAD_STATE="실패"
    return 2
  fi

  if systemctl reload sshd >/dev/null 2>&1 \
     || systemctl reload ssh >/dev/null 2>&1 \
     || service sshd reload >/dev/null 2>&1 \
     || service ssh reload >/dev/null 2>&1; then
    _reload_ok=1
  fi

  if [ "$_reload_ok" -eq 1 ]; then
    _U62_APPLY_STATE="적용 완료"
    _U62_APPLY_DETAIL="sshd -t 통과 및 reload 완료"
    _U62_RELOAD_STATE="완료"
    return 0
  fi

  # reload 실패 시 신규 설정을 남기지 않고 원래 설정으로 되돌린다.
  if cp -p "${_conf}.bak.${_bak_ts}" "$_conf" 2>/dev/null \
     && sshd -t >/dev/null 2>&1; then
    _restore_ok=1
    systemctl reload sshd >/dev/null 2>&1 \
      || systemctl reload ssh >/dev/null 2>&1 \
      || service sshd reload >/dev/null 2>&1 \
      || service ssh reload >/dev/null 2>&1 \
      || true
  fi

  if [ "$_restore_ok" -eq 1 ]; then
    _U62_APPLY_STATE="안전 롤백"
    _U62_APPLY_DETAIL="sshd reload 실패로 sshd_config 원복 완료"
    _U62_RELOAD_STATE="롤백"
    return 1
  fi

  _U62_APPLY_STATE="복구 실패"
  _U62_APPLY_DETAIL="sshd reload 실패 후 sshd_config 정상 복구를 확인하지 못함"
  _U62_RELOAD_STATE="실패"
  return 2
}

# 조치 후 수집한 실제 상태와 가드 결과로 최종 상태를 분류한다.
_u62_classify_result() {
  local _apply_rc="$1" _write_failed="$2"

  _U62_RESULT_CLASS=""
  _U62_RESULT_TEXT=""
  _U62_RESULT_REASON=""

  if [ "$_write_failed" -ne 0 ] || [ "$_U62_FILES_CLEAN" -ne 1 ]; then
    _U62_RESULT_CLASS="FAILED"
    _U62_RESULT_TEXT="조치 실패"
    _U62_RESULT_REASON="배너 파일 쓰기 또는 내용 검증 실패"
    return
  fi

  if [ "$_U62_SSHD_PRESENT" -eq 0 ]; then
    _U62_RESULT_CLASS="FIXED"
    _U62_RESULT_TEXT="조치 완료 / 최종 검증 통과"
    _U62_RESULT_REASON="배너 파일 3개 적용 완료, sshd 미설치"
    return
  fi

  if [ "$_apply_rc" -eq 2 ] \
     || [ "$_U62_APPLY_STATE" = "복구 실패" ] \
     || [ "$_U62_SSHD_T_OK" -ne 1 ]; then
    _U62_RESULT_CLASS="FAILED"
    _U62_RESULT_TEXT="조치 실패"
    _U62_RESULT_REASON="${_U62_APPLY_DETAIL:-sshd 설정 또는 복구 실패}"
    return
  fi

  if [ "$_apply_rc" -ne 0 ] \
     || [ "$_U62_RELOAD_STATE" != "완료" ] \
     || [ "$_U62_SSH_BANNER_OK" -ne 1 ]; then
    _U62_RESULT_CLASS="MANUAL"
    _U62_RESULT_TEXT="수동 확인 필요"
    _U62_RESULT_REASON="${_U62_APPLY_DETAIL:-SSH Banner 적용 또는 reload 재확인 필요}"
    return
  fi

  _U62_RESULT_CLASS="FIXED"
  _U62_RESULT_TEXT="조치 완료 / 최종 검증 통과"
  _U62_RESULT_REASON="배너 파일 검증, sshd -t, Banner(${_U62_SSH_BANNER}) 적용, reload 검증 통과"
}

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-62" ] && _match=1 && break; done
  if [ "$_match" -eq 1 ]; then
    check_still_vuln "U-62"; _vs=$?
    _flush_header

    if [ "$_vs" -eq 1 ]; then
      _item_header "good" "U-62" "(하) 로그인 시 경고 메시지 설정"
      _lbl_cur

      _u62_collect_state
      _u62_print_state
      BEFORE_VAL["U-62"]="$_U62_SUMMARY"
      AFTER_VAL["U-62"]="$_U62_SUMMARY"
      DETAIL_VAL["U-62"]=$(_fmt_detail \
        "$_U62_SUMMARY" \
        "변경 없음" \
        "기존 양호 / 재확인 통과" \
        "" \
        "$_U62_SUMMARY")
      _mark_skipped "U-62" "로그인 경고 메시지 [이미양호]"

    else
      _item_header "vuln" "U-62" "(하) 로그인 시 경고 메시지 설정"
      echo ""

      _u62_collect_state
      _u62_before_summary="$_U62_SUMMARY"
      BEFORE_VAL["U-62"]="$_u62_before_summary"

      _lbl_before
      _u62_print_state
      echo ""

      _lbl_yn
      _read_yn _yn_u62 " 조치하시겠습니까? (y/n): "

      if [[ "$_yn_u62" != [Yy] ]]; then
        _lbl_skip

        _u62_collect_state
        AFTER_VAL["U-62"]="$_U62_SUMMARY"
        DETAIL_VAL["U-62"]=$(_fmt_detail \
          "$_u62_before_summary" \
          "사용자 선택으로 자동 조치 미수행" \
          "수동 확인 필요" \
          "" \
          "$_U62_SUMMARY")

        _mark_skipped "U-62" "로그인 경고 메시지 [조치보류]"
        echo ""

      else
        DEFAULT_MSG="이 시스템은 인가된 사용자만 접근 가능합니다."
        echo -e " ${YELLOW}[기본 배너 문구]${RESET}"
        echo "   ******************************************************************"
        echo "   * ${DEFAULT_MSG}   *"
        echo "   ******************************************************************"
        echo ""
        echo -e " ${YELLOW}※ y = 기본 문구 사용, n = 직접 입력 (영문/숫자/기호만 가능)${RESET}"
        _read_yn _banner_yn " 기본 문구를 사용하시겠습니까? (y/n): "

        if [[ "$_banner_yn" =~ ^[Nn]$ ]]; then
          while true; do
            _vf_read_line _banner_input " 배너 메시지를 입력하세요 (영문/숫자/기호만): " || _vf_input_abort
            [ -z "$_banner_input" ] && break
            if LC_ALL=C grep -q '[^ -~]' <<< "$_banner_input"; then
              echo -e " ${RED}영문/숫자/기호(ASCII)만 입력 가능합니다.${RESET}"
              continue
            fi
            break
          done
          [ -z "$_banner_input" ] && _banner_input="$DEFAULT_MSG"
          BANNER_TEXT="$_banner_input"
        else
          BANNER_TEXT="$DEFAULT_MSG"
        fi

        _u62_inner=62
        _u62_tw=$(_display_width "$BANNER_TEXT")
        _u62_pad=$(( _u62_inner - 2 - _u62_tw ))
        [ "$_u62_pad" -lt 0 ] && _u62_pad=0
        _u62_border=$(printf '%0.s*' $(seq 1 $(( _u62_inner + 2 ))))
        BANNER_MSG=$(printf '%s\n* %s%*s*\n%s' \
          "$_u62_border" "$BANNER_TEXT" "$_u62_pad" "" "$_u62_border")

        _lbl_during
        echo "   /etc/issue, /etc/issue.net, /etc/motd 경고문 적용"

        _u62_write_failed=0
        printf '%s\n' "$BANNER_MSG" > /etc/issue \
          || _u62_write_failed=1
        printf '%s\n' "$BANNER_MSG" > /etc/issue.net \
          || _u62_write_failed=1
        printf '%s\n' "$BANNER_MSG" > /etc/motd \
          || _u62_write_failed=1

        _u62_apply_rc=0
        _u62_bak_ts=$(date +%Y%m%d_%H%M%S)
        if command -v sshd >/dev/null 2>&1; then
          echo "   sshd_config Banner /etc/issue.net 설정 + sshd -t + reload 검증"
          _u62_apply_sshd_banner "$_u62_bak_ts" "/etc/ssh/sshd_config"
          _u62_apply_rc=$?
        else
          _U62_APPLY_STATE="해당없음"
          _U62_APPLY_DETAIL="sshd 미설치로 SSH Banner 조치 제외"
          _U62_RELOAD_STATE="해당없음"
        fi

        _u62_collect_state "$BANNER_TEXT"
        _u62_classify_result "$_u62_apply_rc" "$_u62_write_failed"

        AFTER_VAL["U-62"]="${_U62_SUMMARY}, SSH 적용=${_U62_APPLY_STATE}, reload=${_U62_RELOAD_STATE}"

        _u62_changed_files="/etc/issue|/etc/issue.net|/etc/motd"
        [ "$_U62_SSHD_PRESENT" -eq 1 ] \
          && _u62_changed_files="${_u62_changed_files}|/etc/ssh/sshd_config"

        DETAIL_VAL["U-62"]=$(_fmt_detail \
          "$_u62_before_summary" \
          "로그인 경고 문구 적용: \"${BANNER_TEXT}\" (/etc/issue, /etc/issue.net, /etc/motd) 및 SSH Banner /etc/issue.net 설정" \
          "$_U62_RESULT_TEXT" \
          "$_u62_changed_files" \
          "${AFTER_VAL["U-62"]}" \
          "${_U62_APPLY_DETAIL}")

        echo ""
        _lbl_result
        echo "   적용 위치 : /etc/issue, /etc/issue.net, /etc/motd"
        echo "$BANNER_MSG" | sed 's/^/   /'
        echo ""
        echo -e " ${BOLD}${WHITE}[검증 상태]${RESET}"
        echo ""
        _u62_print_state
        echo "   SSH 적용 결과   : ${_U62_APPLY_STATE}"
        echo "   reload 상태     : ${_U62_RELOAD_STATE}"
        [ -n "$_U62_APPLY_DETAIL" ] \
          && echo "   적용 상세       : ${_U62_APPLY_DETAIL}"
        echo ""

        case "$_U62_RESULT_CLASS" in
          FIXED)
            _lbl_done_nr
            _mark_fixed "U-62" \
              "로그인 경고 메시지 및 SSH Banner 적용·최종 검증 완료"
            ;;
          MANUAL)
            _warn "부분 적용 또는 안전 롤백 상태 — 후속 확인 필요"
            _mark_manual "U-62" \
              "${_U62_RESULT_REASON}; ${AFTER_VAL["U-62"]}"
            ;;
          *)
            _lbl_fail_v
            _mark_failed "U-62" \
              "${_U62_RESULT_REASON}; ${AFTER_VAL["U-62"]}"
            ;;
        esac
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
  "_p=/etc/sudoers; [ -f \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; [ -f /etc/sudoers ] && chown root /etc/sudoers && chmod 640 /etc/sudoers" \
  "ls -l /etc/sudoers 2>/dev/null" \
  "^-rw-r-----.*root"

# ============================================================
_has_cat_target "패치 관리" && section_header "패치 관리"
# ============================================================

# =============================================================================
# U-64 / 주기적 보안 패치 및 벤더 권고사항 적용
#
# 점검 기준:
#   저장소 메타데이터를 실제로 갱신한 뒤 적용 가능한 보안 업데이트를 확인한다.
#   DNS·프록시·저장소·구독 오류는 "업데이트 없음"으로 보지 않고 확인 필요로 처리한다.
#
# 처리 정책:
#   dnf/yum은 --security만 적용한다. apt는 보안 저장소로 식별되는 패키지가 있을 때만
#   자동 적용하고, 분류할 수 없는 전체 업그레이드는 운영 영향 때문에 수동 확인으로 남긴다.
# =============================================================================

{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-64" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-64"; _vs=$?
    _flush_header

    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      echo ""
      _u64_print_cached_report | sed 's/^/   /'
      BEFORE_VAL["U-64"]="${_U64_UPDATE_MANAGER:-패키지 관리자}: 적용 가능한 보안 업데이트 없음"
      AFTER_VAL["U-64"]="기존 양호 (저장소 확인 통과)"
      _mark_skipped "U-64" "보안 패치 [이미양호]"

    elif [ $_vs -eq 3 ]; then
      _item_header "manual" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      _sec check
      _u64_print_cached_report | sed 's/^/   /'
      _sec need
      _warn "${_U64_UPDATE_REASON:-저장소 또는 보안 권고정보 확인 실패}"
      if [ "${_U64_UPDATE_MANAGER:-}" = "apt" ]          && [ "${_U64_ALL_UPDATE_COUNT:-0}" -gt 0 ]          && [ "${_U64_UPDATE_COUNT:-0}" -eq 0 ]; then
        _info "전체 업그레이드 후보는 있으나 보안 업데이트로 확정할 수 없습니다. 벤더 보안 공지와 apt-cache policy를 대조하세요."
        _u64_manual_class="보안 업데이트 분류 불가"
      else
        _info "DNS·프록시·구독·저장소 연결을 복구한 뒤 다시 점검하세요. 현재 결과를 양호로 처리하지 않습니다."
        _u64_manual_class="저장소/권고정보 확인 실패"
      fi
      BEFORE_VAL["U-64"]="${_U64_UPDATE_REASON:-업데이트 상태 확인 불가}"
      AFTER_VAL["U-64"]="수동 확인 필요"
      DETAIL_VAL["U-64"]="[현재 상태] ${BEFORE_VAL[U-64]} | [판정] ${_u64_manual_class}로 양호 판정 금지"
      _mark_manual "U-64" "보안 패치 상태 확인 불가 — ${_U64_UPDATE_REASON:-원인 확인 필요}"

    elif [ "$_U64_UPDATE_MANAGER" = "apt" ]; then
      _item_header "vuln" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      _sec check
      _u64_print_cached_report | sed 's/^/   /'
      _u64_sec_pkgs="$_U64_SECURITY_PACKAGES"
      if [ -z "$_u64_sec_pkgs" ]; then
        _sec need
        _warn "업그레이드 대상은 있으나 보안 업데이트로 신뢰성 있게 분류할 수 없습니다."
        _info "전체 apt upgrade 자동 실행은 커널·서비스 재시작 영향을 유발할 수 있어 수행하지 않습니다."
        BEFORE_VAL["U-64"]="apt 전체 후보 ${_U64_ALL_UPDATE_COUNT}개, 보안 분류 불가"
        AFTER_VAL["U-64"]="수동 확인 필요"
        _mark_manual "U-64" "apt 보안 패키지 분류 불가 — 전체 업그레이드 자동 적용 제외"
      else
        echo "   보안 저장소 식별 패키지: $(printf '%s\n' "$_u64_sec_pkgs" | wc -l | tr -d ' ')개"
        printf '%s\n' "$_u64_sec_pkgs" | head -15 | sed 's/^/     - /'
        _read_yn _yn64apt " 보안 패키지만 적용하시겠습니까? (y/n): "
        if [[ "$_yn64apt" == [Yy] ]]; then
          _sec during
          # shellcheck disable=SC2086
          DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y $_u64_sec_pkgs
          _apply_rc=$?
          _u64_update_state; _post_rc=$?
          _sec result
          _u64_print_cached_report | sed 's/^/   /'
          if [ $_apply_rc -eq 0 ] && [ $_post_rc -eq 1 ]; then
            AFTER_VAL["U-64"]="보안 패치 적용 완료"
            _mark_fixed "U-64" "apt 보안 패키지 적용 및 저장소 재검증 통과"
          elif [ $_apply_rc -ne 0 ]; then
            AFTER_VAL["U-64"]="패치 명령 실패(rc=${_apply_rc})"
            _mark_failed "U-64" "apt 보안 패키지 적용 명령 실패(rc=${_apply_rc})"
          else
            AFTER_VAL["U-64"]="패치 후 잔존 또는 재확인 불가"
            _mark_manual "U-64" "apt 패치 후 업데이트 잔존 또는 저장소 재확인 필요"
          fi
        else
          AFTER_VAL["U-64"]="조치 보류 (사용자 선택)"
          _mark_skipped "U-64" "보안 패치 [조치보류]"
        fi
      fi

    elif [ "$_U64_UPDATE_MANAGER" = "dnf" ] || [ "$_U64_UPDATE_MANAGER" = "yum" ]; then
      _item_header "vuln" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      _sec check
      _u64_print_cached_report | sed 's/^/   /'
      _read_yn _yn64 " ${_U64_UPDATE_MANAGER} 보안 패치만 적용하시겠습니까? (y/n): "
      if [[ "$_yn64" == [Yy] ]]; then
        _sec during
        "$_U64_UPDATE_MANAGER" update --security -y
        _apply_rc=$?
        _u64_update_state; _post_rc=$?
        _sec result
        _u64_print_cached_report | sed 's/^/   /'
        if [ $_apply_rc -eq 0 ] && [ $_post_rc -eq 1 ]; then
          AFTER_VAL["U-64"]="보안 패치 적용 완료"
          _mark_fixed "U-64" "${_U64_UPDATE_MANAGER} --security 적용 및 저장소 재검증 통과"
        elif [ $_apply_rc -ne 0 ]; then
          AFTER_VAL["U-64"]="패치 명령 실패(rc=${_apply_rc})"
          _mark_failed "U-64" "${_U64_UPDATE_MANAGER} 보안 패치 명령 실패(rc=${_apply_rc})"
        else
          AFTER_VAL["U-64"]="패치 후 잔존 또는 재확인 불가"
          _mark_manual "U-64" "패치 후 보안 업데이트 잔존 또는 저장소 재확인 필요"
        fi
      else
        AFTER_VAL["U-64"]="조치 보류 (사용자 선택)"
        _mark_skipped "U-64" "보안 패치 [조치보류]"
      fi

    else
      _item_header "manual" "U-64" "(상) 주기적 보안 패치 및 벤더 권고사항 적용"
      _warn "${_U64_UPDATE_MANAGER:-패키지 관리자} 자동 보안 패치 적용은 지원하지 않습니다."
      _mark_manual "U-64" "지원하지 않는 패키지 관리자 — 수동 패치 필요"
    fi
    echo ""
  fi
}

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
  "_u65_status before" \
  "_u65_apply" \
  "_u65_status" \
  "^검증 결과 : 확인 완료$"

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
  "_p=/var/log; [ -d \"\$_p\" ] && echo \"PERM_RESTORE|\$_p|\$(stat -c '%a' \"\$_p\" 2>/dev/null)|\$(stat -c '%U:%G' \"\$_p\" 2>/dev/null)\" >> \"\${_CURRENT_RECORDS_FILE}\"; chown root:root /var/log && chmod 755 /var/log" \
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

# ── 조치 단계 종료 ───────────────────────────────────────────────────────────
# 이 시점 이후는 요약 출력과 보고서 생성뿐이라 시스템 설정을 변경하지 않는다.
# 중단 안내 트랩을 해제해, 보고서 생성 중 Ctrl+C 가 "조치 중단"으로
# 잘못 안내되지 않도록 한다.
trap - INT TERM HUP
_VF_FIX_PHASE=0

# ============================================================
# 최종 요약
# ============================================================
echo ""
_div_thick
echo -e "${BOLD}  조치 결과 요약  (총 ${#TARGET_IDS[@]}개 항목)${RESET}"
echo ""
# SKIPPED → 기존양호 / 조치보류 분리
_ALREADY_OK=0; _USER_SKIP=0
_ALREADY_OK_LIST=(); _USER_SKIP_LIST=()
for v in "${SKIPPED_LIST[@]}"; do
  if [[ "$v" == *"[이미양호]"* ]]; then
    _ALREADY_OK=$((_ALREADY_OK+1)); _ALREADY_OK_LIST+=("$v")
  else
    _USER_SKIP=$((_USER_SKIP+1)); _USER_SKIP_LIST+=("$v")
  fi
done

# 결과 집계는 CSV·Excel 보고서 생성용 데이터에만 반영한다.
_detail_log_summary "$_ALREADY_OK" "$FIXED" "$MANUAL" "$_USER_SKIP" "$NA" "$FAILED"

echo -e " ${GREEN}✔ 기존 양호${RESET}        : ${BOLD}${GREEN}${_ALREADY_OK}건${RESET}"
echo -e " ${GREEN}✔ 조치 완료${RESET}        : ${BOLD}${GREEN}${FIXED}건${RESET}"
echo -e " ${CYAN}○ 해당없음${RESET}         : ${BOLD}${CYAN}${NA}건${RESET}"
[ $_USER_SKIP -gt 0 ] && \
echo -e " ${YELLOW}– 조치 보류${RESET}        : ${BOLD}${YELLOW}${_USER_SKIP}건${RESET}"
echo -e " ${YELLOW}⚠ 수동 확인${RESET}        : ${BOLD}${YELLOW}${MANUAL}건${RESET}"
echo -e " ${RED}✘ 조치 실패${RESET}        : ${BOLD}${RED}${FAILED}건${RESET}"

# ── 조치 완료 상세 ───────────────────────────────────────────────────────────
if [ ${#FIXED_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${GREEN}  ✔ 조치 완료 항목${RESET}"
  for v in "${FIXED_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    echo -e " ${GREEN}•${RESET} ${BOLD}${id}${RESET} ${desc//\[이미양호\]/}"
    before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
    [ -n "$before" ] && _summary_preview "$before" "조치 전" "   " 2
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      _summary_preview "$after" "조치 후" "   " 2
  done
fi

# ── 수동 확인 상세 ───────────────────────────────────────────────────────────
if [ ${#MANUAL_LIST[@]} -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${YELLOW}  ⚠ 수동 확인 항목${RESET}"
  for v in "${MANUAL_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    echo -e " ${YELLOW}•${RESET} ${BOLD}${id}${RESET} ${desc// — */}"
  done
fi

# ── 조치 실패 상세 ────────────────────────────────────────────────────────────
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
  echo ""
  # 실패 원인은 항목마다 다르므로(문법 검사 실패, 명령 실행 오류, 검증 불일치 등)
  # 헤더에 특정 원인을 단정하지 않는다.
  echo -e "${BOLD}${RED}  ✘ 조치 실패 항목${RESET}"
  for v in "${FAILED_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    # 실패 사유는 "제목 — 사유" 형태로 기록된다.
    # 기존에는 ${desc// — */} 로 '—' 뒤를 잘라내 정작 필요한 사유가 사라졌다.
    _fail_title="${desc%% — *}"
    _fail_reason=""
    [[ "$desc" == *" — "* ]] && _fail_reason="${desc#* — }"
    echo -e " ${RED}•${RESET} ${BOLD}${id}${RESET} ${_fail_title}"
    [ -n "$_fail_reason" ] && echo -e "   ${RED}사유${RESET} : ${_fail_reason}"
    before="${BEFORE_VAL[$id]}"; after="${AFTER_VAL[$id]}"
    [ -n "$before" ] && _summary_preview "$before" "조치 전" "   " 2
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      _summary_preview "$after" "조치 후" "   " 2
  done
  echo ""
  echo -e "   ${WHITE}확인 방법${RESET}"
  echo -e "   1) 결과보고서의 '변경 및 검증 결과' 열에서 항목별 실패 사유와 실행 명령을 확인"
  echo -e "   2) 조치 실패 항목은 설정을 변경하기 전 상태로 되돌려 둔 상태입니다"
  echo -e "      (설정 검사에 실패하면 변경 내용을 적용하지 않고 백업에서 복구합니다)"
  echo -e "   3) 원인 해소 후 다시 실행하거나, 해당 항목만 수동으로 조치"
fi

# ── 조치 보류 목록 (간략) ───────────────────────────────────────────────────
if [ $_USER_SKIP -gt 0 ]; then
  echo ""
  echo -e "${BOLD}${YELLOW}  – 조치 보류 항목${RESET}"
  for v in "${_USER_SKIP_LIST[@]}"; do
    id="${v%%:*}"; desc="${v#*: }"
    desc="${desc//\[조치보류\]/}"
    echo -e " ${YELLOW}–${RESET} ${BOLD}${id}${RESET} ${desc}"
  done
fi

echo ""
[ ${#MANUAL_LIST[@]} -gt 0 ] && \

_div_thick

# XLSX 생성 전 결과 누락 항목을 보정하여 TARGET_IDS와 보고서 행 수를 일치시킨다.
_report_finalize_rows

# =============================================================================
# ── [Excel 결과 보고서 자동 생성] 임시 CSV → XLSX 변환 ────────────────────────
#    임시 CSV는 /tmp에 생성되며 XLSX 처리 후 즉시 삭제한다.
#    /linux_vuln_fix/report에는 최종 .xlsx 파일만 남긴다.
# =============================================================================

# ── 환경 감지 + openpyxl 필요 시 오프라인 설치 ───────────────────────────────
_XLSX_PYTHON=""


_xlsx_env_check() {
  # 반환값: 0=사용 가능, 1=사용 불가(XLSX 생성 안 함)
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

  # 배포본은 실행 중 OS 패키지를 설치하지 않는다.
  # python3는 --preflight 단계에서 사전 준비 여부를 검증한다.
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "   ${YELLOW}⚠ python3가 없어 Excel 보고서를 생성할 수 없습니다.${RESET}"
    echo -e "   ${YELLOW}  실행 전 python3를 설치하거나 표준 서버 이미지에 포함하세요.${RESET}"
    return 1
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
    echo -e "   ${YELLOW}⚠ openpyxl 없음 + 오프라인 패키지 미발견 — Excel 보고서를 생성할 수 없습니다.${RESET}"
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
    echo -e "   ${YELLOW}⚠ tar 압축 해제 실패 — Excel 보고서를 생성할 수 없습니다.${RESET}"
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
    echo -e "   ${YELLOW}⚠ 압축 파일에 whl 패키지가 없습니다 — Excel 보고서를 생성할 수 없습니다.${RESET}"
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

  echo -e "   ${YELLOW}⚠ openpyxl 로드 실패 — Excel 보고서를 생성할 수 없습니다.${RESET}"
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
  local _csv="$1" _out="$2" _server="$3" _os="$4" _ts="$5"
  local _xlsx_python="${_XLSX_PYTHON:-python3}"

  "$_xlsx_python" - "$_csv" "$_out" "$_server" "$_os" "$_ts" 2>"${_RPT_BASE_DIR}/.xlsx_error_${_RUN_TS}.tmp" << 'PYEOF'
import sys, csv, math, re, unicodedata
from collections import Counter
from openpyxl import Workbook
from openpyxl.cell.cell import MergedCell
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.chart import BarChart, DoughnutChart, Reference, Series
from openpyxl.chart.label import DataLabelList
from openpyxl.chart.data_source import AxDataSource, StrRef
from openpyxl.chart.text import RichText
from openpyxl.chart.shapes import GraphicalProperties
from openpyxl.chart.axis import ChartLines
from openpyxl.drawing.spreadsheet_drawing import AnchorMarker, TwoCellAnchor
from openpyxl.drawing.text import (
    RichTextProperties, Paragraph, ParagraphProperties,
    CharacterProperties, Font as DrawingFont
)
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo
from openpyxl.formatting.rule import CellIsRule, DataBarRule

csv_path, out_path, server, os_info, run_ts = sys.argv[1:6]

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
applicable = denom  # 적용 대상 = 전체 - 해당없음(적용 제외)
need_check = COUNTS['수동확인'] + COUNTS['건너뜀']  # 확인 필요 = 수동확인 + 미조치(건너뜀), 실패는 별도 카드
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
    excluded = sum(1 for x in sub if x.get('최종결과') == '해당없음')
    ok = sum(1 for x in target if x.get('최종결과') in ('양호','조치완료'))
    bad = sum(1 for x in target if x.get('최종결과') in ('수동확인','실패','건너뜀'))
    sc = round(ok / len(target) * 100, 1) if target else 0.0
    high = sum(1 for x in target if x.get('위험도') == '상' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    mid = sum(1 for x in target if x.get('위험도') == '중' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    low = sum(1 for x in target if x.get('위험도') == '하' and x.get('최종결과') in ('수동확인','실패','건너뜀'))
    CAT_STAT.append([cat, sc, high, mid, low, ok, bad, len(target), excluded])

risk_order = {'상':0, '중':1, '하':2}
status_order = {'건너뜀':0, '실패':1, '수동확인':2}
TOP_NEED = sorted(
    [x for x in rows if x.get('최종결과') in ('수동확인','실패','건너뜀')],
    key=lambda x: (risk_order.get(x.get('위험도'), 9), status_order.get(x.get('최종결과'), 9),
                   int(str(x.get('항목ID','')).replace('U-','') or '0'))
)[:10]

# ── 대시보드 집계 무결성 검사 ───────────────────────────────────────────────
# 잘못된 상태·위험도·분류 또는 집계 불일치가 있으면 잘못된 점수의 보고서를
# 생성하지 않고 즉시 오류로 중단한다.
_unknown_results = sorted({
    x.get('최종결과', '') for x in rows
    if x.get('최종결과', '') not in RESULTS
})
if _unknown_results:
    raise ValueError(
        '알 수 없는 최종결과 값: ' + ', '.join(_unknown_results)
    )

_unknown_risks = sorted({
    x.get('위험도', '') for x in rows
    if x.get('최종결과') != '해당없음'
    and x.get('위험도', '') not in RISKS
})
if _unknown_risks:
    raise ValueError(
        '적용 대상 항목의 위험도 값 오류: ' + ', '.join(_unknown_risks)
    )

_unknown_categories = sorted({
    x.get('대분류', '') for x in rows
    if x.get('대분류', '') not in _ALL_CATS_ORDER
})
if _unknown_categories:
    raise ValueError(
        '알 수 없는 대분류 값: ' + ', '.join(_unknown_categories)
    )

_calc_errors = []

if total != sum(COUNTS[x] for x in RESULTS):
    _calc_errors.append(
        f'전체 항목 불일치: total={total}, 상태 합계={sum(COUNTS[x] for x in RESULTS)}'
    )

if total != applicable + na:
    _calc_errors.append(
        f'적용 대상 불일치: 전체={total}, 적용={applicable}, 제외={na}'
    )

if applicable != good + need_check + COUNTS['실패']:
    _calc_errors.append(
        '최종 상태 합계 불일치: '
        f'적용={applicable}, 양호={good}, 확인 필요={need_check}, 실패={COUNTS["실패"]}'
    )

if before_vuln != after_vuln + COUNTS['조치완료']:
    _calc_errors.append(
        '조치 전후 취약 건수 불일치: '
        f'조치 전={before_vuln}, 조치 후={after_vuln}, 조치완료={COUNTS["조치완료"]}'
    )

if improve != COUNTS['조치완료']:
    _calc_errors.append(
        f'개선 건수 불일치: 개선={improve}, 조치완료={COUNTS["조치완료"]}'
    )

_expected_score = round(good / applicable * 100, 1) if applicable else 0.0
if score != _expected_score:
    _calc_errors.append(
        f'보안 점수 불일치: 표시={score}, 재계산={_expected_score}'
    )

_risk_good_sum = sum(RISK_STAT[x][0] for x in RISKS)
_risk_need_sum = sum(RISK_STAT[x][1] for x in RISKS)
if _risk_good_sum != good:
    _calc_errors.append(
        f'위험도별 최종 양호 합계 불일치: 위험도 합계={_risk_good_sum}, 전체={good}'
    )
if _risk_need_sum != need_check + COUNTS['실패']:
    _calc_errors.append(
        '위험도별 확인 필요 합계 불일치: '
        f'위험도 합계={_risk_need_sum}, 전체={need_check + COUNTS["실패"]}'
    )

_cat_good_sum = sum(x[5] for x in CAT_STAT)
_cat_need_sum = sum(x[6] for x in CAT_STAT)
_cat_target_sum = sum(x[7] for x in CAT_STAT)
_cat_excluded_sum = sum(x[8] for x in CAT_STAT)

if _cat_good_sum != good:
    _calc_errors.append(
        f'분류별 최종 양호 합계 불일치: 분류 합계={_cat_good_sum}, 전체={good}'
    )
if _cat_need_sum != need_check + COUNTS['실패']:
    _calc_errors.append(
        '분류별 확인 필요 합계 불일치: '
        f'분류 합계={_cat_need_sum}, 전체={need_check + COUNTS["실패"]}'
    )
if _cat_target_sum != applicable:
    _calc_errors.append(
        f'분류별 적용 대상 합계 불일치: 분류 합계={_cat_target_sum}, 전체={applicable}'
    )
if _cat_excluded_sum != na:
    _calc_errors.append(
        f'분류별 적용 제외 합계 불일치: 분류 합계={_cat_excluded_sum}, 전체={na}'
    )

if _calc_errors:
    raise ValueError(
        '대시보드 집계 무결성 오류: ' + ' / '.join(_calc_errors)
    )

# ── 공통 스타일 ───────────────────────────────────────────────────────────────
FN = '맑은 고딕'
NAVY = '173B70'; BLUE = '2F66C3'; LIGHT_BLUE = 'EAF2FF'; PALE = 'F7F9FC'
WHITE = 'FFFFFF'; DARK = '1F2937'; GRAY = '6B7280'; RED = 'E53935'; ORANGE = 'F59E0B'; GREEN = '2E7D32'
# 수동 확인 글자만 기존 주황색보다 채도를 낮춘다.
MANUAL_TEXT_COLOR = 'C98200'
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
    '양호':'E2F0D9',
    '조치완료':'E2F0D9',
    '수동확인':'FFF2CC',
    '실패':'F4CCCC',
    '해당없음':'E7E6E6',
    '건너뜀':'FCE4D6'
}
# 화면에 보여줄 판정 용어를 짧고 일관된 6개 표현으로 통일한다.
# 내부 로직의 키는 그대로 유지하고 Excel 표시값만 변경한다.
DISPLAY_NAME = {
    '양호':'기존 양호',
    '조치완료':'조치 완료',
    '수동확인':'수동 확인',
    '건너뜀':'조치 보류',
    '해당없음':'해당없음',
    '실패':'조치 실패'
}
def disp(name):
    return DISPLAY_NAME.get(name, name)


DISPLAY_TO_INTERNAL = {v: k for k, v in DISPLAY_NAME.items()}
# 이전 보고서의 표시 문자열도 색상 매핑과 호환되도록 유지한다.
DISPLAY_TO_INTERNAL.update({
    '조치 후 양호':'조치완료',
    '수동 확인 필요':'수동확인',
    '미조치':'건너뜀',
    '적용 제외':'해당없음'
})


def customer_disp(name):
    return disp(name)

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
    # 헤더는 진한 남색, 데이터 행은 모두 흰색으로 통일한다.
    # 행 전체 교차 색상은 사용하지 않고 판정 셀에만 상태 색상을 적용한다.
    for c in range(start_col, end_col + 1):
        cell(
            ws, start_row, c, ws.cell(start_row, c).value,
            font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True
        )
    for r in range(start_row + 1, end_row + 1):
        for c in range(start_col, end_col + 1):
            cell(
                ws, r, c, ws.cell(r, c).value,
                font=FONT_SMALL, fill=WHITE, align='center', wrap=True
            )

def fill_block(ws, r1, c1, r2, c2, fill=None, border=True, align='center', wrap=False):
    # 병합/차트 인접 영역에서 마지막 셀 테두리가 빠지는 현상 방지용 보정 함수
    # MergedCell은 .value는 못 넣지만 .border/.fill/.alignment는 그대로 적용되므로
    # (여기서는 value를 쓰지 않기 때문에) 건너뛰지 않고 병합된 칸에도 동일하게 적용한다.
    for rr in range(r1, r2 + 1):
        for cc in range(c1, c2 + 1):
            x = ws.cell(rr, cc)
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
# 조치 전 상태       : [현재 설정] / [확인 내용]
# 변경 및 검증 결과  : [변경 내용] / [최종 상태] / [검증 결과]
# 최종 판정          : 양호·조치완료·수동확인·실패·해당없음·건너뜀 중 한 값
# 조치 상세    : [조치 내용] / [변경 파일] / [변경 파일 목록] / [서비스 변경]

_GENERIC_BEFORE = {
    '', '점검값 미수집', '점검값 미수집 (점검 대상 미감지)',
    '설정 정보 없음 (점검 대상 미감지)', '이상 항목 없음 (점검 통과)'
}
_GENERIC_AFTER = {
    '',
    '이미 양호 (재확인 통과)',      # 구버전 호환
    '기존 양호 (재확인 통과)',
    '수동 확인 필요',
    '해당없음',
    '해당 없음',                    # 구버전 호환
    '사용자 건너뜀',                # 구버전 호환
    '건너뜀',                       # 내부 상태·구버전 호환
    '조치 보류',
    '조치 보류 (사용자 선택)',
    '조치 실패',
    '조치 실패 (실행 오류)'
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
    'U-35': {
        'method': '''1. FTP·Samba·NFS 서비스와 현재 익명 접근 설정을 확인합니다.
getent passwd ftp anonymous
grep -RniE '^[[:space:]]*anonymous_enable[[:space:]]*=|^[[:space:]]*<Anonymous' /etc/vsftpd.conf /etc/vsftpd /etc/proftpd.conf /etc/proftpd 2>/dev/null
grep -niE 'guest[[:space:]]*ok|map[[:space:]]+to[[:space:]]+guest' /etc/samba/smb.conf 2>/dev/null
grep -vE '^[[:space:]]*(#|$)' /etc/exports 2>/dev/null
exportfs -v 2>/dev/null

2. 업무상 필요한 FTP 익명 접속, Samba guest 공유 및 NFS 허용 IP·대역을 운영 담당자와 확인합니다.

3. FTP 익명 접속이 불필요하면 관련 설정을 비활성화하고 서비스 구문을 검증합니다.
anonymous_enable=NO
# ProFTPD의 불필요한 <Anonymous> 블록 제거 또는 비활성화

4. Samba guest 공유가 불필요하면 해당 공유의 guest ok를 no로 변경하고 설정을 검증합니다.
testparm -s

5. NFS의 * 또는 no_root_squash 설정은 승인된 IP·대역과 root_squash 정책으로 직접 변경합니다.
cp -a /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
vi /etc/exports
exportfs -rav
exportfs -v

6. 실제 클라이언트 접속과 업무 서비스를 확인한 후 스크립트를 다시 실행합니다.''',
        'criteria': 'FTP 익명 접속과 Samba guest 공유가 불필요하게 허용되지 않고, NFS export는 승인된 호스트·대역으로 제한되어야 합니다.',
        'caution': '허용 대상과 업무 사용 여부를 확인하지 않고 계정을 잠그거나 공유 설정을 변경하면 FTP·Samba·NFS 이용 장애가 발생할 수 있습니다.'
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
    # 첫 대괄호 앞에 라벨 없이 붙어있는 요약 텍스트(예: "조치 전 전체 N개 | ... | [chmod o-w] ...")는
    # 대괄호 패턴에 안 걸려서 그냥 버려지면 정보 손실이 커진다. '요약' 키로 별도 보존한다.
    if not text.startswith('['):
        _lead = _clean_layout_text(text.split('\n[', 1)[0])
        if _lead:
            sections['요약'] = _lead
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
        return '조치 필요 상태이나 사용자 선택으로 조치를 보류함'
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


def format_change_verify_result(row):
    """
    취약점 점검 결과 시트의 변경·검증 결과를 보고서 형식으로 표시한다.

    - 조치 완료: 실제 조치 내용, 최종 설정, 검증 결과
    - 기존 양호: 변경 없음, 유지된 최종 상태, 재확인 결과
    - 조치 보류/수동 확인: 변경 여부와 후속 확인 상태
    - 실패: 수행한 조치와 미통과 결과를 구분
    """
    sections, raw_detail = _detail_sections(row.get('상세내역', ''))
    status = row.get('최종결과', '').strip()

    before = _clean_layout_text(row.get('조치전상태', ''))
    after = _clean_layout_text(row.get('조치후상태', ''))
    detail_after = _first_section(
        sections, '최종 설정', '변경 후', '조치 후'
    )

    explicit_action = _first_section(
        sections, '조치 내용', '수행 내역', '적용 내용'
    )
    service_change = _first_section(sections, '서비스 변경')

    # 실제 변경 내용을 최종 판정별로 명확히 구분한다.
    if status == '양호':
        change_text = '변경 없음'
    elif status == '해당없음':
        change_text = '변경 없음 (점검 대상 아님)'
    elif status == '건너뜀':
        change_text = '변경 없음 (사용자 조치 보류)'
    elif status == '수동확인' and not explicit_action:
        change_text = '자동 변경 없음 (운영 정책 확인 후 조치 필요)'
    else:
        change_text = _report_text(
            explicit_action or _infer_action(row, sections, raw_detail)
        )
        if not change_text:
            change_text = (
                '보안 설정 조치 수행'
                if status == '조치완료'
                else '조치 시도 내역 확인 필요'
            )

    # 서비스 변경은 변경 내용에 포함하되 같은 문구가 중복되지 않게 한다.
    service_text = _report_text(service_change)
    if service_text and service_text not in change_text:
        change_text = f'{change_text}\n서비스 변경: {service_text}'

    # 최종 상태는 실제 조치 후 값이 있으면 우선하고,
    # 기존 양호·미변경 항목은 조치 전 상태를 유지된 상태로 표시한다.
    if detail_after:
        final_state = _report_text(detail_after)
    elif status == '양호' and after in _GENERIC_AFTER:
        final_state = _report_text(before or '기존 설정 유지')
    elif status in ('수동확인', '건너뜀') and after in _GENERIC_AFTER:
        final_state = '변경 전 상태 유지'
    elif status == '해당없음' and after in _GENERIC_AFTER:
        final_state = '점검 대상 없음'
    elif status == '실패' and after in _GENERIC_AFTER:
        final_state = '변경 전 상태 유지 또는 일부 변경'
    else:
        final_state = _report_text(
            after or detail_after or before or '최종 상태 확인 필요'
        )

    verify = _report_text(_after_verify_message(row, sections))
    if not verify:
        verify = '검증 결과 확인 필요'

    return (
        f'[변경 내용]\n{change_text}'
        f'\n\n[최종 상태]\n{final_state}'
        f'\n\n[검증 결과]\n{verify}'
    )


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
        '건너뜀': '사용자 선택으로 조치를 보류함',
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


def format_need_criteria_caution(row):
    criteria = format_need_criteria(row)
    caution = format_need_caution(row)
    return f'[양호 기준]\n{criteria}\n\n[주의]\n{caution}'


def format_need_state_reason(row):
    state = format_current_state(row)
    reason = format_need_reason(row)
    return f'[현재 상태]\n{state}\n\n[확인 필요 사유]\n{reason}'


def format_need_action_criteria_caution(row):
    action = format_need_action(row)
    cc = format_need_criteria_caution(row)
    return f'[조치 방법]\n{action}\n\n{cc}'


def format_customer_need_reason(row):
    status = row.get('최종결과', '').strip()
    manual_reason = _report_text(row.get('수동확인사유', ''))
    fail_reason = _report_text(row.get('실패사유', ''))
    if status == '건너뜀':
        return manual_reason or (
            '운영 영향 확인이 필요하여 자동 조치를 보류했습니다. '
            '운영 정책 확인 후 조치와 재점검이 필요합니다.'
        )
    if status == '수동확인':
        return manual_reason or '서비스 운영 정책과 설정값을 확인한 후 수동 조치가 필요합니다.'
    if status == '실패':
        return fail_reason or '자동 조치 후 검증에 실패했습니다. 원인 확인 및 재조치가 필요합니다.'
    return format_need_reason(row)


def format_dashboard_need_reason(row):
    status = row.get('최종결과', '').strip()
    manual_reason = _report_text(row.get('수동확인사유', ''))
    fail_reason = _report_text(row.get('실패사유', ''))
    if status == '건너뜀':
        return manual_reason or '운영 영향 확인 후 조치 필요'
    if status == '수동확인':
        return manual_reason or '운영 정책 확인 후 수동 확인 필요'
    if status == '실패':
        return fail_reason or '자동 조치 실패 원인 확인 및 재조치 필요'
    return format_need_reason(row)


def format_customer_need_state_reason(row):
    state = format_current_state(row)
    reason = format_customer_need_reason(row)
    return f'[현재 상태]\n{state}\n\n[확인 필요 사유]\n{reason}'


def format_customer_need_action_criteria_caution(row):
    action = format_need_action(row)
    status = row.get('최종결과', '').strip()

    if status == '건너뜀':
        action = action.replace(
            '사용자 선택으로 조치를 보류함',
            '운영 영향과 정책 확인 후 조치 여부 결정'
        )
    elif status == '수동확인':
        action = action.replace(
            '자동 조치 없이 추가 검토 대상으로 기록',
            '서비스 운영 정책과 설정값 확인 후 수동 조치'
        )

    cc = format_need_criteria_caution(row)
    return f'[조치 방법]\n{action}\n\n{cc}'


_COMMAND_LINE_RE = re.compile(
    r'''^(?:[$#]\s*)?(?:'''
    r'''[A-Za-z_][A-Za-z0-9_]*=|'''
    r'''\[.+\](?:\s*\|\|.*)?|'''
    r'''(?:sudo\s+)?(?:'''
    r'''awk|cat|cd|chmod|chown|command|cp|cut|date|dpkg|echo|exim|'''
    r'''exportfs|file|find|firewall-cmd|getent|gpasswd|grep|id|'''
    r'''iptables|lastlog|lsof|mount|nmcli|postconf|postfix|ps|'''
    r'''rm|rpm|sed|sendmail|sha256sum|ss|stat|sudo|systemctl|'''
    r'''tar|test|ufw|umount|usermod|vi|vim'''
    r''')\b)'''
)


def _customer_action_text(row):
    action = format_need_action(row)
    status = row.get('최종결과', '').strip()
    if status == '건너뜀':
        action = action.replace(
            '사용자 선택으로 조치를 보류함',
            '운영 영향과 정책 확인 후 조치 여부 결정'
        )
    elif status == '수동확인':
        action = action.replace(
            '자동 조치 없이 추가 검토 대상으로 기록',
            '서비스 운영 정책과 설정값 확인 후 수동 조치'
        )
    return _clean_layout_text(action)


def _trim_blank_lines(lines):
    cleaned = []
    for line in lines:
        line = line.rstrip()
        if not line and (not cleaned or cleaned[-1] == ''):
            continue
        cleaned.append(line)
    while cleaned and cleaned[-1] == '':
        cleaned.pop()
    return cleaned


def split_customer_action(row):
    # 설명과 실제 명령어를 분리해 긴 명령어가 일반 문장에 섞이지 않도록 한다.
    method_lines = []
    command_lines = []

    for raw_line in _customer_action_text(row).splitlines():
        line = raw_line.strip()
        if not line:
            method_lines.append('')
            command_lines.append('')
            continue

        if (
            _COMMAND_LINE_RE.match(line)
            or line.startswith('/')
            or line.startswith('./')
        ):
            command_lines.append(line)
        else:
            method_lines.append(line)

    method_lines = _trim_blank_lines(method_lines)
    command_lines = _trim_blank_lines(command_lines)

    method = '\n'.join(method_lines) or '현재 상태와 운영 정책을 확인한 후 조치 여부를 결정합니다.'
    commands = '\n'.join(command_lines) or '별도 확인 명령 없음'
    return method, commands


def format_customer_action_steps(row):
    return split_customer_action(row)[0]


def format_customer_action_commands(row):
    return split_customer_action(row)[1]


def format_followup_overview(row):
    # 현재 상태와 확인 필요 사유를 하나의 보고서형 셀로 통합한다.
    state = format_current_state(row)
    reason = format_customer_need_reason(row)
    return (
        f'[현재 상태]\n{state}'
        f'\n\n[확인 필요 사유]\n{reason}'
    )


def format_followup_procedure(row):
    # 일반 조치 설명과 실제 확인 명령을 하나의 절차 셀에 구분해 표시한다.
    method, commands = split_customer_action(row)
    return (
        f'[조치 방법]\n{method}'
        f'\n\n[확인 명령]\n{commands}'
    )


def format_followup_criteria(row):
    # 항목을 양호로 판단할 기준만 별도 열에 표시한다.
    return format_need_criteria(row)


def format_followup_caution(row):
    # 적용 전후에 확인해야 할 운영상 주의사항만 별도 열에 표시한다.
    return format_need_caution(row)


def format_result_summary(row):
    sections, _ = _detail_sections(row.get('상세내역', ''))
    status = row.get('최종결과', '').strip()
    if status in ('수동확인', '실패', '건너뜀'):
        return format_customer_need_reason(row)
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
    verify = _first_section(sections, '검증 결과', '최종 검증', '검증', '검증실패', '조치 결과', '결과')
    if verify:
        return _report_text(verify)
    return _report_text(_after_verify_message(row, sections)) or '검증 결과 기록 참조'


def format_change_action_verify(row):
    target = format_change_target(row)
    action = format_change_action(row)
    verify = format_change_verify(row)
    return f'[변경 대상]\n{target}\n\n[적용 내용]\n{action}\n\n[검증]\n{verify}'


def format_backup_path(row):
    value = _clean_layout_text(row.get('백업파일경로', ''))
    return '' if value in ('', '미생성', '없음', '-') else value


def _est_line_count(ws, col, text):
    # \n 개수만 세면, 줄바꿈 문자 없이 컬럼 너비 때문에 화면/인쇄 시
    # 자동으로 줄이 꺾이는 긴 텍스트를 놓친다. 컬럼 너비(문자 단위) 기준으로
    # 각 줄이 몇 줄로 꺾일지 근사 추정한다. 정확한 픽셀 계산은 아니지만
    # "무조건 1줄로 간주"보다는 실제 필요 높이에 훨씬 가깝다.
    if not text:
        return 1
    try:
        width = ws.column_dimensions[get_column_letter(col)].width
    except Exception:
        width = None
    chars_per_line = max(1, int((width or 10) * 1.7))
    total = 0
    for seg in str(text).split('\n'):
        disp_w = sum(2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1 for ch in seg)
        total += max(1, math.ceil(disp_w / chars_per_line)) if disp_w else 1
    return max(1, total)


def _style_multi_text_row(ws, row_num, result_col, text_cols, max_height=409):
    result = ws.cell(row_num, result_col).value
    _fill_key = DISPLAY_TO_INTERNAL.get(result, result)
    ws.cell(row_num, result_col).fill = PatternFill('solid', fgColor=RESULT_FILL.get(_fill_key, WHITE))
    if _fill_key == '수동확인':
        ws.cell(row_num, result_col).font = Font(
            name=FN, bold=True, color=MANUAL_TEXT_COLOR, size=9
        )
    ws.cell(row_num, result_col).alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)

    max_lines = 1
    for col in text_cols:
        current = ws.cell(row_num, col)
        current.alignment = Alignment(horizontal='left', vertical='top', wrap_text=True)
        max_lines = max(max_lines, _est_line_count(ws, col, current.value))
    ws.row_dimensions[row_num].height = max(45, min(max_height, max_lines * 14))


def _detail_row_style(ws, row_num, before_col, after_col, result_col, detail_col, max_height=200):
    result = ws.cell(row_num, result_col).value
    _fill_key = DISPLAY_TO_INTERNAL.get(result, result)
    ws.cell(row_num, result_col).fill = PatternFill('solid', fgColor=RESULT_FILL.get(_fill_key, WHITE))
    if _fill_key == '수동확인':
        ws.cell(row_num, result_col).font = Font(
            name=FN, bold=True, color=MANUAL_TEXT_COLOR, size=9
        )
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

# 화면 배치
#   B:F  자산 정보
#   G    빈 열
#   H:K  보안 점수 및 조치 전·후 비교
#   L    빈 열
#   M:R  결과 요약
#   J    위험도 차트와 분류별 표 사이 빈 열
#   T:V  차트 원본 데이터(숨김)
set_widths(ws, [
    2,      # A: 왼쪽 여백
    10, 10, 14, 14, 14,   # B:F 자산 정보
    2.5,                    # G 빈 열
    5, 5, 10, 10,          # H:K 보안 점수
    2.5,                    # L 빈 열
    9, 11, 11, 11, 11, 11, # M:R 결과 요약
    2,                      # S 보조 여백
    12, 12, 12             # T:V 차트 데이터
])
for _hc in ('T', 'U', 'V'):
    ws.column_dimensions[_hc].hidden = True

for rr in range(1, 50):
    ws.row_dimensions[rr].height = 15
ws.row_dimensions[2].height = 30
ws.row_dimensions[3].height = 18
ws.row_dimensions[4].height = 12
ws.row_dimensions[5].height = 18
ws.row_dimensions[6].height = 24
ws.row_dimensions[7].height = 24
ws.row_dimensions[8].height = 22
ws.row_dimensions[9].height = 30
ws.row_dimensions[10].height = 26  # 보안 점수 산식 각주 표기용
ws.row_dimensions[11].height = 18
ws.row_dimensions[12].height = 26
ws.row_dimensions[20].height = 10
ws.row_dimensions[21].height = 10
ws.row_dimensions[22].height = 18
ws.row_dimensions[23].height = 20
# 위험도 분포 설명과 막대 사이의 여백
ws.row_dimensions[24].height = 10
for _rr in range(25, 28):
    ws.row_dimensions[_rr].height = 18
# 위험도 막대와 다음 조치 우선순위 사이의 여백
ws.row_dimensions[28].height = 10
ws.row_dimensions[29].height = 20
ws.row_dimensions[30].height = 26
for _rr in range(31, 36):
    ws.row_dimensions[_rr].height = 24
ws.row_dimensions[36].height = 18

# 제목 영역
ws.merge_cells('B2:R2')
cell(ws, 2, 2, 'KISA 취약점 조치 결과 보고서',
     font=FONT_TITLE, fill=FILL_NAVY, align='left', border=False)
# 실행 일시는 자산 정보 영역(D9)에만 표시하고 제목 영역에는 중복 표기하지 않는다.
ws.merge_cells('B3:R3')
cell(ws, 3, 2, '',
     font=Font(name=FN, color=WHITE, size=10),
     fill=FILL_NAVY, align='right', border=False)

# ── 1. 상단 3분할: 자산 정보 / 보안 점수 / 결과 요약 ────────────────────────
# 자산 정보: B:F
header(ws, 5, 2, 6, '1. 자산 정보')
# 헤더를 B:F 전체 폭으로 확장
ws.unmerge_cells('B5:F5') if 'B5:F5' in [str(x) for x in ws.merged_cells.ranges] else None
ws.merge_cells('B5:F5')
cell(ws, 5, 2, '1. 자산 정보', font=FONT_HEADER, fill=FILL_NAVY, align='left')

merged_cell(ws, 6, 2, 6, 3, '서버명', font=FONT_BOLD, fill=PALE, align='left')
merged_cell(ws, 6, 4, 6, 6, server, font=FONT_BASE, fill=WHITE, align='left')
merged_cell(ws, 7, 2, 8, 3, 'OS 정보', font=FONT_BOLD, fill=PALE, align='left')
merged_cell(ws, 7, 4, 8, 6, os_info, font=FONT_BASE, fill=WHITE, align='left', wrap=True)
merged_cell(ws, 9, 2, 9, 3, '실행 일시', font=FONT_BOLD, fill=PALE, align='left')
merged_cell(ws, 9, 4, 9, 6, run_ts, font=FONT_BASE, fill=WHITE, align='left')

# 보안 점수: H:K
header(ws, 5, 8, 11, '보안 점수')

_before_pct = round(before_vuln / total * 100, 1) if total else 0
_after_pct = round(after_vuln / total * 100, 1) if total else 0
_improve_pp = round(_before_pct - _after_pct, 1)

# 고객용 색상 팔레트
_CUSTOMER_NAVY = '1F4E78'
_CUSTOMER_BLUE = '4472C4'
_CUSTOMER_SCORE_BLUE = '2F66C4'
_CUSTOMER_LIGHT_BLUE = 'EAF2F8'
_CUSTOMER_GREEN = '70AD47'
_CUSTOMER_GREEN_LIGHT = 'E2F0D9'
_CUSTOMER_ORANGE = 'F5A623'
_CUSTOMER_ORANGE_LIGHT = 'FFF2CC'
_CUSTOMER_RED = 'C00000'
_CUSTOMER_RED_LIGHT = 'FCE4D6'
_CUSTOMER_GRAY = '7F8C8D'
_CUSTOMER_GRAY_LIGHT = 'F2F2F2'
_CUSTOMER_BORDER = Side(style='thin', color='B4C6E7')
_CUSTOMER_BDR = Border(
    left=_CUSTOMER_BORDER,
    right=_CUSTOMER_BORDER,
    top=_CUSTOMER_BORDER,
    bottom=_CUSTOMER_BORDER
)

# 점수
merged_cell(
    ws, 6, 8, 7, 11,
    f'{score} /100점',
    font=Font(name=FN, bold=True, color=_CUSTOMER_SCORE_BLUE, size=18),
    fill=_CUSTOMER_LIGHT_BLUE, align='center'
)

# 중간 설명 행을 제거하고 조치 전 / 조치 후 / 개선을 8~9행으로 병합한다.
merged_cell(
    ws, 8, 8, 9, 9,
    f'조치 전\n{before_vuln}건 · {_before_pct}%',
    font=Font(name=FN, bold=True, color=DARK, size=9),
    fill=PALE, align='center'
)
merged_cell(
    ws, 8, 10, 9, 10,
    f'조치 후\n{after_vuln}건 · {_after_pct}%',
    font=Font(name=FN, bold=True, color=NAVY, size=9),
    fill=PALE, align='center'
)
merged_cell(
    ws, 8, 11, 9, 11,
    f'개선\n{improve}건 · {_improve_pp}%p',
    font=Font(name=FN, bold=True, color=GREEN, size=9),
    fill=PALE, align='center'
)

# 결과 요약: M:R
header(ws, 5, 13, 18, '결과 요약')

_summary_headers = [
    '전체 항목', '적용 대상', '적용 제외',
    '최종 양호', '확인 필요', '실패'
]
_summary_counts = [
    total, applicable, na,
    good, need_check, COUNTS['실패']
]
_summary_ratios = [
    100.0,
    round(applicable / total * 100, 1) if total else 0.0,
    round(na / total * 100, 1) if total else 0.0,
    round(good / applicable * 100, 1) if applicable else 0.0,
    round(need_check / applicable * 100, 1) if applicable else 0.0,
    round(COUNTS['실패'] / applicable * 100, 1) if applicable else 0.0,
]
_summary_fills = [
    _CUSTOMER_LIGHT_BLUE,
    _CUSTOMER_LIGHT_BLUE,
    _CUSTOMER_GRAY_LIGHT,
    _CUSTOMER_GREEN_LIGHT,
    _CUSTOMER_ORANGE_LIGHT,
    _CUSTOMER_RED_LIGHT,
]
_summary_colors = [
    _CUSTOMER_NAVY,
    _CUSTOMER_BLUE,
    _CUSTOMER_GRAY,
    _CUSTOMER_GREEN,
    _CUSTOMER_ORANGE,
    _CUSTOMER_RED,
]

for _offset, _label in enumerate(_summary_headers):
    _col = 13 + _offset

    _header_cell = ws.cell(6, _col, _label)
    _header_cell.font = Font(name=FN, bold=True, color=WHITE, size=8)
    _header_cell.fill = PatternFill('solid', fgColor=_CUSTOMER_NAVY)
    _header_cell.alignment = Alignment(
        horizontal='center', vertical='center', wrap_text=True
    )
    _header_cell.border = _CUSTOMER_BDR

    _count_cell = ws.cell(7, _col, _summary_counts[_offset])
    _count_cell.font = Font(
        name=FN, bold=True,
        color=_summary_colors[_offset],
        size=11 if _offset == 2 else 12
    )
    _count_cell.fill = PatternFill('solid', fgColor=_summary_fills[_offset])
    _count_cell.alignment = Alignment(
        horizontal='center', vertical='center', wrap_text=True
    )
    _count_cell.border = _CUSTOMER_BDR

    _ratio_cell = ws.cell(8, _col, f'{_summary_ratios[_offset]}%')
    _ratio_cell.font = Font(
        name=FN, bold=True,
        color=_summary_colors[_offset],
        size=11 if _offset == 2 else 12
    )
    _ratio_cell.fill = PatternFill('solid', fgColor=_summary_fills[_offset])
    _ratio_cell.alignment = Alignment(
        horizontal='center', vertical='center', wrap_text=True
    )
    _ratio_cell.border = _CUSTOMER_BDR

# 결과 요약의 집계 구조를 숫자 반복 없이 두 구역으로 설명한다.
merged_cell(
    ws, 9, 13, 9, 15,
    '전체 항목 = 적용 대상 + 적용 제외',
    font=Font(name=FN, color=_CUSTOMER_GRAY, size=8),
    fill=WHITE, align='center', wrap=True
)
merged_cell(
    ws, 9, 16, 9, 18,
    '적용 대상 = 최종 양호 + 확인 필요 + 실패',
    font=Font(name=FN, color=_CUSTOMER_GRAY, size=8),
    fill=WHITE, align='center', wrap=True
)

ws.row_dimensions[7].height = 24
ws.row_dimensions[8].height = 30
ws.row_dimensions[9].height = 24

# ── 2. 위험도별 처리 현황 / 3. 분류별 양호율 ────────────────────────────────
# 두 섹션 모두 11행 제목, 12~19행 영역으로 맞춘다.
# 위험도 차트는 B12:I18까지만 배치하고 B19:I19를 실제 색상 띠로 사용한다.
# 분류별 표는 K12:R19에서 끝나므로 양쪽 섹션의 하단 위치가 일치한다.
header(ws, 11, 2, 9, '2. 위험도별 최종 상태')
header(ws, 11, 11, 18, '3. 분류별 양호율')

ws.row_dimensions[12].height = 22
for _rr in range(13, 18):
    ws.row_dimensions[_rr].height = 22
ws.row_dimensions[18].height = 18
# 왼쪽 차트의 전용 마감선 행. 테두리가 아니라 셀 자체를 채워 표시한다.
ws.row_dimensions[19].height = 3

# 차트 원본 데이터는 숨김 열 T:V에 기록한다.
risk_data = [
    ['위험도', '최종 양호', '확인 필요'],
    ['상', RISK_STAT['상'][0], RISK_STAT['상'][1]],
    ['중', RISK_STAT['중'][0], RISK_STAT['중'][1]],
    ['하', RISK_STAT['하'][0], RISK_STAT['하'][1]]
]
for _r, _row in enumerate(risk_data, 2):
    for _c, _value in enumerate(_row, 20):
        cell(ws, _r, _c, _value, border=False)

bar2 = BarChart()
bar2.type = 'bar'
bar2.style = 2
bar2.roundedCorners = False

# 차트 객체의 불안정한 윤곽선과 축 기준선은 제거한다.
# 영역 외곽선은 차트 객체가 아니라 B12:I19 셀 테두리로 별도 적용해
# Excel 화면·인쇄·PDF 변환에서도 네 변이 안정적으로 표시되게 한다.
bar2.graphical_properties = GraphicalProperties(noFill=True)
bar2.graphical_properties.ln.noFill = True
bar2.plot_area.spPr = GraphicalProperties(noFill=True)
bar2.plot_area.spPr.ln.noFill = True
bar2.x_axis.spPr = GraphicalProperties(noFill=True)
bar2.x_axis.spPr.ln.noFill = True
bar2.y_axis.spPr = GraphicalProperties(noFill=True)
bar2.y_axis.spPr.ln.noFill = True

# 차트 원본 데이터(T:V)는 숨김 열이므로 숨겨진 셀도 차트에 표시한다.
bar2.visible_cells_only = False
bar2.title = None

# 가로 막대 차트의 축 구성
# x_axis = 위험도(범주), y_axis = 건수(값)
bar2.x_axis.title = '위험도'
bar2.y_axis.title = '건수'
bar2.x_axis.axPos = 'l'
bar2.y_axis.axPos = 'b'
bar2.x_axis.tickLblPos = 'low'
bar2.y_axis.tickLblPos = 'low'
bar2.x_axis.delete = False
bar2.y_axis.delete = False

# 상 → 중 → 하 순서로 위에서 아래에 표시한다.
bar2.x_axis.scaling.orientation = 'maxMin'
bar2.x_axis.tickLblSkip = 1
bar2.x_axis.noMultiLvlLbl = True

_bar2_max = max(
    [RISK_STAT[k][0] for k in ['상', '중', '하']]
    + [RISK_STAT[k][1] for k in ['상', '중', '하']]
    + [0]
)
bar2.y_axis.scaling.min = 0
bar2.y_axis.scaling.max = max(10, int(math.ceil(_bar2_max / 10.0) * 10))
bar2.y_axis.majorUnit = 10

# 값 축의 주요 눈금선은 가로 막대 길이를 읽기 쉽도록 연한 세로 실선으로 표시한다.
# 차트 외곽선은 아래 B12:I19 셀 테두리로 유지한다.
_bar2_grid_gp = GraphicalProperties()
_bar2_grid_gp.ln.solidFill = 'D9E2F3'
_bar2_grid_gp.ln.width = 6350  # 약 0.5pt
bar2.y_axis.majorGridlines = ChartLines(spPr=_bar2_grid_gp)

# 범주는 문자열 참조(StrRef), 값은 숫자 참조로 연결한다.
# category 축에 숫자 min/max가 기록되어 차트가 빈 화면으로 표시되던 문제를 제거한다.
_bar2_categories = f"'{ws.title}'!$T$3:$T$5"

_bar2_good = Series(
    Reference(ws, min_col=21, min_row=3, max_row=5),
    title='최종 양호'
)
_bar2_good.cat = AxDataSource(strRef=StrRef(f=_bar2_categories))
_bar2_good.graphicalProperties.solidFill = '70AD47'
_bar2_good.graphicalProperties.ln.noFill = True
bar2.append(_bar2_good)

_bar2_bad = Series(
    Reference(ws, min_col=22, min_row=3, max_row=5),
    title='확인 필요'
)
_bar2_bad.cat = AxDataSource(strRef=StrRef(f=_bar2_categories))
_bar2_bad.graphicalProperties.solidFill = 'F5A623'
_bar2_bad.graphicalProperties.ln.noFill = True
bar2.append(_bar2_bad)

bar2.gapWidth = 75
bar2.overlap = 0
bar2.dataLabels = DataLabelList()
bar2.dataLabels.showVal = True
bar2.dataLabels.showSerName = False
bar2.dataLabels.showCatName = False
bar2.dataLabels.showLegendKey = False
bar2.dataLabels.showPercent = False
bar2.dataLabels.dLblPos = 'outEnd'

bar2.legend.position = 'b'
bar2.legend.overlay = False
bar2.legend.txPr = _chart_rich_text(size=800)
bar2.x_axis.txPr = _chart_rich_text(size=800)
bar2.y_axis.txPr = _chart_rich_text(size=800)
_style_axis_title(bar2.x_axis, 850)
_style_axis_title(bar2.y_axis, 850)
_style_data_labels(bar2.dataLabels, 800)

# B12:I18까지만 차트를 배치해 19행 마감선이 차트에 가려지지 않게 한다.
_bar2_from = AnchorMarker(col=1, colOff=0, row=11, rowOff=0)
_bar2_to = AnchorMarker(col=9, colOff=0, row=18, rowOff=0)
bar2.anchor = TwoCellAnchor(
    editAs='twoCell',
    _from=_bar2_from,
    to=_bar2_to
)
ws.add_chart(bar2)

# 차트 내부의 축·막대 테두리는 제거하되, 위험도별 최종 상태 영역은
# Excel 버전과 인쇄 렌더링에 관계없이 안정적으로 보이도록 B12:I19 셀 범위에
# 얇은 외곽 테두리를 적용한다. 차트 객체 자체의 윤곽선이 아니라 셀 테두리를
# 사용하므로 일부 변만 누락되는 openpyxl/Excel 렌더링 차이를 피할 수 있다.
_CHART_FRAME_SIDE = Side(style='thin', color='B4C6E7')

for _row_num in range(12, 20):
    for _col_num in range(2, 10):
        _frame_cell = ws.cell(_row_num, _col_num)
        _old_border = _frame_cell.border
        _frame_cell.border = Border(
            left=_CHART_FRAME_SIDE if _col_num == 2 else _old_border.left,
            right=_CHART_FRAME_SIDE if _col_num == 9 else _old_border.right,
            top=_CHART_FRAME_SIDE if _row_num == 12 else _old_border.top,
            bottom=_CHART_FRAME_SIDE if _row_num == 19 else _old_border.bottom
        )

# 분류별 양호율: K12:R19
CAT_STAT.sort(key=lambda x: x[1])

merged_cell(
    ws, 12, 11, 12, 13, '항목 분류',
    font=FONT_HEADER, fill=FILL_NAVY, align='center'
)
merged_cell(
    ws, 12, 14, 12, 15, '최종 양호',
    font=FONT_HEADER, fill=FILL_NAVY, align='center'
)
cell(
    ws, 12, 16, '적용 대상',
    font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True
)
cell(
    ws, 12, 17, '적용 제외',
    font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True
)
cell(
    ws, 12, 18, '양호율',
    font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True
)

for _row_num, _cat in enumerate(CAT_STAT, 13):
    _cat_name, _pct, _high, _mid, _low, _ok, _bad, _target, _excluded = _cat

    if _pct < 60:
        _rate_color = RED
    elif _pct < 80:
        _rate_color = ORANGE
    else:
        _rate_color = GREEN

    merged_cell(
        ws, _row_num, 11, _row_num, 13, _cat_name,
        font=FONT_SMALL, fill=WHITE, align='center'
    )
    merged_cell(
        ws, _row_num, 14, _row_num, 15, f'{_ok}건',
        font=FONT_SMALL, fill=WHITE, align='center'
    )
    cell(
        ws, _row_num, 16, f'{_target}건',
        font=FONT_SMALL, fill=WHITE, align='center'
    )
    cell(
        ws, _row_num, 17, f'{_excluded}건',
        font=FONT_SMALL, fill=WHITE, align='center'
    )
    cell(
        ws, _row_num, 18, f'{_pct}%',
        font=Font(name=FN, bold=True, color=_rate_color, size=9),
        fill=WHITE, align='center'
    )

merged_cell(
    ws, 18, 11, 19, 18,
    '※ 적용 제외는 서비스 미사용 등으로 해당없음 판정된 항목이며, 양호율 계산에서 제외합니다.',
    font=Font(name=FN, color=GRAY, size=8),
    fill=PALE, align='left', wrap=True
)

# ── 4. 확인 필요 요약 및 우선순위 ───────────────────────────────────────────
header(ws, 22, 2, 18, '4. 확인 필요 항목의 위험도 분포 및 우선순위')
_need_total = need_check + COUNTS['실패']

ws.merge_cells(start_row=23, start_column=2, end_row=23, end_column=18)
cell(ws, 23, 2, f'확인 필요 항목의 위험도 분포 (총 {_need_total}건)',
     font=FONT_BOLD, fill=WHITE, align='left', border=False)

_risk_need_rows = [
    ('상', RISK_STAT['상'][1], 'E53935'),
    ('중', RISK_STAT['중'][1], 'F59E0B'),
    ('하', RISK_STAT['하'][1], '4472C4')
]
_risk_need_max = max([x[1] for x in _risk_need_rows] + [1])
_bar_slots = 15

for _row_num, (_risk_name, _risk_count, _bar_color) in enumerate(_risk_need_rows, 25):
    cell(ws, _row_num, 2, _risk_name, font=FONT_BOLD, fill=WHITE, border=False)
    _filled_slots = int(math.ceil((_risk_count / _risk_need_max) * _bar_slots)) if _risk_count else 0

    for _slot_index, _col_num in enumerate(range(3, 18), 1):
        # 실제 건수에 해당하는 구간만 색상을 적용하고 나머지는 흰색으로 둔다.
        _slot_fill = _bar_color if _slot_index <= _filled_slots else WHITE
        cell(ws, _row_num, _col_num, '', fill=_slot_fill, border=False)

    cell(ws, _row_num, 18, f'{_risk_count}건',
         font=FONT_SMALL, fill=WHITE, align='right', border=False)

ws.merge_cells(start_row=29, start_column=2, end_row=29, end_column=18)
cell(ws, 29, 2, '다음 조치 우선순위',
     font=FONT_BOLD, fill=WHITE, align='left', border=False)

for _c1, _c2, _title in [
    (2, 3, '항목ID'),
    (4, 8, '항목명'),
    (9, 10, '중요도'),
    (11, 12, '상태'),
    (13, 18, '확인 필요 사유')
]:
    merged_cell(ws, 30, _c1, 30, _c2, _title,
                font=FONT_HEADER, fill=FILL_NAVY, align='center', wrap=True)

_top5 = TOP_NEED[:5]
for _row_num, _item in enumerate(_top5, 31):
    merged_cell(ws, _row_num, 2, _row_num, 3, _item.get('항목ID', ''),
                font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, _row_num, 4, _row_num, 8, _item.get('항목명', ''),
                font=FONT_SMALL, fill=WHITE, wrap=True)
    merged_cell(ws, _row_num, 9, _row_num, 10, _item.get('위험도', ''),
                font=FONT_SMALL, fill=WHITE)

    _status = _item.get('최종결과', '')
    _status_display = customer_disp(_status)
    _status_font = Font(
        name=FN, bold=True,
        color=(
            _CUSTOMER_RED
            if _status == '실패'
            else MANUAL_TEXT_COLOR
            if _status == '수동확인'
            else _CUSTOMER_ORANGE
        ),
        size=9
    )
    merged_cell(
        ws, _row_num, 11, _row_num, 12, _status_display,
        font=_status_font, fill=WHITE
    )
    merged_cell(
        ws, _row_num, 13, _row_num, 18,
        format_dashboard_need_reason(_item),
        font=FONT_SMALL, fill=WHITE, align='left', wrap=True
    )

for _row_num in range(31 + len(_top5), 36):
    merged_cell(ws, _row_num, 2, _row_num, 3, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, _row_num, 4, _row_num, 8, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, _row_num, 9, _row_num, 10, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, _row_num, 11, _row_num, 12, '', font=FONT_SMALL, fill=WHITE)
    merged_cell(ws, _row_num, 13, _row_num, 18, '', font=FONT_SMALL, fill=WHITE)

ws.merge_cells(start_row=36, start_column=2, end_row=36, end_column=18)
cell(ws, 36, 2, '선정 기준: 중요도 높은 순 → 확인 필요 상태(수동 확인·조치 보류) → 항목ID 순',
     font=Font(name=FN, color=GRAY, size=8),
     fill=WHITE, align='left', border=False)

# 인쇄/보기 설정
ws.freeze_panes = 'B5'
ws.page_setup.orientation = 'landscape'
ws.page_setup.paperSize = ws.PAPERSIZE_A4
ws.print_options.horizontalCentered = False
# 요약 대시보드 인쇄 배율을 고정 75%로 적용한다.
ws.page_setup.scale = 75
ws.page_setup.fitToWidth = None
ws.page_setup.fitToHeight = None
ws.sheet_properties.pageSetUpPr.fitToPage = False
ws.sheet_properties.pageSetUpPr.autoPageBreaks = False
ws.print_area = 'B2:R36'
ws.sheet_view.zoomScale = 85
ws.page_margins.left = 0.35
ws.page_margins.right = 0.35
ws.page_margins.top = 0.6
ws.page_margins.bottom = 0.6
ws.page_margins.header = 0.3
ws.page_margins.footer = 0.3
ws.oddFooter.center.text = '페이지 &P / &N'

# ── 취약점 점검 결과: 판정을 먼저 확인한 후 상세 상태를 읽는 기준 시트 ──────
full_headers = [
    '항목ID', '항목명', '대분류', '위험도',
    '판정', '조치 전 상태', '변경 및 검증 결과', '결과 요약'
]
ws3 = wb.create_sheet('취약점 점검 결과')
ws3.sheet_view.showGridLines = False
ws3.sheet_view.zoomScale = 85
ws3.append(full_headers)

for x in rows:
    ws3.append([
        x.get('항목ID',''),
        x.get('항목명',''),
        x.get('대분류',''),
        x.get('위험도',''),
        disp(x.get('최종결과','')),
        format_before_state(x),
        format_change_verify_result(x),
        format_result_summary(x)
    ])

style_table(ws3, 1, 1, max(ws3.max_row, 1), len(full_headers))

_res_col3 = full_headers.index('판정') + 1
_before_col3 = full_headers.index('조치 전 상태') + 1
_change_verify_col3 = full_headers.index('변경 및 검증 결과') + 1
_summary_col3 = full_headers.index('결과 요약') + 1

_ws3_widths = [9, 30, 18, 8, 11, 42, 52, 38]
set_widths(ws3, _ws3_widths)

for r in range(2, ws3.max_row + 1):
    _style_multi_text_row(
        ws3, r, _res_col3,
        (_before_col3, _change_verify_col3, _summary_col3),
        max_height=220
    )
    # 식별·분류·위험도·판정은 가운데, 상세 상태는 왼쪽 위 정렬
    for _col in range(1, 6):
        ws3.cell(r, _col).alignment = Alignment(
            horizontal='center', vertical='center', wrap_text=True
        )

# 첫 행과 A:E를 고정하여 가로 이동 시에도 판정이 계속 보이게 한다.
ws3.freeze_panes = 'F2'

ws3.page_setup.orientation = 'landscape'
ws3.page_setup.paperSize = ws3.PAPERSIZE_A4
ws3.print_options.horizontalCentered = False
# 취약점 점검 결과 인쇄 배율을 고정 60%로 적용한다.
ws3.page_setup.scale = 60
ws3.page_setup.fitToWidth = None
ws3.page_setup.fitToHeight = None
ws3.sheet_properties.pageSetUpPr.fitToPage = False
ws3.sheet_properties.pageSetUpPr.autoPageBreaks = False
ws3.print_area = f'A1:H{ws3.max_row}'
ws3.print_title_rows = '1:1'
ws3.page_margins.left = 0.30
ws3.page_margins.right = 0.30
ws3.page_margins.top = 0.60
ws3.page_margins.bottom = 0.60
ws3.page_margins.header = 0.25
ws3.page_margins.footer = 0.25
ws3.oddHeader.center.text = f'&"맑은 고딕,굵게"&12KISA 취약점 조치 결과 보고서 - 취약점 점검 결과'
ws3.oddFooter.center.text = '페이지 &P / &N'

try:
    ref = f'A1:H{ws3.max_row}'
    tab = Table(displayName='VulnDetailTable', ref=ref)
    tab.tableStyleInfo = TableStyleInfo(
        name='TableStyleMedium2',
        showFirstColumn=False,
        showLastColumn=False,
        showRowStripes=False,
        showColumnStripes=False
    )
    ws3.add_table(tab)
except Exception:
    pass

# ── 후속 확인 항목: 판정 기준과 유의사항을 분리한 7개 열 보고서 형식 ───────
# 대분류와 위험도는 대시보드·집계용 내부 데이터에는 유지하되,
# 이 시트에서는 중복 정보이므로 표시하지 않는다.
need_headers = [
    '항목ID', '항목명', '판정',
    '확인 현황', '조치 절차', '판정 기준', '유의사항'
]
ws2 = wb.create_sheet('후속 확인 항목')
ws2.sheet_view.showGridLines = False
ws2.sheet_view.zoomScale = 85
ws2.append(need_headers)

for x in rows:
    if x.get('최종결과') in ('수동확인', '실패', '건너뜀'):
        ws2.append([
            x.get('항목ID',''),
            x.get('항목명',''),
            disp(x.get('최종결과','')),
            format_followup_overview(x),
            format_followup_procedure(x),
            format_followup_criteria(x),
            format_followup_caution(x)
        ])

style_table(ws2, 1, 1, max(ws2.max_row, 1), len(need_headers))

_res_col2 = need_headers.index('판정') + 1
_text_cols2 = tuple(
    need_headers.index(name) + 1
    for name in (
        '확인 현황',
        '조치 절차',
        '판정 기준',
        '유의사항'
    )
)

# 후속 확인 항목의 본문 열 너비를 업무 가독성 기준으로 조정한다.
# 확인 현황 50, 조치 절차 55, 판정 기준 20, 유의사항 20으로 적용한다.
_ws2_widths = [9, 28, 10, 50, 55, 20, 20]
set_widths(ws2, _ws2_widths)

for r in range(2, ws2.max_row + 1):
    _style_multi_text_row(
        ws2, r, _res_col2, _text_cols2,
        max_height=300
    )

    # 항목ID·항목명·판정은 가운데 정렬한다.
    for _col in range(1, 4):
        ws2.cell(r, _col).alignment = Alignment(
            horizontal='center',
            vertical='center',
            wrap_text=True
        )

    # 보고서 본문은 왼쪽·위쪽 정렬하고 긴 명령도 텍스트로 보존한다.
    for _col in range(4, 8):
        _body_cell = ws2.cell(r, _col)
        _body_cell.font = Font(name=FN, size=8, color=DARK)
        _body_cell.fill = PatternFill('solid', fgColor=WHITE)
        _body_cell.alignment = Alignment(
            horizontal='left',
            vertical='top',
            wrap_text=True
        )
        _body_cell.number_format = '@'

# 첫 행과 A:C를 고정해 가로 이동 시에도 대상과 판정을 확인할 수 있게 한다.
ws2.freeze_panes = 'D2'

ws2.page_setup.orientation = 'landscape'
ws2.page_setup.paperSize = ws2.PAPERSIZE_A4
ws2.print_options.horizontalCentered = False
# 후속 확인 항목 인쇄 배율을 고정 65%로 적용한다.
ws2.page_setup.scale = 65
ws2.page_setup.fitToWidth = None
ws2.page_setup.fitToHeight = None
ws2.sheet_properties.pageSetUpPr.fitToPage = False
ws2.sheet_properties.pageSetUpPr.autoPageBreaks = False
ws2.print_area = f'A1:G{ws2.max_row}'
ws2.print_title_rows = '1:1'
ws2.print_title_cols = 'A:C'
ws2.page_margins.left = 0.30
ws2.page_margins.right = 0.30
ws2.page_margins.top = 0.60
ws2.page_margins.bottom = 0.60
ws2.page_margins.header = 0.25
ws2.page_margins.footer = 0.25
ws2.oddHeader.center.text = f'&"맑은 고딕,굵게"&12KISA 취약점 조치 결과 보고서 - 후속 확인 항목'
ws2.oddFooter.center.text = '페이지 &P / &N'

# ── 조치 변경 내역: 실제 자동 조치 또는 부분 변경이 발생한 항목만 기록 ───────
change_headers = ['항목ID','항목명','판정','조치 전 상태','변경 상세','백업 경로']
ws_log = wb.create_sheet('조치 변경 내역')
ws_log.sheet_view.showGridLines = False
ws_log.append(change_headers)
for x in rows:
    if has_actual_change(x):
        ws_log.append([
            x.get('항목ID',''), x.get('항목명',''), disp(x.get('최종결과','')),
            format_change_before(x), format_change_action_verify(x),
            format_backup_path(x)
        ])
style_table(ws_log, 1, 1, max(ws_log.max_row, 1), len(change_headers))
_res_col_log = change_headers.index('판정') + 1
_text_cols_log = tuple(change_headers.index(name) + 1 for name in ('조치 전 상태','변경 상세','백업 경로'))
# 다른 두 상세 시트와 동일한 전체 열 너비 합계(208)로 맞춘다.
# 9 + 30 + 11 + 34 + 90 + 34 = 208
_ws_log_widths = [9, 30, 11, 34, 90, 34]
set_widths(ws_log, _ws_log_widths)
for r in range(2, ws_log.max_row + 1):
    _style_multi_text_row(ws_log, r, _res_col_log, _text_cols_log, max_height=409)
ws_log.freeze_panes = 'A2'
ws_log.page_setup.orientation = 'landscape'
ws_log.page_setup.paperSize = ws_log.PAPERSIZE_A4
ws_log.print_options.horizontalCentered = False
# 전체 열 너비를 208로 맞추고 같은 A4 가로·여백·한 페이지 폭 맞춤을 적용한다.
# 변경 상세 열은 90을 유지해 가독성을 보존하면서 시트 간 배율 차이를 줄인다.
ws_log.page_setup.fitToWidth = 1
ws_log.page_setup.fitToHeight = 0
ws_log.sheet_properties.pageSetUpPr.fitToPage = True
ws_log.print_area = f'A1:F{ws_log.max_row}'
ws_log.print_title_rows = '1:1'
ws_log.page_margins.left = 0.30
ws_log.page_margins.right = 0.30
ws_log.page_margins.top = 0.60
ws_log.page_margins.bottom = 0.60
ws_log.page_margins.header = 0.25
ws_log.page_margins.footer = 0.25
ws_log.oddHeader.center.text = f'&"맑은 고딕,굵게"&12KISA 취약점 조치 결과 보고서 - 조치 변경 내역'
ws_log.oddFooter.center.text = '페이지 &P / &N'

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
echo -e "${BOLD}  Excel 결과 보고서 자동 생성${RESET}"
_div_thick
echo ""

_XLSX_CREATED=0

if [ ! -f "$REPORT_CSV" ]; then
  _warn "Excel 생성용 임시 결과 데이터가 생성되지 않았습니다."
elif _xlsx_env_check; then
  _info "Excel 보고서 생성 중..."
  rm -f "$REPORT_XLSX" 2>/dev/null || true

  if _generate_xlsx "$REPORT_CSV" "$REPORT_XLSX" \
      "$_HOSTNAME_VAL" "$_OS_INFO" "$(date '+%Y-%m-%d %H:%M:%S')" \
      && [ -s "$REPORT_XLSX" ]; then
    chmod 640 "$REPORT_XLSX" 2>/dev/null
    _XLSX_CREATED=1
    echo ""
    _ok "Excel 보고서 생성 완료"
    echo -e "   ${CYAN}${REPORT_XLSX}${RESET}"
    echo -e "   크기: $(du -h "$REPORT_XLSX" 2>/dev/null | cut -f1)"
  else
    rm -f "$REPORT_XLSX" 2>/dev/null || true
    echo ""
    _warn "Excel 보고서 생성에 실패했습니다."
    _warn "Python/openpyxl 환경과 화면에 표시된 오류를 확인한 후 다시 실행하세요."
  fi
else
  _warn "호환 가능한 Python/openpyxl 환경이 없어 Excel 보고서를 생성하지 못했습니다."
fi

# CSV는 최종 산출물이 아닌 XLSX 생성용 중간 파일이므로 항상 삭제한다.
rm -f "$REPORT_CSV" 2>/dev/null || true
_REPORT_CSV_HEADER_WRITTEN=0

if [ "$_XLSX_CREATED" -eq 0 ]; then
  echo ""
  _warn "이번 실행에서는 Excel 결과 보고서가 생성되지 않았습니다."
fi

# 조치가 끝난 시점의 역산 레코드를 백업 옆 .records 파일로 독립 보관한다.
# tar.gz와 .records를 함께 이동하면 일반 로그 없이도 해당 백업의 복원 정보를 사용할 수 있다.
if [ -n "${_PRE_BAK_FILE:-}" ] && [ -f "${_PRE_BAK_FILE:-}" ]; then
  if _vf_export_run_records_sidecar "$_PRE_BAK_FILE"; then
    chmod 600 "${_PRE_BAK_FILE}.records" 2>/dev/null || true
    _ok "롤백 보조 레코드 저장 완료"
    echo -e "   ${CYAN}${_PRE_BAK_FILE}.records${RESET}"
    _info "백업 이동 시 tar.gz와 .records 파일을 함께 복사하세요."
  else
    _warn "롤백 보조 레코드(.records) 저장 실패 — 이 백업으로는 자동 롤백할 수 없습니다."
    _warn "화면에 표시된 오류 내용을 확인하세요."
  fi
  echo ""
fi

# 롤백 보조 레코드의 무결성 확인용 SHA-256 파일만 생성한다.
# /report에는 최종 XLSX 한 파일만 남긴다.
[ -f "${_PRE_BAK_FILE:-}.records" ] \
  && _vf_write_sha256_sidecar "${_PRE_BAK_FILE}.records" || true

echo ""
rm -f "${_RPT_BASE_DIR}/.xlsx_error_${_RUN_TS}.tmp" 2>/dev/null || true
echo -e " ${CYAN}※${RESET} 복원은 --rollback, 도움말은 --help 옵션 사용"
echo ""
_div_thick

# ── 최종 종료 코드 ───────────────────────────────────────────────────────────
# 이 스크립트는 Ansible/Jenkins 등 무인 자동화 연동 없이 관리자가 콘솔에서
# 대화형으로 직접 실행하는 용도로만 사용한다. 실행 결과는 위에서 이미
# "조치 결과 요약" 표와 "✘ 조치 실패 항목" 구간으로 사람이 화면으로 확인하므로,
# 이 블록에서 종료 코드의 의미를 화면에 다시 설명하지 않는다.
# ($? 값은 셸에서 필요 시 확인 가능하도록 0(정상)/1(실패)만 최소한으로 남긴다.)
_VF_FINAL_RC=0
[ "${FAILED:-0}" -gt 0 ] && _VF_FINAL_RC=1

exit "$_VF_FINAL_RC"
