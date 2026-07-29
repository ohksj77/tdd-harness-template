#!/bin/sh
# assert.sh — 최소 단언 라이브러리. source 해서 쓴다.
# POSIX sh. 색은 TTY일 때만.

set -u

ASSERT_PASS=0
ASSERT_FAIL=0
ASSERT_GROUP=""

if [ -t 1 ]; then
	_C_RED=$(printf '\033[31m')
	_C_GRN=$(printf '\033[32m')
	_C_DIM=$(printf '\033[2m')
	_C_OFF=$(printf '\033[0m')
else
	_C_RED=""
	_C_GRN=""
	_C_DIM=""
	_C_OFF=""
fi

group() {
	ASSERT_GROUP=$1
	printf '\n%s── %s%s\n' "$_C_DIM" "$1" "$_C_OFF"
}

pass() {
	ASSERT_PASS=$((ASSERT_PASS + 1))
	printf '  %sok%s   %s\n' "$_C_GRN" "$_C_OFF" "$1"
}

fail() {
	ASSERT_FAIL=$((ASSERT_FAIL + 1))
	printf '  %sFAIL%s %s\n' "$_C_RED" "$_C_OFF" "$1"
	[ $# -gt 1 ] && printf '       기대: %s\n' "$2"
	[ $# -gt 2 ] && printf '       실제: %s\n' "$3"
	return 0
}

# assert_eq <name> <expected> <actual>
assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# assert_ne <name> <not-expected> <actual>
assert_ne() {
	if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "!= $2" "$3"; fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
	case "$3" in
	*"$2"*) pass "$1" ;;
	*) fail "$1" "포함: $2" "$3" ;;
	esac
}

# assert_not_contains <name> <needle> <haystack>
assert_not_contains() {
	case "$3" in
	*"$2"*) fail "$1" "미포함: $2" "$3" ;;
	*) pass "$1" ;;
	esac
}

assert_summary() {
	printf '\n'
	if [ "$ASSERT_FAIL" -eq 0 ]; then
		printf '%s%s개 통과, 실패 없음%s\n' "$_C_GRN" "$ASSERT_PASS" "$_C_OFF"
		return 0
	fi
	printf '%s%s개 실패%s (통과 %s개)\n' "$_C_RED" "$ASSERT_FAIL" "$_C_OFF" "$ASSERT_PASS"
	return 1
}
