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
# 주요정보통신기반시설 기술적 취약점 분석·평가 - LINUX 서버 조치 스크립트
# KISA 2026 상세가이드 기반 (U-01 ~ U-76)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
WHITE='\033[0;37m'; BOLD='\033[1m'; RESET='\033[0m'

# KISA 권고 기본값 — 기준값이 바뀌면 여기 한 곳만 수정하면 된다.
DEFAULT_PASS_MAX_DAYS=90
DEFAULT_PASS_MIN_DAYS=1
DEFAULT_MINLEN=8
DEFAULT_DENY=5
DEFAULT_UNLOCK_TIME=300
DEFAULT_TMOUT=600

# _confirm_yn <prompt>
# y/n 외 입력(엔터, 오타 등)은 무시하고 재질문 (예전엔 조용히 n으로 처리되어 실수 위험).
# 반환값: 0 = 예(y), 1 = 아니오(n)
_confirm_yn() {
  local prompt="$1" ans
  while true; do
    if ! read -rp "$prompt" ans; then
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
    if ! read -rp "$__prompt" __val; then
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
    if ! read -rp "$__prompt" __val; then
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
    # stdin 파이프로 전달 — argv로 넘기면 한글 등 멀티바이트 문자열이
    # 일부 로케일에서 깨져서 python3가 무한 대기하는 버그가 있음
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
  local text="$1" indent=3
  local tw; tw=$(_display_width "$text")
  local pad=$(( _BOX_WIDTH - indent - tw ))
  [ "$pad" -lt 0 ] && pad=0
  printf " ║%*s%s%*s║\n" "$indent" "" "$text" "$pad" ""
}

FIXED=0; SKIPPED=0; FAILED=0; MANUAL=0; NA=0
FIXED_LIST=(); SKIPPED_LIST=(); FAILED_LIST=(); MANUAL_LIST=(); NA_LIST=()
declare -A BEFORE_VAL
declare -A AFTER_VAL
FIX_HISTORY_FILE="/var/log/vulnFixHistory.log"

# 이 실행 전체에서 공용으로 쓰는 타임스탬프 — do_fix의 개별 파일 백업(.bak.<시각>)에 사용
_RUN_TS=$(date +%Y%m%d_%H%M%S)

# root 권한 확인
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[오류] root 권한으로 실행해주세요.${RESET}"; exit 1
fi

# ── 동시 실행 방지 ────────────────────────────────────────────────────────────
# 같은 서버에서 스크립트를 두 세션에서 동시에 실행하면 사전 백업과 PAM 등
# 공유 파일 수정이 서로 겹쳐 꼬일 수 있어, 락을 걸어 중복 실행을 막는다.
_LOCK_FILE="/var/run/vulnFix.lock"
[ -w /var/run ] || _LOCK_FILE="/tmp/vulnFix.lock"
if command -v flock &>/dev/null; then
  exec 9>"$_LOCK_FILE" 2>/dev/null
  if ! flock -n 9 2>/dev/null; then
    echo -e "${RED}[오류] 이미 다른 세션에서 이 스크립트가 실행 중입니다 (${_LOCK_FILE}).${RESET}"
    echo -e "${YELLOW}       동시 실행 시 백업/설정 변경이 꼬일 수 있어 실행을 막습니다.${RESET}"
    exit 1
  fi
else
  echo -e "${YELLOW}[알림] flock 명령이 없어 동시 실행 방지를 건너뜁니다. 이 서버에서 스크립트를 두 세션 이상 동시에 실행하지 마세요.${RESET}"
fi

echo -e "${BOLD}"
_box_top
_box_line "자동 점검 및 조치 스크립트 |  KISA 2026 가이드 기반"
_box_bottom
echo -e "${RESET}"

