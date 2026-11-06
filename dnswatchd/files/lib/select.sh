#!/bin/sh
# SPDX-License-Identifier: MIT
#
# dnswatchd - one round: probe every upstream, then choose.
#
# priority and latency share this single path. priority is "smallest priority
# number wins"; latency is "smallest DNS round-trip wins, and it has to beat the
# current one by latency_margin percent for latency_switch_after rounds in a
# row". Probing every upstream every round (instead of stopping at the first
# healthy one) is what makes `status` tell the truth about the fallbacks.

: "${DNSWATCHD_LIB:=/usr/lib/dnswatchd}"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/common.sh"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/state.sh"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/probe.sh"
# shellcheck source=/dev/null
. "$DNSWATCHD_LIB/apply.sh"

# Returns 0 when the candidate should really be promoted.
_challenger_wins() {
	_cand=$1
	_cf="$STATE_DIR/challenger.count"
	_lf="$STATE_DIR/challenger.section"
	_count=0
	_prev_cand=""

	[ -f "$_cf" ] && _count=$(cat "$_cf" 2>/dev/null)
	[ -f "$_lf" ] && _prev_cand=$(cat "$_lf" 2>/dev/null)

	[ "$_prev_cand" != "$_cand" ] && _count=0
	_count=$((_count + 1))

	printf '%s\n' "$_count" > "$_cf" 2>/dev/null
	printf '%s\n' "$_cand" > "$_lf" 2>/dev/null

	if [ "$_count" -ge "$LATENCY_SWITCH_AFTER" ]; then
		log "latency: '$_cand' won $_count/$LATENCY_SWITCH_AFTER rounds in a row -> promoting"
		return 0
	fi

	log "latency: '$_cand' won $_count/$LATENCY_SWITCH_AFTER rounds; still observing"
	return 1
}

# -1 when b is not at least m percent faster than a
_faster_enough() {
	_best=$1
	_cur=$2
	awk -v b="$_best" -v c="$_cur" -v m="$LATENCY_MARGIN" \
		'BEGIN { exit !(b < c * (100 - m) / 100) }'
}

run_round() {
	ensure_state_dir

	_list="$STATE_DIR/upstreams.list"
	_n=$(collect_upstreams "$_list")

	if [ "$_n" -eq 0 ]; then
		log "no enabled upstream configured; nothing to do"
		return 0
	fi

	_prev=$(active_section "$_list")
	sort -t'|' -k1,1n -k2,2 "$_list" > "$STATE_DIR/upstreams.sorted"

	_cand_file="$STATE_DIR/candidates.list"
	: > "$_cand_file"

	_start=$(date +%s)
	_budget=$((INTERVAL * ROUND_BUDGET_PCT / 100))
	[ "$_budget" -lt 3 ] && _budget=3

	while IFS='|' read -r pri sec addr port dom cidr mode; do
		[ -n "$addr" ] || continue

		_now=$(date +%s)
		if [ $((_now - _start)) -gt "$_budget" ]; then
			log "round budget ${_budget}s exceeded; skipping remaining upstreams"
			break
		fi

		state_read "$sec"

		_round_ok=0
		if probe_one "$addr" "$port" "$dom" "$cidr" "$mode"; then
			_round_ok=1
			ST_OKS=$((ST_OKS + 1))
			ST_FAILS=0
			ST_RTT=$P_RTT
			if [ "$ST_STATUS" != "up" ] && [ "$ST_OKS" -ge "$RECOVER_TH" ]; then
				ST_STATUS=up
				log "upstream '$sec' is UP (ok=$ST_OKS)"
			fi
		else
			ST_FAILS=$((ST_FAILS + 1))
			ST_OKS=0
			ST_RTT=""
			if [ "$ST_STATUS" != "down" ] && [ "$ST_FAILS" -ge "$FAIL_TH" ]; then
				ST_STATUS=down
				log "upstream '$sec' is DOWN (fail=$ST_FAILS class=${P_CLASS:-unknown} rcode=${P_RCODE:-none})"
			fi
		fi

		state_write "$sec"

		# Debounce cuts both ways: one blip does not demote a known-good
		# upstream, and one success does not promote a known-bad one.
		_usable=0
		if [ "$_round_ok" = "1" ] && [ "$ST_STATUS" != "down" ]; then
			_usable=1
		elif [ "$ST_STATUS" = "up" ]; then
			_usable=1
		fi

		printf '%s|%s|%s|%s|%s|%s\n' \
			"$pri" "$sec" "$addr" "$port" "$ST_RTT" "$_usable" >> "$_cand_file"
	done < "$STATE_DIR/upstreams.sorted"

	# ---------------------------------------------------------- decide

	_survivors="$STATE_DIR/survivors.list"

	if [ "$SELECTION" = "latency" ]; then
		awk -F'|' '$6 == 1 && $5 != ""' "$_cand_file" \
			| sort -t'|' -k5,5n -k1,1n > "$_survivors"
	else
		awk -F'|' '$6 == 1' "$_cand_file" | sort -t'|' -k1,1n > "$_survivors"
	fi

	_best=$(head -1 "$_survivors")
	if [ -z "$_best" ]; then
		log "no healthy upstream this round; keeping previous '${_prev:-none}'"
		return 0
	fi

	_bpri=$(echo "$_best" | cut -d'|' -f1)
	_bsec=$(echo "$_best" | cut -d'|' -f2)
	_baddr=$(echo "$_best" | cut -d'|' -f3)
	_bport=$(echo "$_best" | cut -d'|' -f4)
	_brtt=$(echo "$_best" | cut -d'|' -f5)

	if [ "$_bsec" = "$_prev" ]; then
		[ "$VERBOSE" = "1" ] && log "stable on '$_bsec' ($_baddr, rtt=${_brtt:-n/a}ms)"
		printf '0\n' > "$STATE_DIR/challenger.count" 2>/dev/null
		return 0
	fi

	if [ "$SELECTION" = "latency" ] && [ -n "$_prev" ] && [ "$_prev" != "?" ]; then
		_prev_rtt=$(awk -F'|' -v s="$_prev" '$2 == s { print $5; exit }' "$_cand_file")

		if [ -n "$_prev_rtt" ]; then
			if ! _faster_enough "$_brtt" "$_prev_rtt"; then
				log "latency: '$_bsec' ${_brtt}ms vs current '$_prev' ${_prev_rtt}ms — not ${LATENCY_MARGIN}% faster, staying"
				return 0
			fi
			_challenger_wins "$_bsec" || return 0
		else
			# The incumbent produced no RTT this round, so there is nothing to
			# compare against: switch immediately.
			log "latency: previous '$_prev' not measurable this round; switching immediately"
		fi
	fi

	if apply_upstream "$_baddr" "$_bport"; then
		printf '0\n' > "$STATE_DIR/challenger.count" 2>/dev/null
		log "SWITCH: ${_prev:-none} -> $_bsec ($_baddr, priority=$_bpri, rtt=${_brtt:-n/a}ms)"
	else
		err "failed to apply '$_bsec' ($_baddr); servers-file left untouched"
		return 1
	fi

	return 0
}