# ── 대상 항목(TARGET_IDS) 결정 ────────────────────────────────────────────────
# 기본: report 파일 없이 U-01~U-76 전체를 스크립트가 직접 스캔한다.
#      (취약/수동확인/양호 판정은 곧이어 실행되는 재확인 프로그래스바 단계에서 수행)
REPORT=""
if [ -n "$1" ] && [ -f "$1" ]; then
  REPORT="$1"
  echo -e " 점검 파일 지정됨: ${CYAN}${REPORT}${RESET} (보고서 기반 빠른 모드)"
  echo ""
  VULN_IDS=$(grep -E '^\[✘ 취약\]|^\[! 수동확인\]' "$REPORT" | grep -oP 'U-[0-9]+' | sort -t- -k2 -n | uniq)
  TARGET_IDS=()
  for id in $VULN_IDS; do TARGET_IDS+=("$id"); done

  if [ ${#TARGET_IDS[@]} -eq 0 ]; then
    echo -e "${GREEN} 보고서에 취약 및 수동확인 항목이 없습니다.${RESET}"; exit 0
  fi
  echo -e "${BOLD} 보고서 취약 항목: ${RED}${#TARGET_IDS[@]}${RESET}${BOLD}개${RESET} 발견 — 현재 시스템 상태로 재확인을 시작합니다."
else
  echo -e " 주요정보통신기반시설 기술적 취약점 ${CYAN}U-01 ~ U-76 전체 항목${RESET}을 직접 스캔합니다."
  echo ""
  TARGET_IDS=()
  for _n in $(seq -w 1 76); do TARGET_IDS+=("U-${_n}"); done
  echo -e "${BOLD} 전체 점검 대상: ${CYAN}${#TARGET_IDS[@]}${RESET}${BOLD}개${RESET} — 실시간 스캔을 시작합니다."
fi
echo ""

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

# ── 실시간 재확인 함수 ────────────────────────────────────────────────────────
# 반환값: 0=여전히 취약, 1=이미 양호(스킵), 2=해당없음(스킵)
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
      [ -z "$WHEEL_MEMBERS" ] && return 2  # 멤버 없음 — 수동확인(의도 여부)
      return 1 ;;  # 양호
    U-07)
      for a in adm lp sync shutdown halt news uucp operator games gopher; do
        grep -q "^${a}:" /etc/passwd || continue
        PW=$(grep "^${a}:" /etc/shadow 2>/dev/null | awk -F: '{print $2}')
        echo "$PW" | grep -qE '^[*!]' || return 0
      done; return 1 ;;
    U-08) return 2 ;;  # 수동확인 전용
    U-09)
      STALE=$(awk -F: '{print $4}' /etc/passwd | sort -un | while read g; do
        awk -F: -v gid="$g" '$3==gid{found=1} END{if(!found) print gid}' /etc/group
      done | head -1)
      [ -n "$STALE" ] && return 0; return 1 ;;
    U-10)
      DUP=$(awk -F: '{print $3}' /etc/passwd | sort | uniq -d | head -1)
      [ -n "$DUP" ] && return 0; return 1 ;;
    U-11) return 2 ;;  # 수동확인 전용
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
      [ "$O" = "root" ] && [ "$P" -le 644 ] 2>/dev/null && return 1; return 0 ;;
    U-17)
      for f in /etc/rc.local /etc/init.d /etc/rc.d; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && f=$(readlink -f "$f")
        O=$(stat -c '%U' "$f" 2>/dev/null); P=$(stat -c '%a' "$f" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$P" -gt 755 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-18)
      [ ! -f /etc/shadow ] && return 1
      O=$(stat -c '%U' /etc/shadow 2>/dev/null); P=$(stat -c '%a' /etc/shadow 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 400 ] 2>/dev/null && return 1; return 0 ;;
    U-19)
      O=$(stat -c '%U' /etc/hosts 2>/dev/null); P=$(stat -c '%a' /etc/hosts 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 644 ] 2>/dev/null && return 1; return 0 ;;
    U-20)
      for F in /etc/inetd.conf /etc/xinetd.conf; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$P" -gt 600 ]; } 2>/dev/null && return 0
      done
      [ ! -f /etc/inetd.conf ] && [ ! -f /etc/xinetd.conf ] && return 2; return 1 ;;
    U-21)
      for F in /etc/syslog.conf /etc/rsyslog.conf; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$P" -gt 640 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-22)
      O=$(stat -c '%U' /etc/services 2>/dev/null); P=$(stat -c '%a' /etc/services 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 644 ] 2>/dev/null && return 1; return 0 ;;
    U-23)
      ALLOWED="/bin/su /usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh
        /usr/bin/newgrp /usr/bin/gpasswd /usr/bin/crontab /bin/ping /usr/bin/pkexec
        /usr/bin/chage /usr/bin/fusermount /usr/bin/fusermount3 /usr/bin/mount /usr/bin/umount
        /usr/bin/write /usr/bin/at /usr/bin/locate /usr/sbin/lockdev
        /usr/sbin/pam_timestamp_check /usr/sbin/unix_chkpwd /usr/sbin/grub2-set-bootflag
        /usr/sbin/userhelper /usr/lib/polkit-1/polkit-agent-helper-1
        /usr/libexec/utempter/utempter /usr/libexec/Xorg.wrap
        /usr/libexec/openssh/ssh-keysign /usr/libexec/dbus-1/dbus-daemon-launch-helper
        /usr/libexec/sssd/krb5_child /usr/libexec/sssd/ldap_child
        /usr/libexec/sssd/proxy_child /usr/libexec/sssd/selinux_child
        /usr/bin/vmware-user-suid-wrapper"
      EXTRA=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while read -r f; do
        echo "$ALLOWED" | tr ' ' '\n' | grep -qxF "$f" || echo "$f"
      done | head -1)
      [ -n "$EXTRA" ] && return 0; return 1 ;;
    U-24)
      for F in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc /root/.bash_profile /root/.profile; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F" 2>/dev/null); P=$(stat -c '%a' "$F" 2>/dev/null)
        { [ "$O" != "root" ] || [ "$P" -gt 644 ]; } 2>/dev/null && return 0
      done; return 1 ;;
    U-25)
      CNT=$(find / -xdev -perm -0002 -not -type l \
        -not -path '*/proc/*' -not -path '*/sys/*' \
        -not -path '/tmp' -not -path '/tmp/*' \
        -not -path '/var/tmp' -not -path '/var/tmp/*' 2>/dev/null | wc -l)
      [ "$CNT" -gt 0 ] && return 0; return 1 ;;
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
      [ -f /etc/hosts.allow ] || [ -f /etc/hosts.deny ] && return 1; return 0 ;;
    U-29)
      [ ! -f /etc/hosts.lpd ] && return 1
      O=$(stat -c '%U' /etc/hosts.lpd 2>/dev/null); P=$(stat -c '%a' /etc/hosts.lpd 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 600 ] 2>/dev/null && return 1; return 0 ;;
    U-30)
      # 설정 파일에서 022/027 이상의 umask가 명시돼 있으면 양호
      for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/login.defs /etc/profile.d/*.sh; do
        [ -f "$F" ] || continue
        if [ "$F" = "/etc/login.defs" ]; then
          V=$(grep -v '^#' "$F" | grep -iE '^\s*UMASK\s+' | awk '{print $2}' | tail -1)
        else
          V=$(grep -v '^#' "$F" | grep -oE '\bumask[[:space:]]+[0-9]+' | awk '{print $2}' | tail -1)
        fi
        [ -z "$V" ] && continue
        [ "$V" = "022" ] || [ "$V" = "0022" ] || [ "$V" = "027" ] || [ "$V" = "0027" ] && return 1
        return 0  # 취약 값이 명시된 경우
      done
      return 0 ;;
    U-31)
      while IFS=: read -r user _ uid _ _ homedir _; do
        [ "$uid" -lt 1000 ] 2>/dev/null && continue
        [ -z "$homedir" ] || [ "$homedir" = "/" ] || [ ! -d "$homedir" ] && continue
        O=$(stat -c '%U' "$homedir" 2>/dev/null); P=$(stat -c '%a' "$homedir" 2>/dev/null)
        { [ "$O" != "$user" ] || [ "$P" -gt 755 ]; } 2>/dev/null && return 0
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
      # crontab 바이너리 권한 확인
      CRONTAB_BIN=$(which crontab 2>/dev/null || echo "/usr/bin/crontab")
      if [ -f "$CRONTAB_BIN" ]; then
        O=$(stat -c '%U' "$CRONTAB_BIN")
        P_OCT=$(stat -c '%a' "$CRONTAB_BIN")                          # e.g. "4755"
        P_PURE=$(printf '%o' "$((8#${P_OCT} & ~8#6000))" 2>/dev/null) # SUID/SGID 제거 후 octal
        [ "$O" != "root" ] && return 0
        # 750 초과 시 취약 (octal 비교)
        [ "$((8#${P_PURE:-777}))" -gt "$((8#750))" ] 2>/dev/null && return 0
      fi
      # cron 설정 파일 권한 (없으면 스킵)
      for F in /etc/cron.allow /etc/cron.deny /etc/crontab; do
        [ -f "$F" ] || continue
        O=$(stat -c '%U' "$F"); P=$(stat -c '%a' "$F")
        [ "$O" != "root" ] && return 0
        [ "$((8#${P:-777}))" -gt "$((8#640))" ] 2>/dev/null && return 0
      done
      # cron 디렉터리 권한 (sticky/setgid 등 특수비트는 바이너리와 동일하게 제거 후 비교)
      for D in /etc/cron.d /var/spool/cron /var/spool/cron/crontabs; do
        [ -d "$D" ] || continue
        O=$(stat -c '%U' "$D"); P=$(stat -c '%a' "$D")
        DP_PURE=$(printf '%o' "$((8#${P} & ~8#7000))" 2>/dev/null)
        [ "$O" != "root" ] && return 0
        [ "$((8#${DP_PURE:-777}))" -gt "$((8#750))" ] 2>/dev/null && return 0
      done; return 1 ;;
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
      pgrep -x postfix &>/dev/null || pgrep -x sendmail &>/dev/null && return 0; return 1 ;;
    U-46)
      [ ! -f /etc/postfix/main.cf ] && return 2
      O=$(stat -c '%U' /etc/postfix/main.cf 2>/dev/null); P=$(stat -c '%a' /etc/postfix/main.cf 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 644 ] 2>/dev/null && return 1; return 0 ;;
    U-47)
      # MTA 종류(postfix/sendmail/exim) 무관 릴레이 정책은 수동 검토 필요
      # MTA 자체가 미설치 · 미실행이면 해당없음으로 처리
      pgrep -x postfix  &>/dev/null && return 2
      pgrep -x sendmail &>/dev/null && return 2
      pgrep -xf 'exim'  &>/dev/null && return 2
      command -v postfix  &>/dev/null && return 2
      command -v sendmail &>/dev/null && return 2
      command -v exim4    &>/dev/null && return 2
      command -v exim     &>/dev/null && return 2
      return 1 ;;  # MTA 미탐지 → 해당없음(양호 처리)
    U-48)
      [ ! -f /etc/postfix/main.cf ] && return 2
      VRFY=$(grep -v '^#' /etc/postfix/main.cf 2>/dev/null | grep 'disable_vrfy_command' | awk '{print $3}')
      [ "$VRFY" = "yes" ] && return 1; return 0 ;;
    U-49)
      pgrep -x named &>/dev/null && return 0; return 1 ;;
    U-50)
      [ ! -f /etc/named.conf ] && return 2
      AT=$(grep -v '//' /etc/named.conf | grep 'allow-transfer' | head -1)
      echo "$AT" | grep -q 'none' && return 1; return 0 ;;
    U-51)
      [ ! -f /etc/named.conf ] && return 2
      AU=$(grep -v '//' /etc/named.conf | grep 'allow-update' | head -1)
      echo "$AU" | grep -q 'none' && return 1; return 0 ;;
    U-52) ss -tlnp 2>/dev/null | grep -q ':23 ' && return 0; return 1 ;;
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
    U-55) return 2 ;;  # 수동확인
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
        # 백슬래시 이스케이프(\S \r \m 등) 또는 시스템 정보 키워드 포함 시 취약
        if grep -qF '\' "$F" 2>/dev/null || grep -qiE 'kernel|release|version' "$F" 2>/dev/null; then
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
      [ -n "$NOT_REG" ] && return 2  # 구독 미등록 → 수동확인
      command -v yum &>/dev/null || return 1
      SEC=$(yum updateinfo list security 2>/dev/null | grep -cE 'RHSA-|RHBA-|RHEA-')
      SEC=${SEC:-0}
      [ "$SEC" -gt 0 ] && return 0; return 1 ;;
    U-65)
      systemctl is-active chronyd &>/dev/null && return 1
      systemctl is-active ntpd &>/dev/null && return 1; return 0 ;;
    U-66)
      systemctl is-active rsyslog &>/dev/null && return 1
      systemctl is-active syslog &>/dev/null && return 1
      [ -f /var/log/messages ] || [ -f /var/log/syslog ] && return 1; return 0 ;;
    U-67)
      O=$(stat -c '%U' /var/log 2>/dev/null); P=$(stat -c '%a' /var/log 2>/dev/null)
      [ "$O" = "root" ] && [ "$P" -le 755 ] 2>/dev/null && return 1; return 0 ;;
    U-68)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ ${#_APACHE_CONFIGS[@]} -eq 0 ] && return 2
      for _f in "${_APACHE_CONFIGS[@]}"; do
        grep -v '^#' "$_f" 2>/dev/null | grep -iE 'Options.*Indexes' | grep -iv '\-Indexes' | grep -q . && return 0
      done; return 1 ;;
    U-69)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ -z "$_FIX_APACHE_CONF" ] && return 2
      AUSER=$(grep -v '^#' "$_FIX_APACHE_CONF" | grep -iE '^[[:space:]]*User[[:space:]]' | awk '{print $2}' | tail -1)
      [ "$AUSER" = "root" ] && return 0; [ -z "$AUSER" ] && return 2; return 1 ;;
    U-70)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ ${#_APACHE_CONFIGS[@]} -eq 0 ] && return 2
      for _f in "${_APACHE_CONFIGS[@]}"; do
        _v=$(awk '/<Directory[[:space:]]*"?\/"?[[:space:]]*>/{f=1} f && /AllowOverride/{for(i=2;i<=NF;i++) printf "%s ",$i; printf "\n"; f=0} /<\/Directory>/{f=0}' "$_f" 2>/dev/null | tr -d ' ' | tail -1)
        [ -z "$_v" ] && continue
        echo "$_v" | grep -qi '^None' && return 1
        return 0
      done
      return 0 ;;
    U-71)
      for _d in /var/www/html/manual /usr/local/apache/htdocs/manual /usr/local/apache2/htdocs/manual /usr/share/doc/apache2; do
        [ -d "$_d" ] && return 0
      done; return 1 ;;
    U-72)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ ${#_APACHE_CONFIGS[@]} -eq 0 ] && return 2
      for _f in "${_APACHE_CONFIGS[@]}"; do
        grep -v '^#' "$_f" 2>/dev/null | grep -iE 'Options.*FollowSymLinks' | grep -iv '\-FollowSymLinks' | grep -q . && return 0
      done; return 1 ;;
    U-73)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ ${#_APACHE_CONFIGS[@]} -eq 0 ] && return 2
      for _f in "${_APACHE_CONFIGS[@]}"; do
        LIMIT=$(grep -v '^#' "$_f" 2>/dev/null | grep -i 'LimitRequestBody' | awk '{print $2}' | grep -E '^[0-9]+$' | head -1)
        [ -n "$LIMIT" ] && [ "$LIMIT" -gt 0 ] 2>/dev/null && return 1
      done; return 0 ;;
    U-74) return 2 ;;  # 수동확인
    U-75)
      [ "${_APACHE_SKIP:-0}" -eq 1 ] && return 2
      [ ${#_APACHE_CONFIGS[@]} -eq 0 ] && return 2
      ST=""; SS=""
      for _f in "${_APACHE_CONFIGS[@]}"; do
        _st=$(grep -v '^#' "$_f" 2>/dev/null | grep -i 'ServerTokens' | awk '{print $2}' | tail -1)
        _ss=$(grep -v '^#' "$_f" 2>/dev/null | grep -i 'ServerSignature' | awk '{print $2}' | tail -1)
        [ -n "$_st" ] && ST="$_st"; [ -n "$_ss" ] && SS="$_ss"
      done
      echo "$ST" | grep -qiE '^Prod(uctOnly)?$' && echo "$SS" | grep -qi '^Off$' && return 1; return 0 ;;
    U-76) return 2 ;;  # 수동확인
    *) return 2 ;;
  esac
}

# ── 실시간 점검 단계 (프로그레스바) ───────────────────────────────────────────
# REPORT 빠른 모드: 보고서 작성 이후 상태가 바뀌었을 수 있으므로 재확인하는 단계.
# 전체 스캔 모드(기본): TARGET_IDS(U-01~U-76) 전체를 여기서 처음으로 실제 점검하여
# 취약/양호/해당없음을 가른다. 두 모드 모두 동일한 루프를 공유한다.

# do_manual 처리 대상 ID — check_still_vuln 이 2를 반환해도 수동확인으로 분류
_MANUAL_IDS=(U-08 U-11 U-33 U-47 U-55 U-69 U-74 U-76)
_is_manual_id() {
  local _chk="$1"
  for _m in "${_MANUAL_IDS[@]}"; do [ "$_m" = "$_chk" ] && return 0; done
  return 1
}

# Apache 변수 사전 초기화 — 프리체크 단계에서 check_still_vuln U-68~U-75 호출 시
# 변수가 없어서 오동작하지 않도록 빈 값으로 먼저 설정한다.
# 실제 경로 탐색 및 사용자 선택은 조치 직전 "Apache 설정 파일 탐색" 단계에서 수행한다.
_FIX_APACHE_CONF=""
_APACHE_CONFIGS=()
_APACHE_SKIP=0
for _p in /etc/httpd/conf/httpd.conf /etc/apache2/apache2.conf \
           /usr/local/apache/conf/httpd.conf /usr/local/apache2/conf/httpd.conf; do
  [ -f "$_p" ] && _FIX_APACHE_CONF="$_p" && break
done
[ -z "$_FIX_APACHE_CONF" ] && _APACHE_SKIP=1

_PRECHECK_VULN=(); _PRECHECK_OK=(); _PRECHECK_MANUAL=(); _PRECHECK_NA=()
_pc_total=${#TARGET_IDS[@]}
_pc_idx=0
_pc_barlen=30
for _pid in "${TARGET_IDS[@]}"; do
  _pc_idx=$((_pc_idx+1))
  check_still_vuln "$_pid" >/dev/null 2>&1; _pc_rc=$?
  if _is_manual_id "$_pid"; then
    # U-33처럼 do_manual로 처리되는 항목은 check_still_vuln이 0(취약)을 반환해도
    # 스크립트가 자동으로 고쳐주지 않는다 — 항상 "수동 조치 필요"로 분류해야
    # "실제 조치 필요"에 뜨고선 정작 자동 조치되지 않는 혼란을 막을 수 있다.
    # (반환값 1=이미 양호 인 경우만 예외적으로 양호 처리)
    case $_pc_rc in
      1) _PRECHECK_OK+=("$_pid") ;;
      *) _PRECHECK_MANUAL+=("$_pid") ;;
    esac
  else
    case $_pc_rc in
      0) _PRECHECK_VULN+=("$_pid") ;;
      1) _PRECHECK_OK+=("$_pid") ;;
      *) _PRECHECK_NA+=("$_pid") ;;
    esac
  fi
  _pc_pct=$(( _pc_idx * 100 / _pc_total ))
  _pc_filled=$(( _pc_pct * _pc_barlen / 100 ))
  _pc_bar=""
  for ((_k=0; _k<_pc_filled; _k++)); do _pc_bar+="█"; done
  for ((_k=_pc_filled; _k<_pc_barlen; _k++)); do _pc_bar+="░"; done
  if [ "$_pc_idx" -eq "$_pc_total" ]; then
    printf "\r [%3d%%] [%s] (%d/%d) 점검 완료%-10s" "$_pc_pct" "$_pc_bar" "$_pc_idx" "$_pc_total" ""
  else
    printf "\r [%3d%%] [%s] (%d/%d) 점검 중: %-8s" "$_pc_pct" "$_pc_bar" "$_pc_idx" "$_pc_total" "$_pid"
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
  exit 0
fi

_total_action=$(( ${#_PRECHECK_VULN[@]} + ${#_PRECHECK_MANUAL[@]} ))

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
  _read_yn _proceed_all " 위 자동조치 ${#_PRECHECK_VULN[@]}개 항목을 진행하시겠습니까? (y/n): "
  if [[ "$_proceed_all" != [Yy] ]]; then
    echo -e "${YELLOW} 조치를 취소합니다.${RESET}"
    exit 0
  fi
  echo ""
else
  _read_yn _proceed_all " 위 자동조치 ${#_PRECHECK_VULN[@]}개 + 수동확인 ${#_PRECHECK_MANUAL[@]}개 항목을 순서대로 진행하시겠습니까? (y/n): "
  if [[ "$_proceed_all" != [Yy] ]]; then
    echo -e "${YELLOW} 조치를 취소합니다.${RESET}"
    exit 0
  fi
  echo ""
fi

# ── 구분선 함수 조기 정의 ─────────────────────────────────────────────────────
_div_thick() {
  echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}
_div_thin() {
  echo -e " ──────────────────────────────────────────────────────────────────"
}

# ── 사전 백업 ─────────────────────────────────────────────────────────────────
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
  /etc/sudoers
  /etc/sudoers.d
  /etc/crontab
  /etc/cron.d
  /etc/cron.allow
  /etc/cron.deny
  /var/spool/cron
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
  /etc/vsftpd.conf
  /etc/proftpd
  /etc/proftpd.conf
  /etc/exports
  /etc/httpd/conf
  /etc/httpd/conf.d
  /etc/httpd/conf.modules.d
  /etc/apache2
  /etc/mail
  /etc/exim4
  /etc/profile
  /etc/profile.d
  /etc/bashrc
  /etc/bash.bashrc
)

echo -e " 백업 대상:"
for _t in "${_PRE_BACKUP_TARGETS[@]}"; do
  [ -e "$_t" ] && echo "   $_t"
done
echo ""

_PRE_BAK_DIR="/var/log"
[ -w "$_PRE_BAK_DIR" ] || _PRE_BAK_DIR="$HOME"
[ -w "$_PRE_BAK_DIR" ] || _PRE_BAK_DIR="/tmp"
_PRE_BAK_FILE="${_PRE_BAK_DIR}/vulnFix_backup_$(hostname)_$(date +%Y%m%d_%H%M%S).tar.gz"

_exist_targets=()
for _t in "${_PRE_BACKUP_TARGETS[@]}"; do
  [ -e "$_t" ] && _exist_targets+=("$_t")
done

printf " 백업 중..."
tar czf "$_PRE_BAK_FILE" "${_exist_targets[@]}" 2>/dev/null &
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
  echo -e "   ${YELLOW}※ 조치 실패 시 아래 명령으로 복원하세요:${RESET}"
  echo -e "   ${CYAN}tar xzf ${_PRE_BAK_FILE} -C /${RESET}"
  _PRE_BAK_RECORDED="$_PRE_BAK_FILE"
else
  printf "\r   [%s] 백업 실패%-15s\n" "$_bar_full" ""
  _warn "${_PRE_BAK_DIR} 쓰기 권한 확인 필요 (조치는 계속 진행)"
  _PRE_BAK_RECORDED="백업 실패"
fi
echo ""

# ── 조치 함수 ────────────────────────────────────────────────────────────────

# _safe_append <file> <text>
# 추가 전 exit 0 / 열린 if 블록 여부 검사 — exit 0 앞에 삽입, 열린 if면 경고 후 중단.
# 공용 출력/백업 헬퍼 — 백업·체크마크 출력을 한 곳에서 관리해 색상/기호 불일치를 방지.
_backup_file() {
  # 사용: _backup_file <파일경로> [타임스탬프] → 백업 경로 echo, 실패 시 return 1
  # 여러 파일이 같은 타임스탬프를 공유해야 하면(예: U-01 sshd 설정 일괄 롤백) 호출 전에
  # 만들어서 동일하게 넘길 것 — 안 그러면 _sshd_reload_guard 등의 일괄 복구가 깨진다.
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
_ok()   { echo -e "   ${GREEN}✓${RESET} $1"; }
_fail() { echo -e "   ${RED}✗${RESET} $1"; }
_info() { echo -e "   ${CYAN}→${RESET} $1"; }
_warn() { echo -e "   ${YELLOW}⚠${RESET} $1"; }

# ── UI 레이블 헬퍼 ─────────────────────────────────────────────────────────────
# 모든 인라인 블록이 동일한 레이블/색상/기호를 쓰도록 헬퍼로 통일한다.
_ok()   { echo -e "   ${GREEN}✓${RESET} $1"; }
_fail() { echo -e "   ${RED}✗${RESET} $1"; }
_info() { echo -e "   ${CYAN}→${RESET} $1"; }
_warn() { echo -e "   ${YELLOW}⚠${RESET} $1"; }

# ── 구분선 ────────────────────────────────────────────────────────────────────
# ── 구분선 (위쪽에서 이미 정의됨 — 여기서는 재정의하지 않음) ──────────────────

# ── 항목 헤더 ─────────────────────────────────────────────────────────────────
# _item_header <상태> <ID> <제목>
# 상태: vuln | good | manual | na
_item_header() {
  local state="$1" id="$2" title="$3"
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

# ── 항목 닫기 ─────────────────────────────────────────────────────────────────
# _item_close <done|fail|skip|na>
# 취약점 카드는 시작(_item_header)과 끝(_item_close)에서만 굵은 구분선을 사용한다.
_item_close() {
  case "${1:-done}" in
    done) _lbl_done ;;
    fail) _lbl_fail_v ;;
    skip) _lbl_skip ;;
    na)   : ;;
  esac
  echo ""
}

# ── 섹션 헤더 ─────────────────────────────────────────────────────────────────
# _sec <check|before|during|result|verify|need>
_sec() {
  echo ""
  case "$1" in
    check)  echo -e " ${BOLD}${WHITE}[현재 상태]${RESET}" ;;
    before) echo -e " ${BOLD}${YELLOW}[조치 전]${RESET}" ;;
    during) echo -e " ${BOLD}${BLUE}[조치 중]${RESET}" ;;
    result) echo -e " ${BOLD}${GREEN}[조치 결과]${RESET}" ;;
    verify) echo -e " ${BOLD}${MAGENTA}[최종 검증]${RESET}" ;;
    need)   echo -e " ${BOLD}${YELLOW}[확인 필요]${RESET}" ;;
  esac
  echo ""
}

# ── 테이블 행 ─────────────────────────────────────────────────────────────────
# _row "라벨" "값" ["✓"|"✗"|""]  — 라벨 18칸 고정
_row() {
  local label="$1" value="$2" sym="${3:-}"
  local sym_out=""
  [ "$sym" = "✓" ] && sym_out="${GREEN}✓${RESET}"
  [ "$sym" = "✗" ] && sym_out="${RED}✗${RESET}"
  [ -n "$sym" ] && [ "$sym" != "✓" ] && [ "$sym" != "✗" ] && sym_out="$sym"
  printf "  ${WHITE}%-18s${RESET}: ${WHITE}%s${RESET} %b\n" "$label" "$value" "$sym_out"
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
_lbl_subdiv()  { echo ""; }

# 결과 기록 헬퍼 — FIXED/SKIPPED/MANUAL/FAILED 카운터 증가 + LIST 추가 + FIX_HISTORY_FILE
# 기록을 한 곳에서 처리한다. 기존엔 이 3단계를 항목마다 직접 echo/배열추가/카운터증가로
# 반복해서 빠뜨리기 쉬웠다(U-01/U-02/U-03/U-06이 로그 기록 자체가 빠졌던 사례 — 이번
# 점검에서 실제로 발견·수정함). 함수로 묶으면 누락이 구조적으로 불가능해진다.
_mark_fixed()   { FIXED=$((FIXED+1));     FIXED_LIST+=("$1: $2");   echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|FIXED"   >> "$FIX_HISTORY_FILE" 2>/dev/null; }
_mark_skipped() { SKIPPED=$((SKIPPED+1)); SKIPPED_LIST+=("$1: $2"); echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|SKIPPED" >> "$FIX_HISTORY_FILE" 2>/dev/null; }
_mark_manual()  { MANUAL=$((MANUAL+1));   MANUAL_LIST+=("$1: $2");  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|MANUAL"  >> "$FIX_HISTORY_FILE" 2>/dev/null; }
_mark_failed()  { FAILED=$((FAILED+1));   FAILED_LIST+=("$1: $2");  echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|FAILED"  >> "$FIX_HISTORY_FILE" 2>/dev/null; }
_mark_na()      { NA=$((NA+1));           NA_LIST+=("$1: $2");      echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|NA"      >> "$FIX_HISTORY_FILE" 2>/dev/null; }

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

# _apache_reload_guard <conf_file1> [<conf_file2> ...]
# Apache 설정은 여러 파일(httpd.conf + conf.d/*.conf)에 분산되는 경우가 많다 — 메인
# 파일 1개만 복구하면 같이 수정된 다른 파일이 깨진 채로 남을 수 있어, 전달된 파일
# 전체를 각자의 최신 백업으로 복구한다.
_apache_reload_guard() {
  local files=("$@")
  local test_cmd=""
  command -v apachectl &>/dev/null && test_cmd="apachectl configtest"
  command -v httpd    &>/dev/null && [ -z "$test_cmd" ] && test_cmd="httpd -t"
  command -v apache2  &>/dev/null && [ -z "$test_cmd" ] && test_cmd="apache2 -t"

  if [ -z "$test_cmd" ]; then
    echo -e "   ${YELLOW}!! configtest 명령 없음 — reload 생략 (수동 확인 필요)${RESET}"
    return 1
  fi

  if $test_cmd 2>&1 | grep -q 'Syntax OK'; then
    systemctl reload httpd 2>/dev/null || systemctl reload apache2 2>/dev/null || true
    echo -e "   ${GREEN}configtest OK → reload 완료${RESET}"
    return 0
  else
    echo -e "   ${RED}!! configtest 실패 — 백업에서 복구 중 (수정된 파일 ${#files[@]}개 전체)${RESET}"
    $test_cmd 2>&1 | sed 's/^/   /'
    local _restored=0
    for _cf in "${files[@]}"; do
      [ -z "$_cf" ] && continue
      local latest_bak
      latest_bak=$(ls -t "${_cf}.bak."* 2>/dev/null | head -1)
      if [ -n "$latest_bak" ] && [ -f "$latest_bak" ]; then
        cp "$latest_bak" "$_cf"
        echo -e "   ${GREEN}복구 완료: $latest_bak → $_cf${RESET}"
        _restored=1
      fi
    done
    if [ $_restored -eq 0 ]; then
      echo -e "   ${RED}!! 백업 파일 없음 — 수동 복구 필요${RESET}"
    else
      # 복구 후 재검증 — 모든 파일을 되돌렸는데도 여전히 문법 오류면 다른 원인이 있을 수 있음
      if $test_cmd 2>&1 | grep -q 'Syntax OK'; then
        echo -e "   ${GREEN}복구 후 재검증 통과${RESET}"
      else
        echo -e "   ${RED}!! 복구 후에도 여전히 문법 오류 — 수동 확인 필요${RESET}"
      fi
    fi
    return 1
  fi
}

# _sshd_reload_guard
# "sshd -t" 문법 검증 통과 시에만 reload하고, 실패 시 백업에서 즉시 복구한다.
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
    if grep -q 'pam_tally2\|pam_tally\b\|pam_faillock' "$_pf"; then
      sed -i "s/deny=[0-9]*/deny=${_deny}/g; s/unlock_time=[0-9]*/unlock_time=${_unlock}/g" "$_pf"
      echo -e " ${GREEN}→ $_pf deny/unlock_time 수정 완료${RESET}"
    else
      sed -i "/^auth.*sufficient.*pam_unix/i auth        required      pam_faillock.so preauth silent audit deny=${_deny} unlock_time=${_unlock}" "$_pf"
      echo -e " ${GREEN}→ $_pf pam_faillock.so 라인 추가 완료${RESET}"
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
      sleep "$timeout"
      for ((i=0; i<${#pairs[@]}; i+=2)); do
        bak="${pairs[i]}"; tgt="${pairs[i+1]}"
        [ -f "$bak" ] && cp -p "$bak" "$tgt"
      done
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] PAM 변경 미확인 타임아웃 → 자동 롤백 실행됨: ${pairs[*]}" >> /var/log/vulnFixHistory.log 2>/dev/null
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
      if [[ "$_confirm_ok" == "e" || "$_confirm_ok" == "E" ]]; then
        kill "$_wd_pid" 2>/dev/null; wait "$_wd_pid" 2>/dev/null
        echo -e "${YELLOW}→ ${timeout}초 연장합니다. 계속 확인해 주세요.${RESET}"
        _start_wd
        continue
      fi
      kill "$_wd_pid" 2>/dev/null; wait "$_wd_pid" 2>/dev/null
      echo -e "${GREEN}→ 확인 완료. PAM 변경 사항을 유지합니다.${RESET}"
      return 0
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
    "웹 서버(Apache) 보안 설정") echo "(U-68 ~ U-76)" ;;
    *) echo "" ;;
  esac
}
_flush_header() {
  if [ -n "$_PENDING_HEADER" ]; then
    local _range
    _range="$(_section_range "$_PENDING_HEADER")"
    echo ""
    _div_thick
    echo -e " ${CYAN}■${RESET} ${BOLD}${_PENDING_HEADER}${RESET} ${WHITE}${_range}${RESET}"
    _div_thick
    echo ""
    _PENDING_HEADER=""
    _JUST_PRINTED_SECTION=1
  fi
}

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
    local cur_out=""
    [ -n "$before_cmd" ] && cur_out=$(eval "$before_cmd" 2>/dev/null)
    if [ -n "$cur_out" ]; then
      echo "$cur_out" | sed 's/^/   /'
    else
      # before 명령이 이상 항목만 출력하는 유형(U-32 등)은 양호 시 빈 출력이 됨 —
      # 섹션이 통째로 생략되지 않도록 양호 사유를 명시한다.
      echo -e "   ${GREEN}✔${RESET} 이상 항목 없음 (점검 통과)"
    fi
    AFTER_VAL["$id"]="이미 양호 (재확인 통과)"
    _mark_skipped "$id" "${title} [이미양호]"
    echo ""; return

  # ── 해당없음 ──────────────────────────────────────────────────────────────
  elif [ $vuln_status -eq 2 ]; then
    _item_header "na" "$id" "$title"
    _info "서비스 미운용으로 조치 불필요"
    AFTER_VAL["$id"]="해당없음"
    NA=$((NA+1)); NA_LIST+=("${id}: ${title}")
    echo ""; return
  fi

  # ── 취약 ──────────────────────────────────────────────────────────────────
  _item_header "vuln" "$id" "$title"

  # [확인 상태]
  local before_out; before_out=$(eval "$before_cmd" 2>/dev/null)
  _sec check
  if [ -n "$before_out" ]; then
    echo "$before_out" | sed 's/^/   /'
  else
    echo "   (출력된 설정 값 없음 — 미설정 상태)"
  fi
  BEFORE_VAL["$id"]=$(echo "$before_out" | grep -v '^[[:space:]]*$' | head -5)

  echo ""
  _lbl_yn
  _read_yn yn " 조치하시겠습니까? (y/n): "
  case "$yn" in
    [Yy])
      # [조치 중] — 무엇을 하는지 신뢰할 수 있도록 실제 실행 명령을 먼저 보여준다.
      _sec during
      echo -e "   ${CYAN}$ 다음 명령을 실행합니다${RESET}"
      echo "$fix_cmd" | sed -e 's/^[[:space:]]*//' -e '/^$/d' -e 's/^/     /'
      echo ""
      # fix_cmd 안에서 언급된 /etc 절대경로 파일을 조치 전에 개별 백업한다.
      # 스크립트 시작 시의 통짜 tar 백업과 별개로, 이 항목 하나만 콕 집어
      # 되돌리고 싶을 때 쓸 수 있는 개별 스냅샷이다. (이미 존재하는 대상만,
      # 이번 실행에서 처음 건드리는 파일만 — 같은 실행 중 여러 항목이 같은
      # 파일을 건드려도 "이번 실행 시작 전" 상태 하나만 보존한다.)
      while IFS= read -r _bt; do
        [ -z "$_bt" ] && continue
        [ -f "$_bt" ] || continue
        [ -e "${_bt}.bak.${_RUN_TS}" ] || cp -p "$_bt" "${_bt}.bak.${_RUN_TS}" 2>/dev/null
      done < <(grep -oE '/etc/[A-Za-z0-9_./-]+' <<< "$fix_cmd" | sort -u)
      # 주의: $(eval ...) 서브셸 캡처를 쓰면 fix_cmd 안의 export(예: U-14의
      # PATH 정리)가 본 셸에 반영되지 않아 검증이 오탐한다. 현재 셸에서
      # 실행하고 출력만 임시파일로 캡처한다.
      local _fix_tmp; _fix_tmp=$(mktemp 2>/dev/null || echo "/tmp/.vulnfix_out.$$")
      eval "$fix_cmd" >"$_fix_tmp" 2>/dev/null
      if [ -s "$_fix_tmp" ]; then
        sed 's/^[^[:space:]]/   &/' "$_fix_tmp"
      else
        # postconf/sed/chmod 등 무출력 명령이면 헤더만 비어 보이므로 진행 표시를 남긴다
        echo -e "   ${CYAN}→${RESET} 실행 완료 (출력 없음)"
      fi
      rm -f "$_fix_tmp"

      # [조치 결과]
      local after_out; after_out=$(eval "$after_cmd" 2>/dev/null)
      _sec result
      echo "$after_out" | sed 's/^/   /'
      AFTER_VAL["$id"]=$(echo "$after_out" | grep -v '^[[:space:]]*$' | head -5)

      # 검증 (출력 없이 판정만 — [조치 결과] 직후 완료/실패 라벨로 통일)
      local verified=0
      [ -n "$pass_pattern" ] && echo "$after_out" | grep -qE "$pass_pattern" && verified=1
      [ -z "$pass_pattern" ] && verified=1
      echo ""
      if [ $verified -eq 1 ]; then
        _item_close done
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
    local cur_out=""
    [ -n "$status_cmd" ] && cur_out=$(eval "$status_cmd" 2>/dev/null)
    if [ -n "$cur_out" ]; then
      echo "$cur_out" | sed 's/^/   /'
    else
      echo -e "   ${GREEN}✔${RESET} 이상 항목 없음 (점검 통과)"
    fi
    echo ""
    _mark_skipped "$id" "${title} [이미양호]"
  else
    _item_header "manual" "$id" "$title"
    if [ -n "$status_cmd" ]; then
      _sec check
      eval "$status_cmd" 2>/dev/null | sed 's/^/   /'
    fi
    _sec need
    echo "   $desc" | sed 's/\\n/\n   /g'
    echo ""
    _info "위 현재 상태를 보안정책과 대조하여 직접 판단이 필요합니다."
    _item_close na
    _mark_manual "$id" "${title} — ${desc}"
  fi
  echo ""
}


# ============================================================
section_header "계정 관리"
# ============================================================

# U-01 root 계정 원격 접속 제한 — SSH + Telnet(PAM) 분기 처리
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
      _mark_skipped "U-01" "root 원격접속 제한 [이미양호]"
      echo ""

    else
      _item_header "vuln" "U-01" "(상) root 계정 원격 접속 제한"
      echo ""

      # ── [SSH 설정] ──────────────────────────────────────────────────────────
      echo -e " ${YELLOW}[SSH 설정]${RESET}"
      echo ""
      _u01_literal=$(grep -i 'PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | grep -v '^\s*#')

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
      _u01_telnet_on=0
      ss -tlnp 2>/dev/null | grep -q ':23 ' && _u01_telnet_on=1
      pgrep -x telnetd &>/dev/null && _u01_telnet_on=1

      if [ "$_u01_telnet_on" -eq 0 ]; then
        echo -e "   Telnet 서비스 : ${GREEN}미사용${RESET}"
        echo ""
        _info "securetty / pam_securetty 점검 제외"
      else
        echo -e "   Telnet 서비스 : ${RED}활성${RESET}"
        echo ""
        _u01_pts=$(grep -v '^#' /etc/securetty 2>/dev/null | grep '^pts/')
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
              sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin no/I' "$_cf"
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
            [ "${PTS_COUNT:-0}" -gt 0 ] && sed -i '/^pts\//s/^/#/' /etc/securetty
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
          _mark_fixed "U-01" "root 계정 원격 접속 제한 완료"
        else
          _lbl_fail_v
          AFTER_VAL["U-01"]="${_u01_after:-확인불가} [검증실패]"
          _mark_failed "U-01" "root 계정 원격 접속 제한 — 조치 시도했으나 검증 기준 미충족"
        fi
        echo ""
      fi
    fi
  fi
}

# U-02 비밀번호 관리정책 — PASS_MAX_DAYS 사용자 선택 입력
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
      grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null \
        | grep -E 'minlen|ucredit|lcredit|dcredit|ocredit|retry' | sed 's/^/   /'
      echo ""
            _mark_skipped "U-02" "비밀번호 관리정책 [이미양호]"
      echo ""
    else
      _item_header "vuln" "U-02" "(상) 비밀번호 관리정책 설정"
      echo ""
      _lbl_before
      grep -v '^\s*#' /etc/login.defs | grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS' | sed 's/^/   /'
      _u02_minlen_out=$(grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null | grep 'minlen')
      if [ -n "$_u02_minlen_out" ]; then echo "$_u02_minlen_out" | sed 's/^/   /'; else echo "   minlen 미설정"; fi
      grep -v '^\s*#' /etc/security/pwquality.conf 2>/dev/null \
        | grep -E 'ucredit|lcredit|dcredit|ocredit|retry' | sed 's/^/   /'
      echo ""

      _lbl_yn
      _read_yn _yn_u02 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u02" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-02" "비밀번호 관리정책 [건너뜀]"
        echo ""
      else
      # 1회짜리 루프 — 아래 "KISA 권고 초과" 분기에서 continue로 조치 로직 전체를
      # 건너뛰기 위한 구조. ({} 그룹 안에서는 continue/break가 조용히 무시되어
      # 조기 종료가 안 되고 아래로 흘러 조치까지 수행되는 버그가 있었음.)
      for _u02_once in 1; do
      echo -e " ${YELLOW}[!] 비밀번호 최대 사용기간(PASS_MAX_DAYS)을 입력하세요.${RESET}"
      echo -e "     권고: ${DEFAULT_PASS_MAX_DAYS}일 이하 (KISA 권고 기본값: ${DEFAULT_PASS_MAX_DAYS})"
      while true; do
        read -rp " 최대 사용기간(일) 입력: " _max_input
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

      # 가이드 조치 예시처럼 4종류(대/소문자·숫자·특수문자) 모두 -1(강제)을 기본값으로
      # 적용한다. 과거엔 ucredit만 받고 나머지를 0(미사용)으로 고정해서 문자종류 1개만
      # 설정되어 우리 판정 기준(2종류 이상)도 못 만족하는 문제가 있었음.
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

      echo -e "     pam_pwquality.so enforce_for_root 적용?"
      echo -e "     (system-auth, password-auth에 추가) (y/n)"
      read -rp "     적용 여부: " _pam_yn
      if [[ "$_pam_yn" =~ ^[Yy]$ ]]; then
        ENFORCE_ROOT="enforce_for_root"
        PAM_APPLY=1
      else
        ENFORCE_ROOT=""
        PAM_APPLY=0
      fi

      _lbl_during
      echo -e "   ${CYAN}→${RESET} /etc/login.defs, pwquality.conf 정책 적용"

      grep -q '^\s*PASS_MAX_DAYS' /etc/login.defs \
        && sed -i "s/^\s*PASS_MAX_DAYS.*/PASS_MAX_DAYS\t${MAX_DAYS}/" /etc/login.defs \
        || echo -e "PASS_MAX_DAYS\t${MAX_DAYS}" >> /etc/login.defs

      grep -q '^\s*PASS_MIN_DAYS' /etc/login.defs \
        && sed -i "s/^\s*PASS_MIN_DAYS.*/PASS_MIN_DAYS\t${MIN_DAYS}/" /etc/login.defs \
        || echo -e "PASS_MIN_DAYS\t${MIN_DAYS}" >> /etc/login.defs

      [ -f /etc/security/pwquality.conf ] || touch /etc/security/pwquality.conf

      _set_pwq() {
        local key="$1" val="$2"
        grep -q "^\s*${key}\s*=" /etc/security/pwquality.conf \
          && sed -i "s/^\s*${key}\s*=.*/${key} = ${val}/" /etc/security/pwquality.conf \
          || echo "${key} = ${val}" >> /etc/security/pwquality.conf
      }

      _set_pwq "minlen"   "$MINLEN"
      _set_pwq "retry"    "$RETRY"
      [ "$UCREDIT" -ne 0 ]  && _set_pwq "ucredit"  "$UCREDIT"
      [ "$LCREDIT" -ne 0 ]  && _set_pwq "lcredit"  "$LCREDIT"
      [ "$DCREDIT" -ne 0 ]  && _set_pwq "dcredit"  "$DCREDIT"
      [ "$OCREDIT" -ne 0 ]  && _set_pwq "ocredit"  "$OCREDIT"

      if [ "$PAM_APPLY" -eq 1 ]; then
        # RHEL 계열: system-auth/password-auth. Debian/Ubuntu 계열은 이 파일이
        # 없고 대신 common-password를 쓴다 — 예전엔 이 목록에 common-password가
        # 빠져 있어서, Debian에서는 pwquality.conf 값만 쓰이고 PAM이 그 모듈을
        # 아예 호출하지 않는데도 "조치 완료"로 표시되는 문제가 있었다.
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

      # 예전 버전에서 썼던 minclass 잔존 라인이 있으면 정리 (지금은 minclass를 더 이상
      # 관리하지 않으므로, 혼란을 주는 옛 값이 파일에 남아있지 않도록 함)
      sed -i '/^[[:space:]]*minclass[[:space:]]*=/d' /etc/security/pwquality.conf 2>/dev/null

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
      BEFORE_VAL["U-02"]="조치 전 설정 확인"
      _lbl_done_nr

      if [ "$PAM_APPLY" -eq 1 ] && command -v authselect &>/dev/null && authselect current &>/dev/null; then
        # authselect가 system-auth/password-auth를 프로필 템플릿으로부터 생성·관리하는
        # 시스템에서는, 방금 sed로 넣은 pam_pwquality 줄이 이후 누군가
        # authselect select/apply-changes를 실행하면(도메인 재가입, 다른 담당자의
        # 프로필 변경 등) 조용히 초기화(원상복구)될 수 있다. pwquality.conf의
        # minlen/ucredit 등 수치 설정 자체는 별도 파일이라 영향받지 않지만,
        # enforce_for_root 적용 여부는 authselect 작업에 따라 달라질 수 있다.
        echo ""
        echo -e " ${YELLOW}※ 이 시스템은 authselect로 PAM을 관리합니다.${RESET}"
        echo -e " ${YELLOW}  방금 적용한 pam_pwquality 설정 줄은 이후 'authselect select' 또는${RESET}"
        echo -e " ${YELLOW}  'authselect apply-changes'가 실행되면 초기화될 수 있습니다${RESET}"
        echo -e " ${YELLOW}  (pwquality.conf의 minlen/ucredit 등 수치값 자체는 영향받지 않습니다).${RESET}"
        echo -e " ${YELLOW}  영구 적용하려면 authselect custom profile 사용을 권장합니다.${RESET}"
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
      fi  # Y/N 분기 종료
    echo ""
  fi
}

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-03" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-03"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
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
      echo ""; _lbl_before
      for _pf in /etc/security/faillock.conf /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-auth; do
        [ -f "$_pf" ] && grep -v '^#' "$_pf" | grep -E 'deny|unlock_time|pam_tally|pam_faillock' | sed "s|^|   [$_pf] |" | head -3
      done
      echo ""
      _lbl_yn
      _read_yn _yn_u03 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u03" != [Yy] ]]; then
        _lbl_skip
        _mark_skipped "U-03" "계정 잠금 임계값 [건너뜀]"
        echo ""
      else
      echo -e " ${YELLOW}[!] 계정 잠금 실패 횟수(deny)를 입력하세요.${RESET}"
      echo -e "     권고: 10회 이하 (KISA 권고 기본값: ${DEFAULT_DENY})"
      _read_num DENY_VAL " 실패 횟수 입력: " "$DEFAULT_DENY" 1 10
      echo -e " ${YELLOW}[!] 계정 잠금 해제 시간(unlock_time, 초)을 입력하세요.${RESET}"
      echo -e "     권고: ${DEFAULT_UNLOCK_TIME}초 이상 (KISA 권고 기본값: ${DEFAULT_UNLOCK_TIME})"
      _read_num UNLOCK_VAL " 잠금 해제 시간(초) 입력: " "$DEFAULT_UNLOCK_TIME" 1
      _lbl_during
      # 입력값은 여기서 즉시 faillock.conf에 기록한다 (파일이 있는 신형 환경).
      # 예전에는 authselect 경로 성공 분기 안에서만 기록해서, 사용자가 재생성을
      # 취소하면 "적용"이라 출력해놓고 실제로는 아무 값도 남지 않는 문제가 있었다.
      # PAM 연결(다음 단계)과 무관하게 값 자체는 보존되며, 연결이 안 된 상태는
      # 재점검 시 수동확인으로 정확히 분류된다.
      if [ -f /etc/security/faillock.conf ]; then
        _fc=/etc/security/faillock.conf
        grep -q '^\s*deny\s*=' "$_fc"        && sed -i "s/^\s*deny\s*=.*/deny = ${DENY_VAL}/"               "$_fc" || echo "deny = ${DENY_VAL}"               >> "$_fc"
        grep -q '^\s*unlock_time\s*=' "$_fc" && sed -i "s/^\s*unlock_time\s*=.*/unlock_time = ${UNLOCK_VAL}/" "$_fc" || echo "unlock_time = ${UNLOCK_VAL}" >> "$_fc"
        echo -e "   ${CYAN}→${RESET} /etc/security/faillock.conf 에 deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL} 기록"
      else
        echo -e "   ${CYAN}→${RESET} 적용 예정 값: deny=${DENY_VAL}, unlock_time=${UNLOCK_VAL}"
      fi

      # faillock.conf "파일이 존재하기만 하면" 연결된 것으로 잘못 간주했던 과거 버그 수정용 —
      # RHEL8/9는 그 파일이 패키징 기본값으로 항상 존재하지만, PAM이 실제로 호출하는지는
      # 별개의 사실이라 직접 확인이 필요하다.
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
          grep -q '^\s*deny\s*=' "$_fc"       && sed -i "s/^\s*deny\s*=.*/deny = ${DENY_VAL}/"             "$_fc" || echo "deny = ${DENY_VAL}"             >> "$_fc"
          grep -q '^\s*unlock_time\s*=' "$_fc" && sed -i "s/^\s*unlock_time\s*=.*/unlock_time = ${UNLOCK_VAL}/" "$_fc" || echo "unlock_time = ${UNLOCK_VAL}" >> "$_fc"
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
          } >> "$FIX_HISTORY_FILE" 2>/dev/null

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
          _info "상세 원문은 $FIX_HISTORY_FILE 에 저장했습니다."
          echo ""
          echo -e " ${YELLOW}권장${RESET}"
          echo "   1) PAM 파일 수동 수정  (기존 custom 설정 보존)"
          echo "   2) authselect --force 재생성  (Profile 기준 재생성, 직접 수정한 내용 삭제됨)"
          echo "   3) 건너뛰기"
          echo ""
          while true; do
            if ! read -rp " 선택 (1/2/3): " _u03_as_menu; then
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
                  } >> "$FIX_HISTORY_FILE" 2>/dev/null

                  # 화면엔 요약만
                  echo ""
                  _u03_as_bak_dir2=$(ls -d /var/lib/authselect/backups/* 2>/dev/null | tail -1)
                  _ok "기존 PAM 파일 백업 완료  (*.bak.${_u03_as_bak_ts2})"
                  [ -n "$_u03_as_bak_dir2" ] && _info "authselect 백업 위치: ${_u03_as_bak_dir2}"
                  if [ $_u03_as_force_rc -eq 0 ]; then
                    _ok "Profile(${_u03_prof}) 기준으로 PAM 파일 재생성 완료"
                    _ok "with-faillock 적용 완료"
                    echo ""
                    _info "상세 원문은 $FIX_HISTORY_FILE 에 저장했습니다."
                    echo ""
                    echo -e " ${YELLOW}다음 단계${RESET}"
                    echo "   - faillock.conf 값 설정 (deny / unlock_time)"
                    echo "   - PAM 연결 상태 재검증: authselect current / grep faillock /etc/pam.d/system-auth"
                    # faillock.conf 값 적용
                    _fc=/etc/security/faillock.conf; [ -f "$_fc" ] || touch "$_fc"
                    grep -q '^\s*deny\s*=' "$_fc"         && sed -i "s/^\s*deny\s*=.*/deny = ${DENY_VAL}/"             "$_fc" || echo "deny = ${DENY_VAL}"             >> "$_fc"
                    grep -q '^\s*unlock_time\s*=' "$_fc"  && sed -i "s/^\s*unlock_time\s*=.*/unlock_time = ${UNLOCK_VAL}/" "$_fc" || echo "unlock_time = ${UNLOCK_VAL}" >> "$_fc"
                    _ok "faillock.conf  deny=${DENY_VAL}  unlock_time=${UNLOCK_VAL} 설정 완료"
                  else
                    _fail "authselect --force 실패 — 상세 원문은 $FIX_HISTORY_FILE 참조"
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

        # 만일을 위해 현재 파일도 백업 (주 복구 수단은 authselect disable-feature이지만 방어적으로 남겨둠)
        _u03_as_bak_ts=$(date +%Y%m%d_%H%M%S)
        for _pf in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
          [ -f "$_pf" ] && _backup_file "$_pf" "$_u03_as_bak_ts" >/dev/null
        done

        _u03_as_out=$(authselect enable-feature with-faillock 2>&1)
        _u03_as_rc=$?
        # 원문 로그 저장
        {
          echo "=== U-03 authselect enable-feature 원문 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
          echo "$_u03_as_out"
          echo "==="
        } >> "$FIX_HISTORY_FILE" 2>/dev/null

        if [ $_u03_as_rc -ne 0 ]; then
          _fail "authselect enable-feature 실패 — 상세 원문은 $FIX_HISTORY_FILE 참조"
        else
          _fc=/etc/security/faillock.conf; [ -f "$_fc" ] || touch "$_fc"
          grep -q '^\s*deny\s*=' "$_fc"       && sed -i "s/^\s*deny\s*=.*/deny = ${DENY_VAL}/"             "$_fc" || echo "deny = ${DENY_VAL}"             >> "$_fc"
          grep -q '^\s*unlock_time\s*=' "$_fc" && sed -i "s/^\s*unlock_time\s*=.*/unlock_time = ${UNLOCK_VAL}/" "$_fc" || echo "unlock_time = ${UNLOCK_VAL}" >> "$_fc"

          # authselect/system-auth/password-auth를 각각 따로 확인해서 어디가 실패했는지
          # 바로 짚는다 (_u03_pam_wired()는 boolean만 알려줘서 디버깅엔 부족함).
          echo ""
          echo -e " ${CYAN}[검증] faillock PAM 적용 여부 확인 중...${RESET}"
          _AUTHSELECT_OK=0; _SYSTEM_AUTH_OK=0; _PASSWORD_AUTH_OK=0

          authselect current 2>/dev/null | grep -q "with-faillock" && _AUTHSELECT_OK=1

          grep -qE 'pam_faillock\.so.*preauth' /etc/pam.d/system-auth 2>/dev/null && \
          grep -qE 'pam_faillock\.so.*authfail' /etc/pam.d/system-auth 2>/dev/null && \
          _SYSTEM_AUTH_OK=1

          grep -qE 'pam_faillock\.so.*preauth' /etc/pam.d/password-auth 2>/dev/null && \
          grep -qE 'pam_faillock\.so.*authfail' /etc/pam.d/password-auth 2>/dev/null && \
          _PASSWORD_AUTH_OK=1

          if [ "$_AUTHSELECT_OK" -eq 1 ] && [ "$_SYSTEM_AUTH_OK" -eq 1 ] && [ "$_PASSWORD_AUTH_OK" -eq 1 ]; then
            echo -e " ${GREEN}→ 검증 완료: with-faillock 및 PAM 연결 정상${RESET}"
            _u03_as_verified=1
          else
            echo -e " ${RED}→ 검증 실패 또는 불완전 — authselect 명령은 성공했지만 PAM 연결 상태가 예상과 다릅니다.${RESET}"
            echo "   authselect with-faillock : ${_AUTHSELECT_OK}"
            echo "   system-auth preauth/authfail : ${_SYSTEM_AUTH_OK}"
            echo "   password-auth preauth/authfail : ${_PASSWORD_AUTH_OK}"
            echo "   수동 확인 명령: authselect current / grep faillock /etc/pam.d/system-auth /etc/pam.d/password-auth"
            _u03_as_verified=0
          fi

          if [ "$_u03_as_verified" -eq 1 ]; then
          # PAM이 실제로 연결됐을 때만 로그인 영향 가능성이 있으므로 이때만 워치독 가동.
          # 복구는 파일 직접 복원이 아니라 authselect disable-feature로 — 직접 덮어쓰면
          # authselect의 추적 상태가 깨져 다음 변경이 막힐 수 있다.
          _u03_as_timeout=90
          _u03_as_wd_pid=""
          _u03_as_start_wd() {
            ( sleep "$_u03_as_timeout"
              authselect disable-feature with-faillock 2>/dev/null
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] U-03 authselect 변경 미확인 타임아웃 → with-faillock 자동 해제됨" >> /var/log/vulnFixHistory.log 2>/dev/null
            ) &
            _u03_as_wd_pid=$!
          }
          echo -e "${RED}⚠ 중요: PAM 인증 설정을 변경했습니다 (authselect with-faillock).${RESET}"
          echo -e "${YELLOW}   1) 지금 이 터미널/세션은 절대 닫지 마세요.${RESET}"
          echo -e "${YELLOW}   2) 새 터미널(또는 새 SSH 접속, su)을 열어 로그인이 정상적으로 되는지 확인하세요.${RESET}"
          echo -e "${YELLOW}   3) 정상이면 아래에서 Enter를 누르세요 — 변경 사항이 그대로 유지됩니다.${RESET}"
          echo -e "${YELLOW}   4) 시간이 더 필요하면 e 를 입력하세요 — ${_u03_as_timeout}초가 다시 주어집니다.${RESET}"
          echo -e "${YELLOW}   5) ${_u03_as_timeout}초 안에 아무 입력도 없으면 'authselect disable-feature with-faillock'으로 자동 복구됩니다.${RESET}"
          _u03_as_start_wd
          while true; do
            if read -t "$_u03_as_timeout" -rp " 새 세션에서 로그인 확인 완료 → Enter, 시간 더 필요하면 e (${_u03_as_timeout}초 제한): " _u03_as_confirm; then
              if [[ "$_u03_as_confirm" == "e" || "$_u03_as_confirm" == "E" ]]; then
                kill "$_u03_as_wd_pid" 2>/dev/null; wait "$_u03_as_wd_pid" 2>/dev/null
                echo -e " ${YELLOW}→ ${_u03_as_timeout}초 연장합니다. 계속 확인해 주세요.${RESET}"
                _u03_as_start_wd
                continue
              fi
              kill "$_u03_as_wd_pid" 2>/dev/null; wait "$_u03_as_wd_pid" 2>/dev/null
              echo -e " ${GREEN}→ 확인 완료. authselect with-faillock 설정을 유지합니다.${RESET}"
            else
              echo ""
              echo -e " ${RED}→ 시간 초과 — authselect disable-feature with-faillock 으로 자동 복구합니다.${RESET}"
              wait "$_u03_as_wd_pid" 2>/dev/null
            fi
            break
          done
          else
            # 정적 검증에서 이미 PAM이 안 연결된 것으로 확인됐으므로, 사람 확인을 기다릴 필요 없이
            # 곧바로 되돌린다 — 어차피 "정상 로그인되는지" 확인할 대상 자체가 없는 상태이기 때문.
            echo -e " ${YELLOW}   PAM이 정상 연결되지 않은 것으로 확인되어, 즉시 authselect disable-feature with-faillock 으로 되돌립니다.${RESET}"
            authselect disable-feature with-faillock 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S')|U-03|정적 검증 실패로 with-faillock 즉시 롤백됨|FAILED" >> "$FIX_HISTORY_FILE" 2>/dev/null
          fi
        fi
        fi
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
        BEFORE_VAL["U-03"]="계정 잠금 미설정"
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

{
  _match=0
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
    elif [ $_vs -eq 2 ]; then
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
        else
          echo -e " ${RED}⚠ wheel 그룹에 사용자가 없습니다.${RESET}"
          echo -e " ${YELLOW}   현재 설정에서는 root를 제외한 일반 사용자는 su 명령을 사용할 수 없습니다.${RESET}"
          echo -e " ${YELLOW}   운영 정책에 맞게 wheel 그룹에 허용 계정을 추가하십시오.${RESET}"
          echo ""
          echo -e " ${YELLOW}wheel 그룹에 추가할 계정을 입력하세요. (예: admin)${RESET}"
          echo -e " ${YELLOW}Enter만 누르면 건너뜁니다.${RESET}"
        fi
      else
        echo -e " ${YELLOW}[!] pam_wheel.so 존재하나 use_uid/group= 옵션 없음 — 실제 제한 미적용 가능성${RESET}"
        echo "   ${WHEEL_LINE}"
        echo ""
        echo -e " ${YELLOW}wheel 그룹에 추가할 계정을 입력하세요. (예: admin)${RESET}"
        echo -e " ${YELLOW}Enter만 누르면 건너뜁니다.${RESET}"
      fi
      read -rp " 계정: " _u06_wheel_user
      if [ -n "$_u06_wheel_user" ] && id "$_u06_wheel_user" &>/dev/null; then
        usermod -aG wheel "$_u06_wheel_user"
        _u06_wheel_after1=$(grep '^wheel:' /etc/group | cut -d: -f4)
        if echo "$_u06_wheel_after1" | tr ',' '\n' | grep -qx "$_u06_wheel_user"; then
          echo ""
          echo -e " ${CYAN}→${RESET} ${_u06_wheel_user} 계정을 wheel 그룹에 추가했습니다."
          echo ""
          _lbl_result
          echo "   pam_wheel.so : 적용됨"
          echo "   wheel 그룹   :"
          echo "$_u06_wheel_after1" | tr ',' '\n' | sed 's/^/     - /'
          echo ""
          _lbl_done_nr
        else
          _fail "wheel: ${_u06_wheel_after1}  (추가가 반영되지 않은 것으로 보입니다 — 수동 확인 필요)"
        fi
        _mark_fixed "U-06" "${_u06_wheel_user} 계정을 wheel 그룹에 추가"
      else
        [ -n "$_u06_wheel_user" ] && echo -e " ${RED}!! ${_u06_wheel_user} 계정을 찾을 수 없습니다 — 추가하지 않았습니다.${RESET}"
        echo -e " ${YELLOW}→ wheel 그룹을 비워두는 것도 보안상 유효한 선택입니다(su 자체를 막는 효과). 운영 정책에 따라 결정하세요.${RESET}"
        _mark_manual "U-06" "pam_wheel.so use_uid 옵션 또는 wheel 그룹 멤버 확인 필요"
      fi
    else
      _item_header "vuln" "U-06" "(상) 사용자 계정 su 기능 제한"
      echo ""; _lbl_before
      _u06_wheel_out=$(grep -v '^#' /etc/pam.d/su 2>/dev/null | grep pam_wheel)
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
        if [ $_rs -eq 1 ]; then
          echo ""
          _lbl_done
          _mark_fixed "U-06" "조치 완료 (pam_wheel.so use_uid 추가)"
        elif [ $_rs -eq 2 ]; then
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

          _u06_wheel_user2=""
          while true; do
            read -rp " 계정: " _u06_wheel_user2
            [ -z "$_u06_wheel_user2" ] && break
            if ! id "$_u06_wheel_user2" &>/dev/null; then
              echo -e " ${RED}✗ ${_u06_wheel_user2} 계정을 찾을 수 없습니다.${RESET}"
              read -rp " 다시 입력하시겠습니까? (y/n): " _u06_retry
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
              usermod -aG wheel "$_u06_wheel_user2"
              _u06_wheel_after=$(grep '^wheel:' /etc/group | cut -d: -f4)
              if echo "$_u06_wheel_after" | tr ',' '\n' | grep -qx "$_u06_wheel_user2"; then
                echo ""
                echo -e " ${CYAN}→${RESET} ${_u06_wheel_user2} 계정을 wheel 그룹에 추가했습니다."
                _mark_fixed "U-06" "조치 완료 (pam_wheel.so 추가 + ${_u06_wheel_user2} wheel 추가)"
              else
                _fail "wheel: ${_u06_wheel_after}  (추가가 반영되지 않은 것으로 보입니다 — 수동 확인 필요)"
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
    echo ""
  fi
}

do_fix "U-07" "(하) 불필요한 계정 제거" \
  "_o=\$(for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd && echo \"\$a 존재\"
   done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '불필요 계정 없음'" \
  "for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd || continue
     passwd -l \"\$a\" 2>/dev/null && echo \"   \$a 잠금 완료\"
   done" \
  "_o=\$(for a in adm lp sync shutdown halt news uucp operator games gopher; do
     grep -q \"^\${a}:\" /etc/passwd || continue
     PW=\$(grep \"^\${a}:\" /etc/shadow 2>/dev/null | awk -F: '{print \$2}')
     echo \"\$a: \$PW\"
   done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '계정 없음 (VERIFY_OK)'" \
  ""

do_manual "U-08" "(중) 관리자 그룹에 최소한의 계정 포함" \
  "wheel/sudo 그룹 멤버가 업무상 반드시 필요한 계정만 포함되어 있는지 보안정책과 대조 필요" \
  "for grp in wheel sudo admin; do
     members=\$(grep \"^\${grp}:\" /etc/group 2>/dev/null | cut -d: -f4)
     [ -z \"\$members\" ] && continue
     echo \"\$grp 그룹 멤버:\"
     echo \"\$members\" | tr ',' '\\n' | sed 's/^/  - /'
     echo ''
   done"

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

do_manual "U-11" "(하) 사용자 Shell 점검" \
  "로그인 가능 계정의 shell이 업무상 필요한지 보안정책과 대조 필요\n(불필요한 계정은 /sbin/nologin 또는 /bin/false 로 변경)" \
  "echo '계정명              UID    Shell'
   echo '──────────────────────────────────────────'
   awk -F: '\$3>=1000&&\$7!~/nologin|false/&&\$7!=\"\"{printf \"%-20s %-6s %s\n\",\$1,\$3,\$7}' /etc/passwd"

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
      echo -e "   readonly TMOUT 미설정 — /etc/profile.d/tmout.sh 에 추가 권장"
      _info "위 현재 상태를 보안정책과 대조하여 직접 판단이 필요합니다."
      echo ""
      _mark_manual "U-12" "세션 종료 시간 — readonly TMOUT 미설정"

    # ── [취약] ──────────────────────────────────────────────────────────────
    else
      _item_header "vuln" "U-12" "(하) 세션 종료 시간 설정"
      echo ""

      # 조치 전 — 공통 설정 현황
      _lbl_before
      echo ""
      _common_out=$(_u12_collect_common)
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
      _bypass_out=$(_u12_collect_bypass)
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
        _mark_skipped "U-12" "세션 종료 시간 [건너뜀]"
        echo ""
      else
        # TMOUT 값 입력
        echo ""
        echo -e " ${YELLOW}세션 종료 시간(초)을 입력하세요. 권고: ${DEFAULT_TMOUT}초 이하${RESET}"
        while true; do
          read -rp " 입력 (Enter=${DEFAULT_TMOUT}): " _tmout_input
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

        # /etc/profile.d/tmout.sh 생성 (기존 TMOUT 설정은 주석 처리)
        _u12_target="/etc/profile.d/tmout.sh"
        for _f in /etc/profile /etc/profile.d/*.sh /etc/bashrc; do
          [ -f "$_f" ] || continue
          grep -v '^\s*#' "$_f" | grep -qE 'TMOUT' || continue
          cp "$_f" "${_f}.bak.$(date +%Y%m%d_%H%M%S)"
          sed -i '/^\s*[^#]*TMOUT/s/^/# [U-12 disabled] /' "$_f"
          _info "기존 TMOUT 주석 처리: $_f"
        done

        cat > "$_u12_target" << TMOUT_EOF
# KISA U-12: 세션 종료 시간 설정
export TMOUT=${TMOUT_VAL}
readonly TMOUT
TMOUT_EOF
        _info "/etc/profile.d/tmout.sh 생성 (export TMOUT=${TMOUT_VAL} / readonly TMOUT)"

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
                sed -i '/^\s*unset\s\+TMOUT/d
                        /^\s*TMOUT\s*=\s*0\([^-9]\|$\)/d
                        /^\s*export\s\+TMOUT\s*=\s*0/d' "$_cur_file" 2>/dev/null
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

        # tmout.sh 내용 확인
        if [ -f "$_u12_target" ]; then
          echo -e "   ${CYAN}${_u12_target}${RESET}"
          grep -v '^\s*#' "$_u12_target" | grep -v '^$' | while IFS= read -r _l; do
            _ok "$_l"
          done
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

do_fix "U-13" "(중) 안전한 비밀번호 암호화 알고리즘 사용" \
  "grep -v '^#' /etc/login.defs 2>/dev/null | grep 'ENCRYPT_METHOD' || echo '미설정'" \
  "grep -q '^\s*ENCRYPT_METHOD' /etc/login.defs \
     && sed -i 's/^\s*ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs \
     || echo 'ENCRYPT_METHOD SHA512' >> /etc/login.defs" \
  "grep -v '^#' /etc/login.defs 2>/dev/null | grep 'ENCRYPT_METHOD'" \
  "SHA512"

# ============================================================
section_header "파일 및 디렉터리 관리"
# ============================================================

do_fix "U-14" "(상) root 홈, 패스 디렉터리 권한 및 패스 설정" \
  "echo \$PATH" \
  "for f in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bash_profile /root/.bashrc /root/.profile; do
     [ -f \"\$f\" ] || continue
     sed -i '/^export PATH=.*\\.:.*\$/d; /^export PATH=\"\\.:.*\"/d' \"\$f\"
     sed -i 's|:\\.:|:|g; s|:\\.\$||; s|^\\.:|:|' \"\$f\"
   done
   export PATH=\$(echo \"\$PATH\" | tr ':' '\n' | grep -v '^\.\$' | paste -sd:)" \
  "VULN=0
   for f in /etc/profile /etc/bashrc /root/.bash_profile /root/.bashrc; do
     [ -f \"\$f\" ] || continue
     grep -v '^#' \"\$f\" | grep -qE '^export PATH=.*\\.' && VULN=1
     grep -v '^#' \"\$f\" | grep -qE 'PATH=.*:\\.:|PATH=\\.' && VULN=1
   done
   echo \":\$PATH:\" | grep -qE ':\\.:' && VULN=1
   [ \"\$VULN\" -eq 0 ] && echo 'PATH 정상 (VERIFY_OK)' || echo 'PATH에 . 잔존'" \
  "VERIFY_OK"

do_fix "U-15" "(상) 파일 및 디렉터리 소유자 설정" \
  "_o=\$(find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '소유자 없는 파일 없음'" \
  "find / -xdev -nouser -ls 2>/dev/null | awk '{print \$NF}' | xargs -r chown root 2>/dev/null
   find / -xdev -nogroup -ls 2>/dev/null | awk '{print \$NF}' | xargs -r chgrp root 2>/dev/null" \
  "find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null | wc -l | xargs echo '소유자 없는 파일 수:'" \
  ""

do_fix "U-16" "(상) /etc/passwd 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/passwd" \
  "chown root:root /etc/passwd && chmod 644 /etc/passwd" \
  "stat -c '소유자: %U / 권한: %a' /etc/passwd" \
  "소유자: root / 권한: 644"

do_fix "U-17" "(상) 시스템 시작 스크립트 권한 설정" \
  "for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] && stat -c \"\$f — %U/%a\" \"\$f\"
   done" \
  "for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] || continue
     [ -L \"\$f\" ] && f=\$(readlink -f \"\$f\")
     chown root:root \"\$f\" && chmod 755 \"\$f\" 2>/dev/null
   done" \
  "for f in /etc/rc.local /etc/init.d /etc/rc.d; do
     [ -e \"\$f\" ] && stat -c \"\$f — %U/%a\" \"\$f\"
   done" \
  ""

do_fix "U-18" "(상) /etc/shadow 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/shadow 2>/dev/null" \
  "chown root:root /etc/shadow && chmod 400 /etc/shadow" \
  "stat -c '소유자: %U / 권한: %a' /etc/shadow 2>/dev/null" \
  "소유자: root / 권한: 4[0-9][0-9]"

do_fix "U-19" "(상) /etc/hosts 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/hosts" \
  "chown root:root /etc/hosts && chmod 644 /etc/hosts" \
  "stat -c '소유자: %U / 권한: %a' /etc/hosts" \
  "소유자: root / 권한: 644"
do_fix "U-20" "(상) /etc/(x)inetd.conf 파일 소유자 및 권한 설정" \
  "_o=\$(for F in /etc/inetd.conf /etc/xinetd.conf; do [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '파일 없음 (양호)'" \
  "for F in /etc/inetd.conf /etc/xinetd.conf; do
     [ -f \"\$F\" ] || continue
     chown root:root \"\$F\" && chmod 600 \"\$F\" && echo \"   \$F → root/600\"
   done" \
  "_o=\$(for F in /etc/inetd.conf /etc/xinetd.conf; do [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '파일 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-21" "(상) /etc/rsyslog.conf 소유자 및 권한" \
  "stat -c '소유자: %U / 권한: %a' /etc/rsyslog.conf 2>/dev/null || echo '파일 없음'" \
  "[ -f /etc/rsyslog.conf ] && chown root:root /etc/rsyslog.conf && chmod 640 /etc/rsyslog.conf" \
  "stat -c '소유자: %U / 권한: %a' /etc/rsyslog.conf 2>/dev/null" \
  "소유자: root / 권한: 640"

do_fix "U-22" "(상) /etc/services 파일 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /etc/services" \
  "chown root:root /etc/services && chmod 644 /etc/services" \
  "stat -c '소유자: %U / 권한: %a' /etc/services" \
  "소유자: root / 권한: 644"

do_fix "U-23" "(상) SUID, SGID, Sticky bit 설정 파일 점검" \
  'ALLOWED="/bin/su /usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh
/usr/bin/newgrp /usr/bin/gpasswd /usr/bin/crontab /bin/ping /usr/bin/pkexec
/usr/bin/chage /usr/bin/fusermount /usr/bin/fusermount3 /usr/bin/mount /usr/bin/umount
/usr/bin/write /usr/bin/at /usr/bin/locate /usr/sbin/lockdev
/usr/sbin/pam_timestamp_check /usr/sbin/unix_chkpwd /usr/sbin/grub2-set-bootflag
/usr/sbin/userhelper /usr/lib/polkit-1/polkit-agent-helper-1
/usr/libexec/utempter/utempter /usr/libexec/Xorg.wrap
/usr/libexec/openssh/ssh-keysign /usr/libexec/dbus-1/dbus-daemon-launch-helper
/usr/libexec/sssd/krb5_child /usr/libexec/sssd/ldap_child
/usr/libexec/sssd/proxy_child /usr/libexec/sssd/selinux_child
/usr/bin/vmware-user-suid-wrapper"
   _allow_lines=""; _remove_lines=""
   while IFS= read -r f; do
     _ls=$(ls -l "$f" 2>/dev/null | awk "{printf \"  %-11s %-8s %-8s %s\n\", \$1, \$3, \$4, \$NF}")
     if echo "$ALLOWED" | tr " " "\n" | grep -qxF "$f"; then
       _allow_lines="${_allow_lines}${_ls}"$'"'"'\n'"'"'
     else
       _remove_lines="${_remove_lines}${_ls}"$'"'"'\n'"'"'
     fi
   done < <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null)

   echo " ✓ 허용 목록"
   echo ""
   if [ -n "$_allow_lines" ]; then
     printf "%s" "$_allow_lines"
   else
     echo "  없음"
   fi
   echo ""
   echo " ✗ 조치 대상"
   echo ""
   if [ -n "$_remove_lines" ]; then
     printf "%s" "$_remove_lines"
   else
     echo "  없음 — 조치 불필요"
   fi
   echo ""' \
  'ALLOWED="/bin/su /usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh
/usr/bin/newgrp /usr/bin/gpasswd /usr/bin/crontab /bin/ping /usr/bin/pkexec
/usr/bin/chage /usr/bin/fusermount /usr/bin/fusermount3 /usr/bin/mount /usr/bin/umount
/usr/bin/write /usr/bin/at /usr/bin/locate /usr/sbin/lockdev
/usr/sbin/pam_timestamp_check /usr/sbin/unix_chkpwd /usr/sbin/grub2-set-bootflag
/usr/sbin/userhelper /usr/lib/polkit-1/polkit-agent-helper-1
/usr/libexec/utempter/utempter /usr/libexec/Xorg.wrap
/usr/libexec/openssh/ssh-keysign /usr/libexec/dbus-1/dbus-daemon-launch-helper
/usr/libexec/sssd/krb5_child /usr/libexec/sssd/ldap_child
/usr/libexec/sssd/proxy_child /usr/libexec/sssd/selinux_child
/usr/bin/vmware-user-suid-wrapper"
   find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while read -r f; do
     if echo "$ALLOWED" | tr " " "\n" | grep -qxF "$f"; then
       : # 허용 목록 — 건드리지 않음
     else
       _before=$(ls -l "$f" 2>/dev/null | awk "{print \$1, \$3, \$4, \$NF}")
       if chmod u-s,g-s "$f" 2>/dev/null; then
         _after=$(ls -l "$f" 2>/dev/null | awk "{print \$1, \$3, \$4, \$NF}")
         printf "   SUID/SGID 제거\n"
         printf "   전: %s\n" "$_before"
         printf "   후: %s\n\n" "$_after"
       else
         echo "   제거 실패: $f"
       fi
     fi
   done' \
  'ALLOWED="/bin/su /usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chfn /usr/bin/chsh
/usr/bin/newgrp /usr/bin/gpasswd /usr/bin/crontab /bin/ping /usr/bin/pkexec
/usr/bin/chage /usr/bin/fusermount /usr/bin/fusermount3 /usr/bin/mount /usr/bin/umount
/usr/bin/write /usr/bin/at /usr/bin/locate /usr/sbin/lockdev
/usr/sbin/pam_timestamp_check /usr/sbin/unix_chkpwd /usr/sbin/grub2-set-bootflag
/usr/sbin/userhelper /usr/lib/polkit-1/polkit-agent-helper-1
/usr/libexec/utempter/utempter /usr/libexec/Xorg.wrap
/usr/libexec/openssh/ssh-keysign /usr/libexec/dbus-1/dbus-daemon-launch-helper
/usr/libexec/sssd/krb5_child /usr/libexec/sssd/ldap_child
/usr/libexec/sssd/proxy_child /usr/libexec/sssd/selinux_child
/usr/bin/vmware-user-suid-wrapper"
   EXTRA=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while read -r f; do
     if ! echo "$ALLOWED" | tr " " "\n" | grep -qxF "$f"; then
       echo "$f"
     fi
   done)
   [ -z "$EXTRA" ] && echo "허용 목록 외 SUID/SGID 없음 (VERIFY_OK)" || echo "잔존: $EXTRA"' \
  "VERIFY_OK"

# ── U-23 기관 추가 강화 정책 (선택적 적용) ────────────────────────────────
{
  # 실제 시스템에서 SUID/SGID 설정된 강화 대상 파일 탐지 (경로 하드코딩 없음)
  _P_FILES=""; _B_FILES=""; _N_FILES=""

  for _bin in lpq lpr lprm; do
    for _p in /usr/bin /bin; do
      _f="${_p}/${_bin}"
      [ -f "$_f" ] && stat -c "%a" "$_f" 2>/dev/null | grep -qE '^[24]' \
        && _P_FILES="${_P_FILES} ${_f}"
    done
  done
  for _bin in lpc; do
    for _p in /usr/sbin /sbin; do
      _f="${_p}/${_bin}"
      [ -f "$_f" ] && stat -c "%a" "$_f" 2>/dev/null | grep -qE '^[24]' \
        && _P_FILES="${_P_FILES} ${_f}"
    done
  done
  for _bin in dump restore; do
    for _p in /sbin /usr/sbin; do
      _f="${_p}/${_bin}"
      [ -f "$_f" ] && stat -c "%a" "$_f" 2>/dev/null | grep -qE '^[24]' \
        && _B_FILES="${_B_FILES} ${_f}"
    done
  done
  for _bin in traceroute traceroute6; do
    for _p in /usr/sbin /sbin /usr/bin /bin; do
      _f="${_p}/${_bin}"
      [ -f "$_f" ] && stat -c "%a" "$_f" 2>/dev/null | grep -qE '^[24]' \
        && _N_FILES="${_N_FILES} ${_f}"
    done
  done

  if [ -z "$_P_FILES" ] && [ -z "$_B_FILES" ] && [ -z "$_N_FILES" ]; then
    : # 탐지된 대상 없음 — 출력 생략
  else
    echo ""
    echo -e "${BOLD} 기관 추가 강화 정책 — SUID/SGID 선택적 제거${RESET}"
    echo ""
    echo " KISA 허용 목록이나 불필요 시 제거를 권고하는 파일입니다."
    echo " 시스템에서 실제 탐지된 항목만 표시됩니다."
    echo ""
    [ -n "$_P_FILES" ] && {
      echo -e " ${YELLOW}[ 프린팅 관련 ]${RESET}  — 프린터 서비스 미운용 환경에서 제거 권고"
      for _f in $_P_FILES; do echo "   $_f"; done
      echo ""
    }
    [ -n "$_B_FILES" ] && {
      echo -e " ${YELLOW}[ 백업/복구 관련 ]${RESET}  — 테이프 백업 미사용 환경에서 제거 권고"
      for _f in $_B_FILES; do echo "   $_f"; done
      echo ""
    }
    [ -n "$_N_FILES" ] && {
      echo -e " ${YELLOW}[ 네트워크 진단 ]${RESET}  — 일반 사용자 실행 불필요 시 제거 권고"
      for _f in $_N_FILES; do echo "   $_f"; done
      echo ""
    }
    echo -e " 위 파일들의 SUID/SGID를 제거하시겠습니까?\n"
    _opts=""
    [ -n "$_P_FILES" ] && _opts="${_opts}[P] 프린팅만  "
    [ -n "$_B_FILES" ] && _opts="${_opts}[B] 백업/복구만  "
    [ -n "$_N_FILES" ] && _opts="${_opts}[N] 네트워크만  "
    echo -e "  ${GREEN}[A]${RESET} 전체 적용   ${_opts}${RED}[S]${RESET} 건너뛰기"
    read -rp " 선택 : " _u23_choice
    echo ""

    _u23_choice=$(echo "$_u23_choice" | tr '[:lower:]' '[:upper:]')
    _do_print=0; _do_backup=0; _do_net=0
    case "$_u23_choice" in
      A) _do_print=1; _do_backup=1; _do_net=1 ;;
      P) _do_print=1 ;;
      B) _do_backup=1 ;;
      N) _do_net=1 ;;
      S|*) echo -e " ${YELLOW}– 기관 강화 정책 건너뜀${RESET}"
           echo "   해당 파일들은 KISA 허용 목록에 포함되어 현재 상태로 유지됩니다."
           echo "   필요 시 fix 스크립트를 재실행하여 적용할 수 있습니다." ;;
    esac

    _u23_count=0
    _apply_suid_remove() {
      local label="$1"; shift
      for _f in "$@"; do
        [ -f "$_f" ] || continue
        _before=$(ls -l "$_f" 2>/dev/null | awk '{print $1, $3, $4, $NF}')
        if chmod u-s,g-s "$_f" 2>/dev/null; then
          _after=$(ls -l "$_f" 2>/dev/null | awk '{print $1, $3, $4, $NF}')
          printf "   전: %s\n" "$_before"
          printf "   후: %s\n\n" "$_after"
        else
          echo -e "   ${RED}!! 제거 실패: $_f${RESET}"
        fi
        _u23_count=$((_u23_count+1))
      done
    }

    [ $_do_print  -eq 1 ] && {
      echo -e " ${CYAN}[적용 중]${RESET} 프린팅 관련 SUID/SGID 제거"
      _apply_suid_remove "프린팅" $_P_FILES
    }
    [ $_do_backup -eq 1 ] && {
      echo -e " ${CYAN}[적용 중]${RESET} 백업/복구 관련 SUID/SGID 제거"
      _apply_suid_remove "백업" $_B_FILES
    }
    [ $_do_net    -eq 1 ] && {
      echo -e " ${CYAN}[적용 중]${RESET} 네트워크 진단 SUID/SGID 제거"
      _apply_suid_remove "네트워크" $_N_FILES
    }

    if [ $_u23_count -gt 0 ]; then
      echo ""
      echo -e " ${CYAN}→${RESET} 기관 강화 정책 적용 완료  총 ${_u23_count}개 파일 처리"
      echo -e "   조치 이력 기록됨 → /var/log/vulnFixHistory.log"
    fi
  fi
}

do_fix "U-24" "(상) 사용자, 시스템 환경변수 파일 소유자 및 권한 설정" \
  "for F in /etc/profile /etc/bashrc /root/.bashrc /root/.bash_profile; do
     [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"
   done" \
  "for F in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc /root/.bash_profile /root/.profile; do
     [ -f \"\$F\" ] && chown root:root \"\$F\" && chmod 644 \"\$F\"
   done" \
  "for F in /etc/profile /etc/bashrc /root/.bashrc /root/.bash_profile; do
     [ -f \"\$F\" ] && stat -c \"\$F — %U/%a\" \"\$F\"
   done" \
  ""


# U-25 World Writable
{
  _match=0
  for _tid in "${TARGET_IDS[@]}"; do [ "$_tid" = "U-25" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-25"; _vs=$?
  _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-25" "(상) world writable 파일 점검"
      _lbl_cur; echo "   의심 world writable 파일 없음 (예외 경로 제외 후)"
      echo ""
      _mark_skipped "U-25" "world writable 파일 점검 [이미양호]"
    else
      _item_header "vuln" "U-25" "(상) world writable 파일 점검"
      echo ""

      # 운영에 흔히 필요한 서비스 소켓 — 무조건 "취약"으로 보지 않고 예외로 분류해서
      # 어떤 서비스가 만들었는지, 지금 그 서비스가 켜져 있는지부터 보여준다.
      _U25_KNOWN_SVC_SOCKETS="gssproxy dbus systemd chronyd sssd docker containerd postfix"

      echo -e " ${YELLOW}예외 디렉터리 (정상)${RESET}"
      for _ed in /tmp /var/tmp; do
        if [ -d "$_ed" ]; then
          _ed_perm=$(stat -c '%a' "$_ed" 2>/dev/null)
          if echo "$_ed_perm" | grep -qE '^1'; then
            _ok "$_ed (${_ed_perm}, Sticky Bit)"
          else
            _fail "$_ed (${_ed_perm} — Sticky Bit 없음, 확인 필요)"
          fi
        fi
      done
      echo ""

      # /tmp, /var/tmp는 "내용물"뿐 아니라 "디렉터리 자체"도 명시적으로 제외해야 한다.
      # 과거에는 -not -path '/tmp/*' 만 써서 /tmp, /var/tmp 디렉터리 자체(1777, 정상)가
      # 조치 대상 목록에 잘못 끼어드는 버그가 있었음.
      _u25_general=$(find / -xdev -perm -0002 -not -type l -not -type s \
        -not -path '/tmp' -not -path '/tmp/*' -not -path '/var/tmp' -not -path '/var/tmp/*' 2>/dev/null)
      _u25_sockets=$(find / -xdev -perm -0002 -type s \
        -not -path '/tmp/*' -not -path '/var/tmp/*' 2>/dev/null)

      _u25_exc_sockets=""; _u25_unknown_sockets=""
      while IFS= read -r _sk; do
        [ -z "$_sk" ] && continue
        _matched_svc=""
        for _svc in $_U25_KNOWN_SVC_SOCKETS; do
          echo "$_sk" | grep -qi "$_svc" && _matched_svc="$_svc" && break
        done
        if [ -n "$_matched_svc" ]; then
          _u25_exc_sockets="${_u25_exc_sockets}${_sk}|${_matched_svc}"$'\n'
        else
          _u25_unknown_sockets="${_u25_unknown_sockets}${_sk}"$'\n'
        fi
      done <<< "$_u25_sockets"

      if [ -n "$_u25_general" ]; then
        echo -e " ${YELLOW}일반 파일 (조치 대상)${RESET}"
        echo "$_u25_general" | sed 's/^/   /'
        echo ""
      fi
      if [ -n "$_u25_exc_sockets" ]; then
        echo -e " ${YELLOW}서비스 Socket 발견${RESET}"
        echo ""

        _u25_svc_list=$(printf '%s
' "$_u25_exc_sockets" | awk -F'|' 'NF>=2 && $2!="" {print $2}' | sort -u)
        while IFS= read -r _svc; do
          [ -z "$_svc" ] && continue
          _svc_status=$(systemctl is-active "$_svc" 2>/dev/null)
          [ -z "$_svc_status" ] && _svc_status="unknown"
          _svc_sockets=$(printf '%s
' "$_u25_exc_sockets" | awk -F'|' -v svc="$_svc" '$2==svc {print $1}')
          _svc_cnt=$(printf '%s
' "$_svc_sockets" | grep -c . 2>/dev/null); _svc_cnt=${_svc_cnt:-0}

          echo -e "   서비스  : ${_svc}"
          if [ "$_svc_status" = "active" ]; then
            echo -e "   상태    : ${GREEN}active (운용 중)${RESET}"
          else
            echo -e "   상태    : ${YELLOW}${_svc_status}${RESET}"
          fi
          echo ""
          echo -e "   ${CYAN}[서비스 Socket]${RESET}"
          echo -e "   Socket  : ${_svc_cnt}개"
          printf '%s
' "$_svc_sockets" | sed 's/^/     - /'
          echo ""
          echo -e "   ${YELLOW}※ 위 파일은 ${_svc} 서비스에서 생성한 UNIX Domain Socket입니다.${RESET}"
          echo -e "     일반 World Writable 파일과는 용도가 다르며,"
          echo -e "     자동 권한 변경 또는 삭제 대상이 아닙니다."
          echo ""
          if [ "$_svc_status" = "active" ]; then
            echo -e "   ${CYAN}[권장 조치]${RESET}"
            echo -e "   - 서비스를 사용하는 경우"
            echo -e "     → 현재 상태를 유지하고 보안 정책에 따라 관리"
          else
            echo -e "   ${CYAN}[권장 조치]${RESET}"
            echo -e "   서비스를 사용하지 않는 경우: ${CYAN}systemctl stop/disable/mask ${_svc}${RESET}"
            echo -e "   서비스를 사용하는 경우    : ${CYAN}/etc/tmpfiles.d/${_svc}-fix.conf 권한 정책 수정${RESET}"
          fi
          echo ""
        done <<< "$_u25_svc_list"
      fi
      if [ -n "$_u25_unknown_sockets" ]; then
        echo -e " ${RED}알 수 없는 Socket 발견  (조치 대상)${RESET}"
        _lbl_subdiv
        while IFS= read -r _sk; do
          [ -z "$_sk" ] && continue
          echo ""
          echo -e "   파일    : ${_sk}"
          echo -e "   종류    : Socket"
          echo -e "   서비스  : ${RED}알 수 없음${RESET}"
          echo -e "   상태    : ${YELLOW}생성 서비스 자동 식별 불가${RESET}"
          echo ""
          echo -e "   ${CYAN}※ 처리 방법${RESET}"
          echo -e "   해당 소켓을 생성한 서비스/프로세스를 확인 후 조치"
          echo -e "   ${CYAN}→${RESET} 확인 명령: lsof ${_sk}  또는  fuser ${_sk}"
          _lbl_subdiv
        done <<< "$_u25_unknown_sockets"
        echo ""
      fi
      if [ -z "$_u25_general" ] && [ -z "$_u25_exc_sockets" ] && [ -z "$_u25_unknown_sockets" ]; then
        echo "   (조치 대상 없음)"
        echo ""
      fi

      _lbl_yn
      _read_yn _yn25 " 조치하시겠습니까? (y/n): "
      case "$_yn25" in
        [Yy])
          _lbl_during
          echo -e "   ${CYAN}→${RESET} world writable 파일 권한(o-w) 제거 적용"
          [ -n "$_u25_general" ] && echo "$_u25_general" | xargs -r chmod o-w
          [ -n "$_u25_unknown_sockets" ] && echo "$_u25_unknown_sockets" | xargs -r chmod o-w

          _u25_pending_list=""
          if [ -n "$_u25_exc_sockets" ]; then
            # 서비스 Socket은 파일별로 묻지 않고 서비스 단위로 1회만 처리한다.
            # 같은 서비스(postfix 등)가 여러 Socket을 생성하는 경우 파일마다 반복 질문하면
            # 사용자가 같은 서비스를 계속 조치하는 것처럼 보이므로 신뢰도가 떨어진다.
            _u25_svc_list=$(printf '%s\n' "$_u25_exc_sockets" | awk -F'|' 'NF>=2 && $2!="" {print $2}' | sort -u)
            while IFS= read -r _svc <&3; do
              [ -z "$_svc" ] && continue
              _svc_status=$(systemctl is-active "$_svc" 2>/dev/null)
              [ -z "$_svc_status" ] && _svc_status="unknown"
              _svc_sockets=$(printf '%s\n' "$_u25_exc_sockets" | awk -F'|' -v svc="$_svc" '$2==svc {print $1}')
              _svc_cnt=$(printf '%s\n' "$_svc_sockets" | grep -c . 2>/dev/null); _svc_cnt=${_svc_cnt:-0}

              echo ""
              echo -e " ${YELLOW}[서비스 Socket] ${_svc}${RESET}"
              echo -e "   상태   : ${_svc_status}"
              echo -e "   Socket : ${_svc_cnt}개"
              printf '%s\n' "$_svc_sockets" | sed 's/^/     - /'
              echo ""
              echo -e "   ${CYAN}→ 서비스 불필요${RESET}  : y  (서비스 중지 + disable + mask)"
              echo -e "   ${CYAN}→ 서비스 사용 중${RESET} : n  (서비스 유지, tmpfiles.d 권한 정책 등록)"
              _read_yn _svc_yn " ${_svc} 서비스를 사용하지 않아 중지/마스킹하시겠습니까? (y/n): "
              case "$_svc_yn" in
                [Yy])
                      systemctl stop "$_svc" 2>/dev/null
                      systemctl disable "$_svc" 2>/dev/null
                      systemctl mask "$_svc" 2>/dev/null
                      while IFS= read -r _sk; do
                        [ -z "$_sk" ] && continue
                        # 중지된 서비스의 잔존 소켓도 o-w 제거 — 파일이 정리되기 전까지
                        # world writable 상태로 남아 재점검 시 다시 취약으로 잡히는 것 방지
                        chmod o-w "$_sk" 2>/dev/null
                        _u25_pending_list="${_u25_pending_list}${_sk}"$'\n'
                      done <<< "$_svc_sockets"
                      echo -e " ${GREEN}→ ${_svc} 서비스 중지 및 마스킹 완료 (Socket ${_svc_cnt}개, o-w 적용)${RESET}" ;;
                *)
                      # 소유자/그룹은 보존(- -)하고, 현재 권한에서 other-write 비트만
                      # 제거한 모드를 적용한다. (기존 "0600 root root" 고정은 postfix처럼
                      # 서비스 계정 소유 소켓의 소유권을 root로 바꿔 서비스를 깨뜨렸음)
                      {
                        while IFS= read -r _sk; do
                          [ -z "$_sk" ] && continue
                          _cur_mode=$(stat -c '%a' "$_sk" 2>/dev/null)
                          [ -z "$_cur_mode" ] && continue
                          _new_mode=$(printf '%03o' $(( 0${_cur_mode} & ~02 )))
                          echo "z ${_sk} ${_new_mode} - - -"
                        done <<< "$_svc_sockets"
                      } > "/etc/tmpfiles.d/${_svc}-fix.conf"
                      systemd-tmpfiles --create "/etc/tmpfiles.d/${_svc}-fix.conf" 2>/dev/null
                      # 핵심: tmpfiles.d 규칙은 "부팅 시"에만 자동 적용된다. postfix 등
                      # 활성 서비스가 재시작되면 소켓을 새로 만들면서 자체 기본 권한(대개
                      # world-writable)으로 되돌아가고, 다음 재부팅 전까지는 아무도 이
                      # tmpfiles 규칙을 다시 실행해주지 않아 재점검 시 다시 취약으로 뜬다.
                      # → 서비스가 시작될 때마다 tmpfiles 규칙을 재적용하도록 drop-in을 심는다.
                      _svc_unit=$(systemctl list-units --type=service --all --no-legend 2>/dev/null \
                        | awk -v s="$_svc" '$1 ~ ("^"s"(@|\\.service)")' | awk '{print $1}' | head -1)
                      [ -z "$_svc_unit" ] && _svc_unit="${_svc}.service"
                      _svc_dropin_dir="/etc/systemd/system/${_svc_unit}.d"
                      mkdir -p "$_svc_dropin_dir" 2>/dev/null
                      cat > "${_svc_dropin_dir}/99-vulnfix-u25-tmpfiles.conf" << DROPIN_EOF
[Service]
ExecStartPost=-/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/${_svc}-fix.conf
DROPIN_EOF
                      systemctl daemon-reload 2>/dev/null
                      echo -e " ${GREEN}→ tmpfiles.d 권한 정책 등록 완료 (${_svc} Socket ${_svc_cnt}개, o-w 적용·소유권 보존)${RESET}"
                      echo -e " ${CYAN}→ ${_svc_unit} 재시작 시에도 자동 재적용되도록 drop-in 등록 (${_svc_dropin_dir})${RESET}" ;;
              esac
            done 3<<< "$_u25_svc_list"
          fi

          echo ""
          _lbl_result
          _u25_remain_general=$(find / -xdev -perm -0002 -not -type l -not -type s \
            -not -path '/tmp' -not -path '/tmp/*' -not -path '/var/tmp' -not -path '/var/tmp/*' 2>/dev/null)
          _u25_remain_sockets=$(find / -xdev -perm -0002 -type s \
            -not -path '/tmp/*' -not -path '/var/tmp/*' 2>/dev/null)
          # 서비스 중지를 선택한 소켓은 "서비스 중지/재부팅 시 정리될 수 있음" 예외로 별도 표기
          # (가독성 — "재부팅하면 무조건 사라진다"는 단정적 표현은 서비스마다 다를 수 있어 지양)
          _u25_pending_cnt=0
          if [ -n "$_u25_pending_list" ]; then
            while IFS= read -r _pk; do
              [ -z "$_pk" ] && continue
              _u25_remain_sockets=$(echo "$_u25_remain_sockets" | grep -vxF "$_pk")
              _u25_pending_cnt=$((_u25_pending_cnt+1))
            done <<< "$_u25_pending_list"
          fi
          _u25_gen_cnt=$(echo "$_u25_remain_general" | grep -c . 2>/dev/null); _u25_gen_cnt=${_u25_gen_cnt:-0}
          _u25_sock_cnt=$(echo "$_u25_remain_sockets" | grep -c . 2>/dev/null); _u25_sock_cnt=${_u25_sock_cnt:-0}
          if [ "$_u25_gen_cnt" -eq 0 ]; then
            _ok "World Writable 일반 파일: 0개"
          else
            _fail "World Writable 일반 파일: ${_u25_gen_cnt}개"
            echo "$_u25_remain_general" | head -5 | sed 's/^/      /'
          fi
          if [ "$_u25_sock_cnt" -gt 0 ]; then
            _warn "Socket 파일: ${_u25_sock_cnt}개 (확인 필요)"
            echo "$_u25_remain_sockets" | head -5 | sed 's/^/      /'
          fi
          [ "$_u25_pending_cnt" -gt 0 ] && echo -e "   ${YELLOW}※ 서비스 중지/마스킹 처리한 소켓 ${_u25_pending_cnt}개는 서비스 중지 또는 재부팅 시${RESET}" && echo -e "   ${YELLOW}  자동으로 제거되거나 다시 생성될 수 있습니다 (서비스마다 다름).${RESET}"

          REMAIN=$((_u25_gen_cnt + _u25_sock_cnt))
          BEFORE_VAL["U-25"]="world writable 파일 존재"
          AFTER_VAL["U-25"]="world writable 제거 완료 (일반 잔존: ${_u25_gen_cnt}개)"
          _mark_fixed "U-25" "world writable 조치 (일반잔존 ${_u25_gen_cnt}개, 소켓잔존 ${_u25_sock_cnt}개, 처리대기 ${_u25_pending_cnt}개)" ;;
        *)
          _lbl_skip
          _mark_skipped "U-25" "world writable 파일 점검 [건너뜀]" ;;
      esac
    fi
    echo ""
  fi
}

do_fix "U-26" "(상) /dev에 존재하지 않는 device 파일 점검" \
  "_o=\$(find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '비장치 파일 없음'" \
  "find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | xargs -r rm -f" \
  "find /dev -not -type d -not -type c -not -type b -not -type l -not -type p -not -type s 2>/dev/null | grep -v '\.udev' | wc -l | xargs echo '잔존 비장치 파일:'" \
  ""

do_fix "U-27" "(상) $HOME/.rhosts, hosts.equiv 사용 금지" \
  "[ -f /etc/hosts.equiv ] && echo '/etc/hosts.equiv 존재'
   _o=\$(find /root /home -name '.rhosts' 2>/dev/null | head -3); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '.rhosts 파일 없음'" \
  "rm -f /etc/hosts.equiv 2>/dev/null
   find /root /home -name '.rhosts' 2>/dev/null | xargs -r rm -f" \
  "[ -f /etc/hosts.equiv ] && echo '제거 실패' || echo '/etc/hosts.equiv 없음 (VERIFY_OK)'
   find /root /home -name '.rhosts' 2>/dev/null | wc -l | xargs echo '.rhosts 잔존:'" \
  "VERIFY_OK"

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
      _lbl_before
      echo "   firewalld: $(systemctl is-active firewalld 2>/dev/null)"
      _u28_ipt=$(iptables -L -n 2>/dev/null | grep -v '^Chain\|^target\|^$' | grep -c '.')
      _u28_ipt=${_u28_ipt:-0}
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

        # ── SSH 포트 실제 감지 ────────────────────────────────────────────
        # sshd -T로 "실제 적용된" 포트를 읽는다 (sshd_config만 보면 다중 Port
        # 지시자나 Include로 실제와 다를 수 있음). 이 값을 못 얻으면 22로
        # 폴백하되, 하드코딩된 22만 열고 DROP을 걸면 SSH를 다른 포트로 운영
        # 중인 서버에서는 관리자 자신의 접속까지 차단해버리는 락아웃 사고로
        # 이어질 수 있으므로 반드시 실제 포트를 먼저 확인한다.
        _u28_ssh_ports=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | sort -u)
        [ -z "$_u28_ssh_ports" ] && _u28_ssh_ports="22"
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

do_fix "U-29" "(하) hosts.lpd 파일 소유자 및 권한 설정" \
  "[ -f /etc/hosts.lpd ] && stat -c '소유자: %U / 권한: %a' /etc/hosts.lpd || echo '파일 없음 (양호)'" \
  "[ -f /etc/hosts.lpd ] && chown root:root /etc/hosts.lpd && chmod 600 /etc/hosts.lpd" \
  "[ -f /etc/hosts.lpd ] && stat -c '소유자: %U / 권한: %a' /etc/hosts.lpd || echo '파일 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-30" "(중) UMASK 설정 관리" \
  '# 조치 전: 설정 파일 기준 현재 umask 표시 (세션값 아님)
   _o=$(for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/login.defs /etc/profile.d/*.sh; do
     [ -f "$F" ] || continue
     V=$(grep -v "^#" "$F" | grep -oE "\bumask[[:space:]]+[0-9]+" | head -1)
     [ -n "$V" ] && echo "  $F: $V"
   done); [ -n "$_o" ] && echo "$_o" || echo "  설정 없음"' \
  '# 1) 모든 설정 파일에서 취약 umask 제거
   for F in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/profile.d/*.sh; do
     [ -f "$F" ] || continue
     grep -qE "^\s*umask\s+[0-9]" "$F" 2>/dev/null || continue
     sed -i "/^\s*umask\s\+0*(022|027)\b/! { /^\s*umask\s\+[0-9]/d }" "$F" 2>/dev/null && \
       echo "   취약 umask 제거: $F"
   done
   # 2) login.defs UMASK 수정
   if [ -f /etc/login.defs ]; then
     UM_LD=$(grep -v "^#" /etc/login.defs | grep -iE "^\s*UMASK\s+" | awk "{print \$2}" | tail -1)
     if [ -n "$UM_LD" ] && [ "$UM_LD" != "022" ] && [ "$UM_LD" != "0022" ] && \
        [ "$UM_LD" != "027" ] && [ "$UM_LD" != "0027" ]; then
       sed -i "s/^\s*UMASK\s.*/UMASK\t022/" /etc/login.defs && echo "   login.defs UMASK → 022"
     fi
   fi
   # 3) /etc/profile에 안전한 umask 없으면 추가
   if ! grep -qE "^\s*umask\s+0*(022|027)\b" /etc/profile 2>/dev/null; then
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
   grep -qE "^\s*umask\s+0*(022|027)\b" /etc/profile && echo "umask 022 설정 확인 (VERIFY_OK)" || echo "설정 미확인"' \
  "VERIFY_OK"

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
     O=\$(stat -c '%U' \"\$homedir\"); P=\$(stat -c '%a' \"\$homedir\")
     [ \"\$O\" != \"\$user\" ] && chown \"\$user\" \"\$homedir\"
     [ \"\$P\" -gt 755 ] 2>/dev/null && chmod 750 \"\$homedir\"
   done < /etc/passwd" \
  "while IFS=: read -r user _ uid _ _ homedir _; do
     [ \"\$uid\" -lt 1000 ] 2>/dev/null && continue
     [ -d \"\$homedir\" ] || continue
     stat -c \"\$homedir — %U/%a\" \"\$homedir\"
   done < /etc/passwd" \
  ""

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
section_header "서비스 관리"
# ============================================================

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

# U-39 NFS (업무 여부 확인 필요)
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
                  echo "$(date '+%Y-%m-%d %H:%M:%S')|${_dep_id}|U-39에서 NFS 비활성화로 불필요|NA" >> "$FIX_HISTORY_FILE" 2>/dev/null
                  NA=$((NA+1)); NA_LIST+=("${_dep_id}: ${_dep_name} [NFS 비활성화로 불필요]")
                  break
                fi
              done
            done
          else
            _NFS_DISABLED=0
            echo ""
            echo -e " ${YELLOW}※ 커널/export 잔존이 있어 U-35, U-40은 자동으로 해당없음 처리하지 않고 그대로 점검합니다.${RESET}"
          fi ;;
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
            _mark_skipped "U-35" "공유 서비스 익명 접근 제한 [이미양호]"
    else
      _item_header "vuln" "U-35" "(상) 공유 서비스에 대한 익명 접근 제한 설정"
      echo ""
      _lbl_before
      echo "   [FTP 기본계정]"
      _u35_ftpacc_found=0
      for _acc in ftp anonymous; do
        if grep -q "^${_acc}:" /etc/passwd 2>/dev/null; then
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
          if grep -qi '^\s*anonymous_enable' "$_cf"; then
            sed -i 's/^\s*anonymous_enable.*/anonymous_enable=NO/I' "$_cf"
          else
            echo 'anonymous_enable=NO' >> "$_cf"
          fi
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
            read -rp " 선택: " _u35_nfs_choice

            _do_ip_restrict=0; _do_root_squash=0
            case "$_u35_nfs_choice" in
              1) [ -n "$ANON_LINE" ] && _do_ip_restrict=1 ;;
              2) [ -n "$NOSQ_LINES" ] && _do_root_squash=1 ;;
              3) [ -n "$ANON_LINE" ] && _do_ip_restrict=1; [ -n "$NOSQ_LINES" ] && _do_root_squash=1 ;;
              *) echo -e " ${YELLOW}→ NFS exports 조치를 건너뜁니다.${RESET}"
                 _mark_manual "U-35" "NFS exports 위험요소(전체허용/no_root_squash) — 건너뜀" ;;
            esac

            if [ "$_do_root_squash" -eq 1 ]; then
              cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
              sed -i 's/,no_root_squash//g; s/no_root_squash,//g; s/no_root_squash//g' /etc/exports
              exportfs -ra 2>/dev/null
              echo -e " ${GREEN}→ no_root_squash 제거 완료 (root_squash 적용)${RESET}"
            fi
          fi
          if [ -n "$ANON_LINE" ] && [ "${_do_ip_restrict:-0}" -eq 1 ]; then
            echo ""
            echo -e " ${YELLOW}[NFS] 현재 익명 접근(*) 설정이 발견되었습니다:${RESET}"
            echo "   ${ANON_LINE}"
            echo -e " ${YELLOW}허용할 신뢰 IP 또는 대역(CIDR)을 입력하세요.${RESET}"
            echo "   예: 192.168.10.50  또는  192.168.10.0/24"
            echo "   입력 없이 Enter = 조치 건너뜀(수동확인) / s = 외부 신뢰 IP 없음(로컬호스트로 차단)"
            read -rp " 신뢰 IP/대역 입력: " _nfs_ip

            _IP_RE='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(/([0-9]|[12][0-9]|3[0-2]))?$'

            if [ -z "$_nfs_ip" ]; then
              # 입력 없음 → 추측하지 않고 수동확인으로 전환 (조치 보류)
              echo -e " ${YELLOW}→ 입력이 없어 NFS 조치를 건너뜁니다. 신뢰 대역 확인 후 재실행하세요.${RESET}"
              _mark_manual "U-35" "NFS exports 익명 접근(*) — 신뢰 IP/대역 미입력으로 보류"

            elif [ "$_nfs_ip" = "s" ] || [ "$_nfs_ip" = "S" ]; then
              # 명시적으로 "신뢰 IP 없음" → 로컬호스트로 강하게 제한(사실상 외부 비공개)
              cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
              sed -i 's/\*(rw/127.0.0.1(rw/g; s/\*(ro/127.0.0.1(ro/g' /etc/exports
              exportfs -ra 2>/dev/null
              echo -e " ${GREEN}→ 외부 신뢰 IP 없음으로 확인 — 127.0.0.1(로컬호스트)로 제한 완료${RESET}"
              echo -e " ${YELLOW}   ※ 외부 공유가 필요 없다면 NFS 서비스 자체 중지를 권장합니다 (U-39 참고)${RESET}"

            elif [ "$_nfs_ip" = "0.0.0.0/0" ]; then
              # 형식은 유효하나 전체 허용 — 익명 접근 제한 의미 무력화, 경고 후 수동확인
              echo -e " ${RED}!! 0.0.0.0/0은 전체 IP 허용으로, 익명 접근 제한과 동일한 효과입니다.${RESET}"
              echo -e " ${YELLOW}   적용하지 않고 수동확인으로 전환합니다.${RESET}"
              _mark_manual "U-35" "NFS exports — 0.0.0.0/0 입력으로 제한 의미 없음, 재검토 필요"

            elif echo "$_nfs_ip" | grep -qE "$_IP_RE"; then
              # 정상 형식 → 입력값으로 치환
              cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
              sed -i "s#\*(rw#${_nfs_ip}(rw#g; s#\*(ro#${_nfs_ip}(ro#g" /etc/exports
              exportfs -ra 2>/dev/null
              echo -e " ${GREEN}→ NFS exports 익명 접근(*) → ${_nfs_ip} 로 제한 완료${RESET}"

            else
              # 형식 오류 → 재입력 1회 시도
              echo -e " ${YELLOW}잘못된 형식입니다. 다시 입력하세요 (예: 192.168.10.0/24):${RESET}"
              read -rp " 신뢰 IP/대역 재입력: " _nfs_ip2
              if [ "$_nfs_ip2" = "0.0.0.0/0" ]; then
                echo -e " ${RED}!! 0.0.0.0/0은 전체 IP 허용으로, 익명 접근 제한과 동일한 효과입니다.${RESET}"
                _mark_manual "U-35" "NFS exports — 0.0.0.0/0 재입력으로 제한 의미 없음, 재검토 필요"
              elif echo "$_nfs_ip2" | grep -qE "$_IP_RE"; then
                cp /etc/exports /etc/exports.bak.$(date +%Y%m%d_%H%M%S)
                sed -i "s#\*(rw#${_nfs_ip2}(rw#g; s#\*(ro#${_nfs_ip2}(ro#g" /etc/exports
                exportfs -ra 2>/dev/null
                echo -e " ${GREEN}→ NFS exports 익명 접근(*) → ${_nfs_ip2} 로 제한 완료${RESET}"
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

{
  _match=0
  for tid in "${TARGET_IDS[@]}"; do [ "$tid" = "U-37" ] && _match=1 && break; done
  if [ $_match -eq 1 ]; then
    check_still_vuln "U-37"; _vs=$?
    _flush_header
    if [ $_vs -eq 1 ]; then
      _item_header "good" "U-37" "(상) crontab 설정파일 권한 설정 미흡"
      _lbl_cur
      _u37_bin=$(command -v crontab 2>/dev/null || echo "/usr/bin/crontab")
      ls -l "$_u37_bin" 2>/dev/null | sed 's/^/   /'
      ls -ld /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/crontab 2>/dev/null \
        | awk '{print $1,$3,$4,$NF}' | sed 's/^/   /'
      echo ""
            _mark_skipped "U-37" "crontab 권한 [이미양호]"
    else
      _item_header "vuln" "U-37" "(상) crontab 설정파일 권한 설정 미흡"
      echo ""
      _lbl_before
      _u37_crontab_bin=$(which crontab 2>/dev/null || echo "/usr/bin/crontab")
      [ -f "$_u37_crontab_bin" ] && stat -c "   ${_u37_crontab_bin} : %U / %a" "$_u37_crontab_bin"
      for F in /etc/crontab /etc/cron.deny /etc/cron.allow; do
        if [ -f "$F" ]; then stat -c "   $F : %U / %a" "$F"; else echo "   $F : 없음"; fi
      done
      for D in /etc/cron.d /var/spool/cron; do
        if [ -d "$D" ]; then stat -c "   $D : %U / %a" "$D"; else echo "   $D : 없음"; fi
      done
      echo ""
      _lbl_yn
      _read_yn _yn_u37 " 조치하시겠습니까? (y/n): "
      if [[ "$_yn_u37" != [Yy] ]]; then
        _lbl_skip
                _mark_skipped "U-37" "crontab 권한 [건너뜀]"
      else
        _lbl_during
        # crontab 바이너리 — 판정 기준에 포함되므로 반드시 함께 조치한다.
        # SUID는 일반 사용자 crontab 동작에 필요하므로 유지하고 other 권한만 제거
        # (4755 → 4750). chown은 소유자만 변경해 Debian의 root:crontab 그룹 구성을 보존.
        _u37_bin=$(command -v crontab 2>/dev/null || echo "/usr/bin/crontab")
        if [ -f "$_u37_bin" ]; then
          chown root "$_u37_bin" 2>/dev/null
          chmod o-rwx "$_u37_bin" 2>/dev/null
          echo "   ${_u37_bin} → root / $(stat -c '%a' "$_u37_bin" 2>/dev/null) (other 권한 제거)"
        fi
        [ -f /etc/crontab ]    && chown root:root /etc/crontab    && chmod 640 /etc/crontab    && echo "   /etc/crontab    → root / 640"
        [ -f /etc/cron.deny ]  && chown root:root /etc/cron.deny  && chmod 640 /etc/cron.deny   && echo "   /etc/cron.deny  → root / 640"
        [ -f /etc/cron.allow ] && chown root:root /etc/cron.allow && chmod 640 /etc/cron.allow  && echo "   /etc/cron.allow → root / 640"
        [ -d /etc/cron.d ]     && chown root:root /etc/cron.d     && chmod 750 /etc/cron.d      && echo "   /etc/cron.d     → root / 750"
        [ -d /var/spool/cron ] && chown root:root /var/spool/cron && chmod 750 /var/spool/cron  && echo "   /var/spool/cron → root / 750"
        # Debian 계열 사용자 crontab 디렉터리 — root:crontab 그룹 구성과 sticky 비트를
        # 보존해야 사용자 crontab이 계속 동작하므로 other 권한만 제거한다.
        [ -d /var/spool/cron/crontabs ] && chown root /var/spool/cron/crontabs && chmod o-rwx /var/spool/cron/crontabs \
          && echo "   /var/spool/cron/crontabs → root / $(stat -c '%a' /var/spool/cron/crontabs 2>/dev/null) (other 권한 제거)"
        echo ""
        _lbl_result
        for F in /etc/crontab /etc/cron.deny /etc/cron.allow; do
          if [ -f "$F" ]; then
            _u37_o=$(stat -c '%U' "$F"); _u37_p=$(stat -c '%a' "$F")
            if [ "$_u37_o" = "root" ] && [ "$_u37_p" -le 640 ] 2>/dev/null; then
              _ok "$F : ${_u37_o} / ${_u37_p}"
            else
              _fail "$F : ${_u37_o} / ${_u37_p} (기대: root / 640 이하)"
            fi
          fi
        done
        for D in /etc/cron.d /var/spool/cron; do
          if [ -d "$D" ]; then
            _u37_o=$(stat -c '%U' "$D"); _u37_p=$(stat -c '%a' "$D")
            if [ "$_u37_o" = "root" ] && [ "$_u37_p" -le 750 ] 2>/dev/null; then
              _ok "$D : ${_u37_o} / ${_u37_p}"
            else
              _fail "$D : ${_u37_o} / ${_u37_p} (기대: root / 750 이하)"
            fi
          fi
        done
        if [ -f "$_u37_crontab_bin" ]; then
          _u37_bo=$(stat -c '%U' "$_u37_crontab_bin"); _u37_bp=$(stat -c '%a' "$_u37_crontab_bin")
          # 판정과 동일하게 SUID/SGID 제거 후 750 이하 여부로 평가
          _u37_bpure=$(printf '%o' "$((8#${_u37_bp} & ~8#6000))" 2>/dev/null)
          if [ "$_u37_bo" = "root" ] && [ "$((8#${_u37_bpure:-777}))" -le "$((8#750))" ] 2>/dev/null; then
            _ok "${_u37_crontab_bin} : ${_u37_bo} / ${_u37_bp}"
          else
            _fail "${_u37_crontab_bin} : ${_u37_bo} / ${_u37_bp} (기대: root / other 권한 없음)"
          fi
        fi
        echo ""
        check_still_vuln "U-37"; _u37_rc=$?
        BEFORE_VAL["U-37"]="crontab 설정파일 권한 미흡"
        if [ $_u37_rc -eq 1 ]; then
          AFTER_VAL["U-37"]="crontab 권한 조치 완료"
          _lbl_done_nr
          _mark_fixed "U-37" "(상) crontab 설정파일 권한 설정 미흡 — 조치 완료"
        else
          AFTER_VAL["U-37"]="조치 실패 또는 crontab 바이너리 권한 문제"
          echo -e " ${RED}→ 조치 후에도 여전히 취약 — crontab 바이너리 권한을 확인하세요 (패키지 재설치 등)${RESET}"
          _mark_failed "U-37" "조치 후에도 여전히 취약 (바이너리 권한 가능성)"
        fi
      fi
    fi
    echo ""
  fi
}

do_fix "U-38" "(상) DoS 취약 서비스 비활성화" \
  "_o=\$(for port in 7 9 13 19; do ss -tlnp 2>/dev/null | grep \":\${port} \" && echo \"TCP/\${port} 활성\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'DoS 취약 서비스 비활성 (양호)'" \
  "for svc in echo chargen discard daytime; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
   done" \
  "_o=\$(for port in 7 9 13 19; do ss -tlnp 2>/dev/null | grep \":\${port} \" || true; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'DoS 취약 서비스 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

[ "${_NFS_DISABLED:-0}" -eq 0 ] && \
do_fix "U-40" "(상) NFS 접근 통제" \
  "grep 'no_root_squash' /etc/exports 2>/dev/null || echo 'no_root_squash 없음 (양호)'" \
  "[ -f /etc/exports ] && sed -i 's/,no_root_squash//g; s/no_root_squash,//g; s/no_root_squash//g' /etc/exports && exportfs -ra 2>/dev/null" \
  "grep 'no_root_squash' /etc/exports 2>/dev/null || echo 'no_root_squash 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-41" "(상) 불필요한 automountd 제거" \
  "systemctl is-active autofs 2>/dev/null || echo 'autofs 비활성'" \
  "systemctl stop autofs 2>/dev/null; systemctl disable autofs 2>/dev/null; systemctl mask autofs 2>/dev/null" \
  "systemctl is-active autofs 2>/dev/null || echo 'autofs 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-42" "(상) 불필요한 RPC 서비스 비활성화" \
  "_o=\$(for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do pgrep -x \$svc &>/dev/null && echo \"\$svc 실행 중\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'RPC 취약 서비스 비활성 (양호)'" \
  "for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
     pkill -x \$svc 2>/dev/null
   done" \
  "_o=\$(for svc in cmsd ttdbserverd sadmind rusersd walld sprayd rstatd; do pgrep -x \$svc &>/dev/null && echo \"\$svc 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'RPC 취약 서비스 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-43" "(상) NIS, NIS+ 점검" \
  "_o=\$(for p in ypserv ypbind; do pgrep -x \$p &>/dev/null && echo \"\$p 실행 중\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'NIS 비활성 (양호)'" \
  "for svc in ypserv ypbind; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
     pkill -x \$svc 2>/dev/null
   done" \
  "_o=\$(for p in ypserv ypbind; do pgrep -x \$p &>/dev/null && echo \"\$p 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'NIS 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-44" "(상) tftp, talk 서비스 비활성화" \
  "ss -ulnp 2>/dev/null | grep -E ':69 |:517 |:518 ' || echo 'tftp/talk 비활성 (양호)'" \
  "for svc in tftp tftpd atftpd talk ntalk; do
     systemctl stop \$svc 2>/dev/null; systemctl disable \$svc 2>/dev/null
   done" \
  "ss -ulnp 2>/dev/null | grep -E ':69 |:517 |:518 ' || echo 'tftp/talk 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-45" "(상) 메일 서비스 버전 점검" \
  "postconf -d mail_version 2>/dev/null || echo '메일 서비스 정보 없음'" \
  "# 버전 최신화 — 패키지 업데이트로 처리
   command -v yum &>/dev/null && yum update -y postfix 2>/dev/null
   command -v apt &>/dev/null && apt-get install --only-upgrade postfix -y 2>/dev/null" \
  "postconf -d mail_version 2>/dev/null || echo '메일 서비스 없음'" \
  ""

do_fix "U-46" "(상) 일반 사용자의 메일 서비스 실행 방지" \
  "stat -c '소유자: %U / 권한: %a' /etc/postfix/main.cf 2>/dev/null || echo '파일 없음'" \
  "[ -f /etc/postfix/main.cf ] && chown root:root /etc/postfix/main.cf && chmod 644 /etc/postfix/main.cf" \
  "stat -c '소유자: %U / 권한: %a' /etc/postfix/main.cf 2>/dev/null || echo '파일 없음 (VERIFY_OK)'" \
  "소유자: root / 권한: 644|VERIFY_OK"

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

do_fix "U-48" "(중) expn, vrfy 명령어 제한" \
  "postconf disable_vrfy_command 2>/dev/null || echo 'postfix 없음'" \
  "command -v postconf &>/dev/null && postconf -e 'disable_vrfy_command = yes' && systemctl restart postfix 2>/dev/null" \
  "postconf disable_vrfy_command 2>/dev/null || echo 'postfix 없음 (VERIFY_OK)'" \
  "disable_vrfy_command = yes|VERIFY_OK"

do_fix "U-49" "(상) DNS 보안 버전 패치" \
  "_o=\$(named -v 2>&1 | head -1 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named 비활성'" \
  "command -v yum &>/dev/null && yum update -y bind 2>/dev/null
   command -v apt &>/dev/null && apt-get install --only-upgrade bind9 -y 2>/dev/null" \
  "_o=\$(named -v 2>&1 | head -1 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named 없음'" \
  ""

do_fix "U-50" "(상) DNS Zone Transfer 설정" \
  "_o=\$(grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-transfer' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named.conf 없음'" \
  "[ -f /etc/named.conf ] && grep -q 'allow-transfer' /etc/named.conf \
     && sed -i 's/allow-transfer\s*{[^}]*}/allow-transfer { none; }/' /etc/named.conf \
     || ([ -f /etc/named.conf ] && echo 'options { allow-transfer { none; }; }' >> /etc/named.conf)
   systemctl reload named 2>/dev/null" \
  "grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-transfer' || echo 'named.conf 없음 (VERIFY_OK)'" \
  "none|VERIFY_OK"

do_fix "U-51" "(중) DNS 서비스의 취약한 동적 업데이트 설정 금지" \
  "_o=\$(grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-update' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'named.conf 없음'" \
  "[ -f /etc/named.conf ] && grep -q 'allow-update' /etc/named.conf \
     && sed -i 's/allow-update\s*{[^}]*}/allow-update { none; }/' /etc/named.conf
   systemctl reload named 2>/dev/null" \
  "grep -v '//' /etc/named.conf 2>/dev/null | grep 'allow-update' || echo 'named.conf 없음 (VERIFY_OK)'" \
  "none|VERIFY_OK"

do_fix "U-52" "(중) Telnet 서비스 비활성화" \
  "ss -tlnp 2>/dev/null | grep ':23 ' || echo 'Telnet 비활성 (양호)'" \
  "systemctl stop telnet.socket 2>/dev/null; systemctl disable telnet.socket 2>/dev/null
   systemctl stop telnetd 2>/dev/null; systemctl disable telnetd 2>/dev/null" \
  "ss -tlnp 2>/dev/null | grep ':23 ' || echo 'Telnet 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-53" "(하) FTP 서비스 정보 노출 제한" \
  "_o=\$(grep -i 'ftpd_banner\|ServerIdent' \
       /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
       /etc/proftpd.conf /etc/proftpd/proftpd.conf 2>/dev/null \
       | grep -v '^#' | head -4 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'FTP 설정 없음'" \
  "# vsftpd: 배너에서 버전/제품명 제거
   for F in /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf; do
     [ -f \"\$F\" ] || continue
     grep -q 'ftpd_banner' \"\$F\" \
       && sed -i 's/^[[:space:]]*ftpd_banner.*/ftpd_banner=Welcome/' \"\$F\" \
       || echo 'ftpd_banner=Welcome' >> \"\$F\"
     echo \"   ftpd_banner=Welcome 설정: \$F\"
   done
   # proftpd: ServerIdent off 로 버전 정보 노출 차단
   for F in /etc/proftpd.conf /etc/proftpd/proftpd.conf; do
     [ -f \"\$F\" ] || continue
     cp \"\$F\" \"\${F}.bak.\$(date +%Y%m%d_%H%M%S)\"
     if grep -q 'ServerIdent' \"\$F\"; then
       sed -i 's/^[[:space:]]*ServerIdent.*/ServerIdent off/' \"\$F\"
     else
       echo 'ServerIdent off' >> \"\$F\"
     fi
     echo \"   ServerIdent off 설정: \$F\"
   done
   systemctl restart vsftpd 2>/dev/null; systemctl restart proftpd 2>/dev/null; true" \
  "_o=\$(grep -i 'ftpd_banner\|ServerIdent' \
       /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf \
       /etc/proftpd.conf /etc/proftpd/proftpd.conf 2>/dev/null \
       | grep -v '^#' | head -4 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '설정 없음 (VERIFY_OK)'" \
  "ftpd_banner=Welcome|ServerIdent off|VERIFY_OK"

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
      _mark_skipped "U-54" "FTP 서비스 [이미양호]"
    else
      _item_header "vuln" "U-54" "(중) 암호화되지 않는 FTP 서비스 비활성화"
      _lbl_before
      _u54_svc=""
      systemctl is-active vsftpd  2>/dev/null | grep -q '^active' && _u54_svc="vsftpd"
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
    _div_thick
    echo ""
  fi
}

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
     if grep -qi 'tcp_wrappers' \"\$F\"; then
       sed -i 's/tcp_wrappers=NO/tcp_wrappers=YES/I' \"\$F\"
     else
       echo 'tcp_wrappers=YES' >> \"\$F\"
     fi
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
      _mark_skipped "U-58" "SNMP 서비스 [이미양호]"
    else
      _item_header "vuln" "U-58" "(중) 불필요한 SNMP 서비스 구동 점검"
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
    _div_thick
    echo ""
  fi
}
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
do_fix "U-59" "(상) 안전한 SNMP 버전 사용" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec|^community' | head -3 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 설정 없음'" \
  "# SNMPv1/v2c community 라인 주석 처리 (v3 전환은 수동 필요)
   [ -f /etc/snmp/snmpd.conf ] && \
     sed -i 's/^\\(\\s*com2sec\\)/# [v1v2c-disabled] \\1/; s/^\\(\\s*community\\)/# [v1v2c-disabled] \\1/' /etc/snmp/snmpd.conf && \
     systemctl restart snmpd 2>/dev/null && echo '   SNMPv1/v2c community 라인 비활성화 완료'
   echo '   ※ SNMPv3 사용자 설정은 snmpd.conf 에 createUser/rouser 지시자로 수동 추가 필요'" \
  "_o=\$(grep -v '^#\\|v1v2c-disabled' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec|^community' | head -3 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMPv1/v2c 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-60" "(중) SNMP Community String 복잡성 설정" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'community\s+(public|private)' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음'" \
  "[ -f /etc/snmp/snmpd.conf ] && sed -i '/community\s\+public/d; /community\s\+private/d' /etc/snmp/snmpd.conf && systemctl restart snmpd 2>/dev/null" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'community\s+(public|private)' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '기본 Community 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-61" "(상) SNMP Access Control 설정" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep -iE 'com2sec.*default|agentaddress.*0\.0\.0\.0' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음'" \
  "[ -f /etc/snmp/snmpd.conf ] && sed -i 's/com2sec.*default.*/com2sec notConfigUser  localhost    public/' /etc/snmp/snmpd.conf && systemctl restart snmpd 2>/dev/null" \
  "_o=\$(grep -v '^#' /etc/snmp/snmpd.conf 2>/dev/null | grep 'com2sec' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo 'SNMP 없음 (VERIFY_OK)'" \
  "localhost|VERIFY_OK"

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
      _lbl_before
      _u62_issue=$(cat /etc/issue 2>/dev/null)
      _u62_issuenet=$(cat /etc/issue.net 2>/dev/null)
      _u62_sshbanner=$(sshd -T 2>/dev/null | grep -i '^banner' | awk '{print $2}')
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
        if grep -qi "^\s*Banner" /etc/ssh/sshd_config; then
          sed -i "s|^\s*Banner.*|Banner /etc/issue.net|I" /etc/ssh/sshd_config
        else
          echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
        fi
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

do_fix "U-63" "(중) sudo 명령어 접근 관리" \
  "ls -l /etc/sudoers 2>/dev/null || echo '/etc/sudoers 없음'" \
  "[ -f /etc/sudoers ] && chown root /etc/sudoers && chmod 640 /etc/sudoers" \
  "ls -l /etc/sudoers 2>/dev/null" \
  "^-r.-----.*root"

# ============================================================
section_header "패치 관리"
# ============================================================

# U-64 보안 패치 (패키지 관리자 및 구독 등록 여부에 따라 분기)
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
          fi ;;
        *)
          _mark_skipped "U-64" "보안 패치 [건너뜀]" ;;
      esac
    fi
    echo ""
  fi
}

# ============================================================
section_header "로그 관리"
# ============================================================

do_fix "U-65" "(중) NTP 및 시각 동기화 설정" \
  "timedatectl status 2>/dev/null | grep -E 'NTP|synchronized'
   systemctl is-active chronyd ntpd 2>/dev/null" \
  "if command -v yum &>/dev/null; then yum install -y chrony 2>/dev/null; fi
   systemctl enable --now chronyd 2>/dev/null" \
  "systemctl is-active chronyd 2>/dev/null || systemctl is-active ntpd 2>/dev/null || echo '비활성'" \
  "active"

do_fix "U-66" "(중) 정책에 따른 시스템 로깅 설정" \
  "systemctl is-active rsyslog 2>/dev/null; ls /var/log/messages /var/log/syslog 2>/dev/null | head -2" \
  "systemctl enable --now rsyslog 2>/dev/null" \
  "systemctl is-active rsyslog 2>/dev/null || echo '비활성'" \
  "active"

do_fix "U-67" "(중) 로그 디렉터리 소유자 및 권한 설정" \
  "stat -c '소유자: %U / 권한: %a' /var/log" \
  "chown root:root /var/log && chmod 755 /var/log" \
  "stat -c '소유자: %U / 권한: %a' /var/log" \
  "소유자: root / 권한: 7[0-9][0-9]"

# ============================================================
section_header "웹 서버(Apache) 보안 설정"
# ============================================================

# Apache 설정파일 탐색 (fix 스크립트용 — check_still_vuln과 공유)
_div_thick
echo -e "${BOLD} Apache 설정 파일 탐색${RESET}"
echo ""
echo -e " ${CYAN}※${RESET} U-68 ~ U-76 웹 서버 점검에 공통으로 사용할 설정 파일을 미리 찾는"
echo -e "   ${CYAN}사전 준비 단계${RESET}입니다. 조치 항목이 아니므로 [현재 상태]/[조치 중] 구분 없이 진행됩니다."
echo ""
_info "Apache 설정 파일 자동 탐색 중..."
echo ""

# ── Main Config 우선순위 탐색 ─────────────────────────────────────────────────
_FIX_APACHE_CONF=""
for _p in \
  /etc/httpd/conf/httpd.conf \
  /etc/apache2/apache2.conf \
  /usr/local/apache/conf/httpd.conf \
  /usr/local/apache2/conf/httpd.conf \
  /usr/local/httpd/conf/httpd.conf; do
  [ -f "$_p" ] && _FIX_APACHE_CONF="$_p" && break
done

# 위 경로에 없으면 find로 넓게 탐색 (Apache 지시자 포함 검증)
if [ -z "$_FIX_APACHE_CONF" ]; then
  _FIX_APACHE_CONF=$(find /etc /usr/local /opt /app \
    \( -name 'httpd.conf' -o -name 'apache2.conf' \) 2>/dev/null \
    | grep -vE '^(/usr/lib|/usr/share|/run|/var|/sys|/proc|/boot)' \
    | while IFS= read -r _f; do
        grep -qiE '^\s*(ServerRoot|Listen|ServerName|DocumentRoot)' "$_f" 2>/dev/null && echo "$_f"
      done | head -1)
fi

if [ -z "$_FIX_APACHE_CONF" ]; then
  echo -e "   ${RED}✗ Apache 설정 파일을 찾을 수 없습니다.${RESET}"
  echo ""
  _info "U-68 ~ U-75 항목은 수동 확인이 필요합니다."
  echo -e "   직접 탐색: ${CYAN}find / -name 'httpd.conf' 2>/dev/null${RESET}"
  echo ""
  _APACHE_SKIP=1
else
  _APACHE_SKIP=0

  # ── ServerRoot 추출 (상대경로 Include 기준) ─────────────────────────────────
  _APACHE_SRVROOT=$(grep -v '^\s*#' "$_FIX_APACHE_CONF" 2>/dev/null \
    | grep -iE '^\s*ServerRoot' | awk '{print $2}' | tr -d '"' | tail -1)
  [ -z "$_APACHE_SRVROOT" ] && _APACHE_SRVROOT=$(dirname "$_FIX_APACHE_CONF")

  # ── Include 재귀 파싱 함수 ──────────────────────────────────────────────────
  # declare -A (연관 배열) 전역 선언은 bash 4.x 에서 메모리 오염 → Segfault 유발 가능.
  # 문자열 기반 방문 추적으로 대체하고 최대 재귀 깊이를 제한한다.
  _apache_visited=""      # 방문한 파일 경로를 개행 구분 문자열로 관리
  _apache_include_files=()
  _apache_recurse_depth=0
  _APACHE_MAX_DEPTH=10

  _parse_apache_includes() {
    local conf="$1"
    [ -z "$conf" ] && return
    [ "$_apache_recurse_depth" -ge "$_APACHE_MAX_DEPTH" ] && return
    # 이미 방문한 파일이면 스킵 (순환 방지)
    echo "$_apache_visited" | grep -qxF "$conf" && return
    _apache_visited="${_apache_visited}
${conf}"
    _apache_recurse_depth=$((_apache_recurse_depth + 1))

    while IFS= read -r _line; do
      _pat=$(echo "$_line" | grep -iE '^\s*Include(Optional)?\s+' \
             | sed 's/^\s*Include\(Optional\)\?\s\+//' | tr -d '"')
      [ -z "$_pat" ] && continue
      [[ "$_pat" != /* ]] && _pat="${_APACHE_SRVROOT}/${_pat}"
      for _gf in $_pat; do
        [ -f "$_gf" ] || continue
        echo "$_apache_visited" | grep -qxF "$_gf" && continue
        _apache_include_files+=("$_gf")
        _parse_apache_includes "$_gf"
      done
    done < <(grep -v '^\s*#' "$conf" 2>/dev/null)

    _apache_recurse_depth=$((_apache_recurse_depth - 1))
  }

  _parse_apache_includes "$_FIX_APACHE_CONF"

  # ── 전체 설정 파일 목록 구성 ────────────────────────────────────────────────
  _FIX_APACHE_ALL_CONFS="$_FIX_APACHE_CONF"
  for _f in "${_apache_include_files[@]}"; do
    _FIX_APACHE_ALL_CONFS="$_FIX_APACHE_ALL_CONFS $_f"
  done

  # ── 결과 표시 ───────────────────────────────────────────────────────────────
  echo -e "   ${GREEN}✓ Main Config${RESET}"
  echo -e "     ${_FIX_APACHE_CONF}"
  echo -e "     ServerRoot: ${_APACHE_SRVROOT}"
  echo ""
  if [ ${#_apache_include_files[@]} -gt 0 ]; then
    echo -e "   ${GREEN}✓ Include 파일 (${#_apache_include_files[@]}개)${RESET}"
    for _f in "${_apache_include_files[@]}"; do
      echo -e "     ${_f}"
    done
  else
    _info "Include 파일 없음 (또는 glob 미매칭)"
  fi
fi

echo ""

_fix_apache_grep() {
  [ "${_APACHE_SKIP:-1}" -eq 1 ] && return 0
  local pat="$1"; shift
  for _f in "${_APACHE_CONFIGS[@]}"; do
    grep -v '^[[:space:]]*#' "$_f" 2>/dev/null | grep -E "$pat" "$@"
  done
}

do_fix "U-68" "(상) Apache 디렉터리 리스팅 제거" \
  "_o=\$(_fix_apache_grep 'Options.*Indexes' | grep -iv '\-Indexes' | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '미설정 (양호)'" \
  "_U68_ts=\$(_apache_backup_all)
   for _cf in \"\${_APACHE_CONFIGS[@]}\"; do
     [ -f \"\$_cf\" ] || continue
     grep -iE 'Options.*Indexes' \"\$_cf\" | grep -qiv '\\-Indexes' || continue
     sed -i -E '/^[[:space:]]*Options/s/[[:space:]]+\\+?Indexes//gI' \"\$_cf\"
     sed -i -E '/^[[:space:]]*Options/s/\\+?Indexes[[:space:]]+//gI' \"\$_cf\"
     sed -i -E 's/^([[:space:]]*)Options[[:space:]]*\$/\\1Options None/' \"\$_cf\"
     echo \"   Indexes 제거: \$_cf\"
   done
   _apache_reload_guard \"\$_U68_ts\"" \
  "_fix_apache_grep 'Options.*Indexes' | grep -iv '\-Indexes' || echo '미설정 (VERIFY_OK)'" \
  "VERIFY_OK"

do_manual "U-69" "(상) Apache 웹 프로세스 권한 제한" \
  "httpd.conf User/Group을 비root 계정(apache, www-data 등)으로 설정 후 Apache 재시작 필요" \
  "if [ -n \"\$_FIX_APACHE_CONF\" ] && [ -f \"\$_FIX_APACHE_CONF\" ]; then
     grep -v '^#' \"\$_FIX_APACHE_CONF\" 2>/dev/null \
       | grep -iE '^[[:space:]]*(User|Group)[[:space:]]' | head -4
   else
     echo '  Apache 설정 파일 없음 — 해당없음 또는 수동 확인'
   fi
   _ap_user=\$(ps -eo user,comm 2>/dev/null | grep -E 'httpd|apache2' | awk '{print \$1}' | sort -u | head -3)
   [ -n \"\$_ap_user\" ] && echo \"  실행 계정: \$_ap_user\" || echo '  Apache 프로세스 미감지'"

do_fix "U-70" "(상) Apache 상위 디렉터리 접근 금지" \
  "_o=\$(for _cf in \$_FIX_APACHE_ALL_CONFS; do
     awk '/<Directory[[:space:]]*\"?\\/\"?[[:space:]]*>/{f=1} f && /AllowOverride/{print FILENAME\": \"\$0;f=0} /<\/Directory>/{f=0}' \"\$_cf\" 2>/dev/null
   done | head -5); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '  AllowOverride 미설정'
   echo '  [KISA 기준] AllowOverride None = 양호'" \
  "_U70_ts=\$(_apache_backup_all)
   for _cf in \"\${_APACHE_CONFIGS[@]}\"; do
     [ -f \"\$_cf\" ] || continue
     _v=\$(awk '/<Directory[[:space:]]*\"?\\/\"?[[:space:]]*>/{f=1} f && /AllowOverride/{val=\$0;f=0} END{print val}' \"\$_cf\" 2>/dev/null | tr -d ' ')
     echo \"\$_v\" | grep -qi 'None' && continue
     if echo \"\$_v\" | grep -qi 'AllowOverride'; then
       sed -i 's/AllowOverride[[:space:]]\+[A-Za-z]\+/AllowOverride None/' \"\$_cf\" && \
         echo \"   AllowOverride → None: \$_cf\"
     else
       printf '\n# KISA U-70\n<Directory />\n    AllowOverride None\n    Options None\n    Order deny,allow\n    Deny from all\n</Directory>\n' >> \"\$_cf\"
       echo \"   <Directory /> AllowOverride None 블록 추가: \$_cf\"
     fi
   done
   _apache_reload_guard \"\$_U70_ts\"" \
  "_o=\$(for _cf in \$_FIX_APACHE_ALL_CONFS; do
     awk '/<Directory[[:space:]]*\"?\\/\"?[[:space:]]*>/{f=1} f && /AllowOverride/{if(/None/) print \"AllowOverride None 확인 (VERIFY_OK)\";f=0}' \"\$_cf\" 2>/dev/null | grep -q VERIFY_OK && echo \"VERIFY_OK\" && break
   done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '검증 실패'" \
  "VERIFY_OK"

do_fix "U-71" "(상) Apache 불필요한 파일 제거" \
  "_o=\$(for _d in /var/www/html/manual /usr/local/apache/htdocs/manual /usr/local/apache2/htdocs/manual /usr/share/doc/apache2; do [ -d \"\$_d\" ] && echo \"\$_d 존재\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '불필요 디렉터리 없음 (양호)'" \
  "for _d in /var/www/html/manual /usr/local/apache/htdocs/manual /usr/local/apache2/htdocs/manual /usr/share/doc/apache2; do
     [ -d \"\$_d\" ] && rm -rf \"\$_d\" && echo \"   삭제: \$_d\" || true
   done" \
  "_o=\$(for _d in /var/www/html/manual /usr/local/apache/htdocs/manual /usr/local/apache2/htdocs/manual /usr/share/doc/apache2; do [ -d \"\$_d\" ] && echo \"\$_d 잔존\"; done); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '불필요 디렉터리 없음 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-72" "(상) Apache 심볼릭 링크 사용 금지" \
  "_o=\$(_fix_apache_grep 'Options.*FollowSymLinks' | grep -iv '\-FollowSymLinks' | head -5 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '미설정 (양호)'" \
  "_U72_ts=\$(_apache_backup_all)
   for _cf in \"\${_APACHE_CONFIGS[@]}\"; do
     [ -f \"\$_cf\" ] || continue
     grep -iE 'Options.*FollowSymLinks' \"\$_cf\" | grep -qiv '\-FollowSymLinks' || continue
     sed -i -E '/^[[:space:]]*Options/s/[[:space:]]+\\+?FollowSymLinks//gI' \"\$_cf\"
     sed -i -E '/^[[:space:]]*Options/s/\\+?FollowSymLinks[[:space:]]+//gI' \"\$_cf\"
     sed -i -E 's/^([[:space:]]*)Options[[:space:]]*\$/\\1Options None/' \"\$_cf\"
     echo \"   FollowSymLinks 제거: \$_cf\"
   done
   _apache_reload_guard \"\$_U72_ts\"" \
  "_fix_apache_grep 'Options.*FollowSymLinks' | grep -iv '\-FollowSymLinks' || echo 'FollowSymLinks 비활성 (VERIFY_OK)'" \
  "VERIFY_OK"

do_fix "U-73" "(상) Apache 파일 업로드/다운로드 용량 제한" \
  "_o=\$(_fix_apache_grep 'LimitRequestBody' | head -3 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '미설정'" \
  "# LimitRequestBody 미설정 시 주 설정 파일에 추가 (기본 10MB)
   if [ -n \"\$_FIX_APACHE_CONF\" ] && ! _fix_apache_grep 'LimitRequestBody' | grep -qE '^[0-9]+\$'; then
     echo '' >> \"\$_FIX_APACHE_CONF\"
     echo '# KISA U-73: 파일 업로드/다운로드 제한' >> \"\$_FIX_APACHE_CONF\"
     echo 'LimitRequestBody 10485760' >> \"\$_FIX_APACHE_CONF\"
     echo '   LimitRequestBody 10485760 추가: \$_FIX_APACHE_CONF'
   fi
   systemctl reload httpd apache2 2>/dev/null; true" \
  "_o=\$(_fix_apache_grep 'LimitRequestBody' | head -2 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '설정 없음'" \
  "LimitRequestBody"

do_manual "U-74" "(상) Apache 웹 서비스 영역 분리" \
  "DocumentRoot가 /usr, /etc 등 시스템 디렉터리와 분리된 전용 경로인지 확인 필요" \
  "echo 'DocumentRoot 설정:'
   _fix_apache_grep '^[[:space:]]*DocumentRoot' 2>/dev/null | head -5 | sed 's/^/  /'
   echo ''
   echo 'Apache 실행 계정:'
   ps -eo user,comm 2>/dev/null | grep -E 'httpd|apache2' | awk '{print \"  \"\$1}' | sort -u
   echo ''
   echo '웹 루트 소유자/권한:'
   _dr=\$(_fix_apache_grep '^[[:space:]]*DocumentRoot' 2>/dev/null | head -1 | awk '{print \$NF}' | tr -d '\"')
   [ -n \"\$_dr\" ] && ls -ld \"\$_dr\" 2>/dev/null | sed 's/^/  /' || echo '  DocumentRoot 경로 확인 불가'"

do_fix "U-75" "(중) Apache 웹 서비스 정보 숨김" \
  "_o=\$(_fix_apache_grep 'ServerTokens|ServerSignature' | head -4 2>/dev/null); [ -n \"\$_o\" ] && echo \"\$_o\" || echo '미설정'" \
  "_U75_ts=\$(_apache_backup_all)
   if [ -n \"\$_FIX_APACHE_CONF\" ] && [ -f \"\$_FIX_APACHE_CONF\" ]; then
     grep -q 'ServerTokens' \"\$_FIX_APACHE_CONF\" \
       && sed -i 's/^\\s*ServerTokens.*/ServerTokens Prod/' \"\$_FIX_APACHE_CONF\" \
       || echo 'ServerTokens Prod' >> \"\$_FIX_APACHE_CONF\"
     grep -q 'ServerSignature' \"\$_FIX_APACHE_CONF\" \
       && sed -i 's/^\\s*ServerSignature.*/ServerSignature Off/' \"\$_FIX_APACHE_CONF\" \
       || echo 'ServerSignature Off' >> \"\$_FIX_APACHE_CONF\"
     echo '   ServerTokens Prod, ServerSignature Off 설정 완료'
     _apache_reload_guard \"\$_U75_ts\"
   else
     echo '   Apache 설정 파일 없음 — 해당없음'
   fi" \
  "_fix_apache_grep 'ServerTokens|ServerSignature' | head -4" \
  "Prod.*Off\|Prod\|Off"

do_manual "U-76" "(중) 서버용 백신 프로그램 운용" \
  "ClamAV, V3 Net for Linux, McAfee 등 백신 설치 + 정기 업데이트/스케줄 설정 확인 필요" \
  "echo '백신 탐지 결과:'
   _found=0
   for _av in clamd clamav freshclam ahnlab V3NetForLinux uvscan ds_agent mcafee; do
     if pgrep -f \"\$_av\" &>/dev/null; then
       echo \"  ✓ \$_av — 프로세스 실행 중\"
       _found=1
     elif command -v \"\$_av\" &>/dev/null; then
       echo \"  → \$_av — 설치됨 (프로세스 미실행)\"
       _found=1
     fi
   done
   [ \$_found -eq 0 ] && echo '  ✗ 백신 미탐지 — 수동 설치 필요'
   echo ''
   echo '정기 업데이트 스케줄 (cron):'
   grep -rh 'freshclam\|clamscan\|ahnlab\|V3\|uvscan' /etc/cron* /var/spool/cron 2>/dev/null \
     | grep -v '^#' | sed 's/^/  /' | head -5 || echo '  스케줄 없음 — cron 설정 필요'"
# ============================================================
# ============================================================
# SELinux 컨텍스트 복구
# ============================================================
# sed -i로 수정한 기존 파일은 보통 원래 컨텍스트가 유지되지만, 새로 만든
# 파일(/etc/profile.d/tmout.sh, /etc/tmpfiles.d/*.conf, systemd drop-in 등)은
# 잘못된 컨텍스트로 생성될 수 있다. SELinux가 enforcing/permissive 상태일 때만
# 안전하게 restorecon으로 표준 컨텍스트를 되돌려놓는다 (라벨이 이미 맞으면
# 아무 일도 하지 않는 무해한 동작).
if command -v getenforce &>/dev/null && [ "$(getenforce 2>/dev/null)" != "Disabled" ] \
   && command -v restorecon &>/dev/null; then
  restorecon -RF \
    /etc/pam.d /etc/ssh /etc/security /etc/profile.d /etc/tmpfiles.d \
    /etc/systemd/system /etc/cron.d /etc/sudoers.d /etc/login.defs \
    /etc/issue /etc/issue.net /etc/motd 2>/dev/null
fi

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
    [ -n "$before" ] && echo "$before" | head -2 | sed "s/^/   조치 전 : /"
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      echo "$after"  | head -2 | sed "s/^/   조치 후 : /"
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
    [ -n "$before" ] && echo "$before" | head -2 | sed "s/^/   조치 전 : /"
    [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
      echo "$after"  | head -2 | sed "s/^/   조치 후 : /"
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

# ── 결과 보고서 파일 저장 ─────────────────────────────────────────────────────
_RPT_DIR="/var/log"
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
  echo "  총 점검    : ${#TARGET_IDS[@]}개 항목 (U-01 ~ U-76)"
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
      [ -n "$before" ] && echo "$before" | head -2 | sed 's/^/    조치 전 : /'
      [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
        echo "$after"  | head -2 | sed 's/^/    조치 후 : /'
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
      [ -n "$before" ] && echo "$before" | head -2 | sed 's/^/    조치 전 : /'
      [ -n "$after"  ] && [[ "$after" != "건너뜀" ]] && \
        echo "$after"  | head -2 | sed 's/^/    조치 후 : /'
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
  echo "  이력 로그 : /var/log/vulnFixHistory.log"
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
else
  echo -e " ${YELLOW}!! 보고서 저장 실패 — ${_RPT_DIR} 쓰기 권한 확인 필요${RESET}"
fi
_div_thick
