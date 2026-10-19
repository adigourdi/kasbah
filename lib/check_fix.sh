# kasbah — `check --fix`: the auto-fixable half of docs/compliance.md
# Sourced by lib/check.sh. Do not execute directly.

[ -n "${_KASBAH_CHECK_FIX_LOADED:-}" ] && return 0
_KASBAH_CHECK_FIX_LOADED=1

. "$KASBAH_LIB_DIR/common.sh"
. "$KASBAH_LIB_DIR/prompt.sh"

# ----------------------------------------------------------------------------
# Why this is a line editor and not a yq round trip
# ----------------------------------------------------------------------------
# `yq -y` reads a document and writes it back re-serialised: keys come out in
# jq's order, every comment is gone, and quoting and blank lines are the
# emitter's choice rather than the author's. Compose files carry load-bearing
# comments — this repo's own fixtures explain *why* a service is named for the
# project and why two networks are declared — so a fix that reformatted the file
# would cost more than the rule it repaired. Every edit below is therefore a
# targeted change to the existing bytes: an inserted line, a rewritten value on
# one line, or a deleted key. Everything else comes back byte for byte,
# including CRLF endings and a missing final newline.
#
# The safety rule that makes that defensible: **yq decides what is true, the
# line scanner only finds where it is written.** A rule's verdict and the
# insert-or-replace decision come from yq (`has(...)` and the value); if the
# scanner then cannot find that key in the text — a quoted key it does not know,
# a flow mapping, an anchor — the fix is *refused and reported*, never guessed
# at. And a staged edit is verified before anything is written: the result has
# to parse, keep exactly the same top-level and service keys, and leave the
# planner with nothing more to do. That last one is idempotency checked at
# runtime rather than hoped for.
#
# Scope is docs/compliance.md → `--fix` behavior, and nothing else: C01–C05,
# C08, R01–R03 and the `kasbah_version` backfill, in `compose.prod.yml` and
# `kasbah.yml` only.
#
# Sourced by lib/check.sh, and only from there: C03 asks `_traefik_routed_hosts`
# which service is routed, so that the fix and the rule cannot disagree about
# what "routed" means.

# The file being edited, as lines. CR is kept on each line so a CRLF file comes
# back CRLF; matching strips it. _CF_EOL is what an *inserted* line ends with,
# so inserted lines match the file they land in.
_CF_LINES=()
_CF_EOL=""
_CF_FINAL_NL=1

# Per-line edits, parallel to _CF_LINES. A line is deleted, or replaced, or
# neither. Insertions are a flat list instead, because more than one can be
# anchored on the same line — a service's last content line is also the last
# line of whatever block it ends in — and they then have to come out
# deepest-first, or a key meant for the service lands inside that inner block.
_CF_DEL=()
_CF_REP=()
_CF_HASREP=()
_CF_INS_AT=()
_CF_INS_IND=()
_CF_INS_TXT=()

# What the operator is shown: one line per edit, and one per thing left alone.
_CF_PLAN=()
_CF_LEFT=()
# 0 while the planner is re-run over the staged result to prove it settled —
# that pass must not append a second copy of every refusal.
_CF_COLLECT=1

# Out-parameters. Bash cannot return a value, and `$(…)` per line of a compose
# file is a fork per line.
_CF_IND=0
_CF_IDX=-1
_CF_END=-1
_CF_SEND=-1
_CF_CI=0
_CF_STEP=2
# The step between the service currently being planned and its own keys, which
# is what a key inserted two levels under it (logging.options, a networks list)
# is nested by. A file that indents its sub-blocks by some other amount gets the
# service-key step here, which is the one its services agree on.
_CF_SVC_STEP=2
_CF_TMP=""
_CF_PLAN_TEXT=""
# Every candidate written beside its target, so a run that ends early does not
# leave one in the tree `deploy` rsyncs.
_CF_TEMPS=()

_cf_plan() { _CF_PLAN+=("$1"); }

# What the plan does to the parsed tree, as jq: _CF_OPS sets, deletes and
# appends; _CF_MASK drops a rewritten scalar on both sides, its new value being
# the re-plan's to prove. _cf_guard holds the candidate to it.
_CF_OPS=""
_CF_MASK=""
_CF_P=""
_cf_op_path() { local p="" k; for k in "$@"; do p+="${p:+,}\"$k\""; done; _CF_P="[$p]"; }
_cf_set()  { local v="$1"; shift; _cf_op_path "$@"; _CF_OPS+=" | setpath($_CF_P; $v)"; }
_cf_del()  { _cf_op_path "$@"; _CF_OPS+=" | delpaths([$_CF_P])"; }
_cf_app()  { local v="$1"; shift; _cf_op_path "$@"; _CF_OPS+=" | setpath($_CF_P; (getpath($_CF_P) | if . == null then [] else . end) + [$v])"; }
_cf_mask() { _cf_op_path "$@"; _CF_MASK+=" | delpaths([$_CF_P])"; }
_cf_left() { [ "$_CF_COLLECT" = 1 ] && _CF_LEFT+=("$1"); return 0; }

# ----------------------------------------------------------------------------
# Reading and writing the bytes
# ----------------------------------------------------------------------------

# _cf_read_file FILE — into _CF_LINES, remembering the two things a naive
# rewrite loses: CRLF endings, and whether the last line had a newline at all.
_cf_read_file() {
    local f="$1" line
    _CF_LINES=()
    _CF_EOL=""
    _CF_FINAL_NL=1
    # Checked rather than assumed: a failing `< "$f"` under errexit would end
    # `kasbah check` mid-report rather than refuse one fix.
    [ -f "$f" ] && [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        _CF_LINES+=("$line")
        case "$line" in *$'\r') _CF_EOL=$'\r' ;; esac
    done < "$f"
    if [ -s "$f" ] && [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then
        _CF_FINAL_NL=0
    fi
    return 0
}

_cf_reset_edits() {
    local i n=${#_CF_LINES[@]}
    _CF_DEL=(); _CF_REP=(); _CF_HASREP=(); _CF_PLAN=()
    _CF_INS_AT=(); _CF_INS_IND=(); _CF_INS_TXT=()
    _CF_OPS=""; _CF_MASK=""
    for ((i = 0; i < n; i++)); do
        _CF_DEL+=(0); _CF_REP+=(""); _CF_HASREP+=(0)
    done
    return 0
}

# _cf_render — the edited file on stdout, and the only place the edits are
# turned back into bytes. Insertions anchored on one line are emitted from the
# deepest indentation outwards, and in the order they were planned within one
# indentation: deterministic, which is what makes a second run a no-op.
_cf_render() {
    local i k n=${#_CF_LINES[@]} l last lvl m=${#_CF_INS_AT[@]} want entry
    local -a out=() anchored=()
    # Which lines carry an insertion at all, so the indentation sweep below runs
    # on the handful of lines that need it rather than on every line of the file.
    for ((i = 0; i < n; i++)); do anchored+=(0); done
    for ((k = 0; k < m; k++)); do anchored[${_CF_INS_AT[k]}]=1; done
    for ((i = 0; i < n; i++)); do
        if [ "${_CF_DEL[i]}" != 1 ]; then
            if [ "${_CF_HASREP[i]}" = 1 ]; then
                out+=("${_CF_REP[i]}")
            else
                out+=("${_CF_LINES[i]}")
            fi
        fi
        [ "${anchored[i]}" = 1 ] || continue
        # Within one indentation, sequence entries first: they continue a flush
        # list that ends on this line, which a key emitted first would cut.
        for ((lvl = _CF_MAX_INDENT; lvl >= 0; lvl--)); do
            for want in 1 0; do
                for ((k = 0; k < m; k++)); do
                    [ "${_CF_INS_AT[k]}" = "$i" ] || continue
                    [ "${_CF_INS_IND[k]}" = "$lvl" ] || continue
                    l="${_CF_INS_TXT[k]%%$'\n'*}"
                    l="${l%$'\r'}"
                    if _cf_is_entry "${l:lvl}"; then entry=1; else entry=0; fi
                    [ "$entry" = "$want" ] || continue
                    while IFS= read -r l; do out+=("$l"); done <<<"${_CF_INS_TXT[k]}"
                done
            done
        done
    done
    n=${#out[@]}
    [ "$n" -gt 0 ] || return 0
    if [ "$_CF_FINAL_NL" = 1 ]; then
        printf '%s\n' "${out[@]}"
        return 0
    fi
    # The file ended mid-line and must keep doing so.
    last=$((n - 1))
    [ "$last" -eq 0 ] || printf '%s\n' "${out[@]:0:$last}"
    printf '%s' "${out[$last]}"
    return 0
}

# The deepest indentation _cf_render sorts insertions by. Well past anything a
# hand-written compose file nests to; a block deeper than this would come out in
# planning order rather than deepest-first, so it is generous on purpose.
_CF_MAX_INDENT=64

# _cf_insert_after IDX TEXT — TEXT is one or more already-indented lines,
# newline-separated and without CR; the file's own line ending is added here.
# The indentation of its first line decides where it sorts against anything else
# anchored on the same line.
_cf_insert_after() {
    local idx="$1" text="$2" line acc=""
    local -a got=()
    while IFS= read -r line; do got+=("$line$_CF_EOL"); done <<<"$text"
    # Joined with printf rather than by appending, because a blank first line —
    # the separator before an appended top-level block — is exactly what
    # `${acc:+…}` would swallow.
    printf -v acc '%s\n' "${got[@]}"
    acc="${acc%$'\n'}"
    _cf_indent "$text"
    _CF_INS_AT+=("$idx")
    _CF_INS_IND+=("$_CF_IND")
    _CF_INS_TXT+=("$acc")
    return 0
}

# ----------------------------------------------------------------------------
# Reading the shape of the text
# ----------------------------------------------------------------------------

# _cf_indent LINE → _CF_IND, the count of leading spaces. YAML forbids tabs in
# indentation and yq has already parsed the file, so spaces are all there is.
_cf_indent() {
    local s="${1%$'\r'}" t
    t="${s%%[! ]*}"
    _CF_IND=${#t}
    return 0
}

_cf_is_blank()   { [[ "${1%$'\r'}" =~ ^[[:space:]]*$ ]]; }
_cf_is_comment() { [[ "${1%$'\r'}" =~ ^[[:space:]]*# ]]; }

# _cf_scalar_header IDX — true when the line at IDX is a `|` or `>` block-scalar
# header, its chomping and indentation indicators allowed and a comment after
# them. The indicator may follow `- ` entries (`- |`, `- - >-`), a `key:`, and
# anchors and tags (`entrypoint: &ep |`, `test: !!str >-`). Sets _CF_SIND, the
# column the content is deeper than — the key's, or the last entry's dash — and
# _CF_SKEEP, 1 under `+`. What follows such a header is text, not structure.
_CF_SIND=0
_CF_SKEEP=0
_cf_scalar_header() {
    local s="${_CF_LINES[$1]%$'\r'}" v col n
    _cf_indent "$s"; col=$_CF_IND
    v="${s:col}"
    _CF_SIND=$col
    _CF_SKEEP=0
    while _cf_is_entry "$v"; do
        _CF_SIND=$col
        n="${v#-}"
        n="${n#"${n%%[! $'\t']*}"}"
        col=$((col + ${#v} - ${#n}))
        v="$n"
    done
    [ -n "$v" ] || return 1
    case "$v" in
        '|'*|'>'*|'&'*|'!'*) ;;
        *:*) _CF_SIND=$col; v="${v#*:}" ;;
        *) return 1 ;;
    esac
    while :; do
        v="${v#"${v%%[! $'\t']*}"}"
        case "$v" in
            '&'*|'!'*)
                case "$v" in *[' '$'\t']*) ;; *) return 1 ;; esac
                v="${v#*[' '$'\t']}"
                ;;
            *) break ;;
        esac
    done
    _cf_split_value "$v" || return 1
    case "$_CF_VAL" in
        '|'*|'>'*) ;;
        *) return 1 ;;
    esac
    case "${_CF_VAL:1}" in *[!-+0-9]*) return 1 ;; esac
    case "$_CF_VAL" in *'+'*) _CF_SKEEP=1 ;; esac
    return 0
}

# True when TEXT, its indentation removed, is a sequence entry.
_cf_is_entry() {
    case "${1%$'\r'}" in '-'|'- '*|'-'$'\t'*) return 0 ;; esac
    return 1
}

# _cf_scalar_end IDX → _CF_SEND, the last line of the block scalar opened at
# IDX (after _cf_scalar_header IDX). Its content is every following line that is
# blank or deeper than _CF_SIND; the first non-blank line at or above it ends
# it. That is YAML's own rule, and it is why a `#` line *inside* the region is
# text rather than a comment — which is the whole reason this function exists.
#
# Trailing blank lines are part of the region only when the header keeps them
# (`|+`, `>+`), because those newlines are the value. Under clip or strip YAML
# discards them, so they are left outside and an insertion lands above rather
# than below them.
_cf_scalar_end() {
    local idx="$1" ind="$_CF_SIND" keep="$_CF_SKEEP" i n=${#_CF_LINES[@]}
    # Separate statements: `local a=$1 b=$a` declares every name before it
    # assigns any, so `b` would read an unset `a` and die under set -u.
    local last=$idx lastnb=$idx
    for ((i = idx + 1; i < n; i++)); do
        if _cf_is_blank "${_CF_LINES[i]}"; then last=$i; continue; fi
        _cf_indent "${_CF_LINES[i]}"
        if [ "$_CF_IND" -le "$ind" ]; then break; fi
        last=$i
        lastnb=$i
    done
    if [ "$keep" = 1 ]; then _CF_SEND=$last; else _CF_SEND=$lastnb; fi
    return 0
}

# _cf_first_child START → _CF_FC, the first content line after START, or -1.
_cf_first_child() {
    local i n=${#_CF_LINES[@]}
    _CF_FC=-1
    for ((i = $1 + 1; i < n; i++)); do
        if _cf_is_blank "${_CF_LINES[i]}"; then continue; fi
        if _cf_is_comment "${_CF_LINES[i]}"; then continue; fi
        _CF_FC=$i
        return 0
    done
    return 0
}
_CF_FC=-1

# _cf_flush_seq START — true when the key at START holds a sequence written at
# its own indentation (`key:` then `- a` under it, unindented), which YAML
# allows; its entries are then its children.
_cf_flush_seq() {
    local start="$1" ind s
    _cf_indent "${_CF_LINES[start]}"; ind=$_CF_IND
    _cf_raw_value "$start"
    [ -z "$_CF_RAW" ] || return 1
    s="${_CF_LINES[start]%$'\r'}"
    ! _cf_is_entry "${s:ind}" || return 1
    _cf_first_child "$start"
    [ "$_CF_FC" -ge 0 ] || return 1
    _cf_indent "${_CF_LINES[_CF_FC]}"
    [ "$_CF_IND" = "$ind" ] || return 1
    s="${_CF_LINES[_CF_FC]%$'\r'}"
    _cf_is_entry "${s:ind}"
}

# _cf_block_end START → _CF_END: the last *content* line belonging to the block
# opened at START, or -1 when it has no children. Blank lines and comments are
# stepped over rather than counted, so a comment between two keys does not end
# the block and a trailing comment is not mistaken for its last line — which is
# what keeps an insertion above someone's `# TODO` instead of below it.
#
# A block-scalar header is the exception, and it has to be: the lines under one
# are a string's contents, so a `#` there is text and a blank line there may be
# part of the value. Stepping over them as if they were comments would leave the
# block's last line in the middle of the scalar, and an insertion would then be
# spliced into a shell script. The whole region is skipped instead.
_cf_block_end() {
    local start="$1" ind i n=${#_CF_LINES[@]} flush=0 s
    _cf_flush_seq "$start" && flush=1
    _cf_indent "${_CF_LINES[start]}"; ind=$_CF_IND
    _CF_END=-1
    for ((i = start + 1; i < n; i++)); do
        if _cf_is_blank "${_CF_LINES[i]}"; then continue; fi
        if _cf_is_comment "${_CF_LINES[i]}"; then continue; fi
        _cf_indent "${_CF_LINES[i]}"
        if [ "$_CF_IND" -lt "$ind" ]; then break; fi
        if [ "$_CF_IND" -eq "$ind" ]; then
            s="${_CF_LINES[i]%$'\r'}"
            [ "$flush" = 1 ] && _cf_is_entry "${s:ind}" || break
        fi
        _CF_END=$i
        if _cf_scalar_header "$i"; then
            _cf_scalar_end "$i"
            _CF_END=$_CF_SEND
            i=$_CF_SEND
        fi
    done
    return 0
}

# _cf_child_indent START → _CF_CI: the indentation this block's children are
# written at, taken from the first one, and _CF_STEP: how much deeper that is
# than the block itself. Anything inserted *under* a child is indented by the
# file's own step rather than by two, so a 4-space compose file gets 4-space
# nesting back. A block with no children yet gets its parent's indent plus two,
# which is what every file kasbah renders uses; a flush sequence its own.
#
# Unlike _cf_block_end this needs no block-scalar rule: it stops at the *first*
# child, and a scalar's header is itself a child line, reached before any of its
# content. tests/check_test.sh case F16 pins that.
_cf_child_indent() {
    local start="$1" ind
    _cf_indent "${_CF_LINES[start]}"; ind=$_CF_IND
    _CF_CI=$((ind + 2))
    _CF_STEP=2
    if _cf_flush_seq "$start"; then
        _CF_CI=$ind; _CF_STEP=0
        return 0
    fi
    _cf_first_child "$start"
    [ "$_CF_FC" -ge 0 ] || return 0
    _cf_indent "${_CF_LINES[_CF_FC]}"
    if [ "$_CF_IND" -gt "$ind" ]; then
        _CF_CI=$_CF_IND
        _CF_STEP=$((_CF_CI - ind))
    fi
    return 0
}

# _cf_locate_child KEY START END IND → _CF_IDX, or -1. Exact indent match, so a
# key of the same name nested deeper (or belonging to the next sibling) cannot
# be picked up by mistake. The quoted spellings are here because a caller only
# asks after yq said the key exists: not finding it has to mean "written in a
# shape this cannot edit", not "written in quotes".
_cf_locate_child() {
    local key="$1" start="$2" end="$3" ind="$4" i s pre
    printf -v pre '%*s' "$ind" ''
    _CF_IDX=-1
    [ "$end" -ge "$start" ] || return 0
    for ((i = start + 1; i <= end; i++)); do
        s="${_CF_LINES[i]%$'\r'}"
        case "$s" in
            "$pre$key:"|"$pre$key:"[[:space:]]*) _CF_IDX=$i; return 0 ;;
            "$pre\"$key\":"|"$pre\"$key\":"[[:space:]]*) _CF_IDX=$i; return 0 ;;
            "$pre'$key':"|"$pre'$key':"[[:space:]]*) _CF_IDX=$i; return 0 ;;
        esac
    done
    return 0
}

# _cf_locate_top KEY → _CF_IDX of a top-level `KEY:` line, or -1. The same three
# spellings _cf_locate_child accepts, so the two cannot disagree about whether a
# key is written in quotes — a compose with `'services':` was being told its
# services are not a top-level block, which is not what is unusual about it.
_cf_locate_top() {
    local key="$1" i n=${#_CF_LINES[@]} s
    _CF_IDX=-1
    for ((i = 0; i < n; i++)); do
        s="${_CF_LINES[i]%$'\r'}"
        case "$s" in
            "$key:"|"$key:"[[:space:]]*) _CF_IDX=$i; return 0 ;;
            "\"$key\":"|"\"$key\":"[[:space:]]*) _CF_IDX=$i; return 0 ;;
            "'$key':"|"'$key':"[[:space:]]*) _CF_IDX=$i; return 0 ;;
        esac
    done
    return 0
}

# _cf_split_value TEXT — TEXT is everything a key line carries after its colon.
# Sets _CF_VAL to the scalar with the blanks around it removed, and _CF_CMT to
# the trailing comment *together with the whitespace written in front of it*, so
# a caller re-emitting them reproduces the original bytes.
#
# Returns 1 when the two cannot be told apart, and a refusal is the only honest
# answer there — the same contract the rest of this file works to. A quoted
# scalar is scanned to its closing quote (`\"` and `''` escapes included) rather
# than split on the first `#`, because `mem_limit: "512m # sized for the box"`
# carries no comment at all and splitting it strands a quote in one. A plain
# scalar ends at a `#` that follows a blank, which is YAML's own rule: `app#1`
# keeps its hash.
_CF_VAL=""
_CF_CMT=""
_cf_split_value() {
    # Two statements: in one, `${#s}` would read the caller's `s`.
    local s="$1"
    local n=${#s} i j k c q lead tail tt
    _CF_VAL=""
    _CF_CMT=""
    lead=0
    while [ "$lead" -lt "$n" ]; do
        case "${s:lead:1}" in ' '|$'\t') lead=$((lead + 1)) ;; *) break ;; esac
    done
    [ "$lead" -lt "$n" ] || return 0
    c="${s:lead:1}"
    # A key whose line carries only a comment has no value on it.
    if [ "$c" = '#' ]; then
        _CF_CMT="$s"
        return 0
    fi
    if [ "$c" = '"' ] || [ "$c" = "'" ]; then
        q="$c"
        i=$((lead + 1))
        while [ "$i" -lt "$n" ]; do
            c="${s:i:1}"
            if [ "$q" = '"' ] && [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
            if [ "$c" = "$q" ]; then
                if [ "$q" = "'" ] && [ "${s:i+1:1}" = "'" ]; then i=$((i + 2)); continue; fi
                break
            fi
            i=$((i + 1))
        done
        # No closing quote on this line: the scalar runs on into lines this
        # cannot see, so there is nothing here safe to rewrite.
        [ "$i" -lt "$n" ] || return 1
        _CF_VAL="${s:lead:i - lead + 1}"
        tail="${s:i + 1}"
        tt="${tail#"${tail%%[![:space:]]*}"}"
        if [ -n "$tt" ]; then
            case "$tt" in '#'*) ;; *) return 1 ;; esac
        fi
        _CF_CMT="$tail"
        return 0
    fi
    i=$lead
    j=$n
    while [ "$i" -lt "$n" ]; do
        if [ "${s:i:1}" = "#" ]; then
            case "${s:i - 1:1}" in
                ' '|$'\t') j=$i; break ;;
            esac
        fi
        i=$((i + 1))
    done
    k=$j
    while [ "$k" -gt "$lead" ]; do
        case "${s:k - 1:1}" in ' '|$'\t') k=$((k - 1)) ;; *) break ;; esac
    done
    _CF_VAL="${s:lead:k - lead}"
    _CF_CMT="${s:k}"
    return 0
}

# _cf_raw_value IDX → _CF_RAW, the scalar written after the key's colon. Empty
# when the key opens a block. A value _cf_split_value refuses is still a value
# as far as "is there one at all" goes, so it comes back whole.
_CF_RAW=""
_cf_raw_value() {
    local s="${_CF_LINES[$1]%$'\r'}" rest
    rest="${s#*:}"
    if _cf_split_value "$rest"; then
        _CF_RAW="$_CF_VAL"
    else
        _CF_RAW="${rest#"${rest%%[![:space:]]*}"}"
    fi
    return 0
}

# True when the key at IDX carries its value on the same line — `logging: {}`,
# `networks: [a, b]`, `restart: no`. A block-opening key has nothing there.
_cf_key_inline() {
    _cf_raw_value "$1"
    [ -n "$_CF_RAW" ]
}

# _cf_set_value IDX NEWVAL — rewrite one scalar in place. Indentation, the key
# as spelled, and any trailing comment all survive byte for byte; quoting
# survives too, so `restart: "no"` becomes `restart: "unless-stopped"` rather
# than losing its quotes.
#
# Returns 1 — a refusal the caller reports — when the line is not a `key: value`
# this can take apart, or when _cf_split_value cannot say where the value ends.
_cf_set_value() {
    local idx="$1" new="$2" s cr="" head rest q=""
    s="${_CF_LINES[idx]}"
    case "$s" in *$'\r') cr=$'\r'; s="${s%$'\r'}" ;; esac
    [[ "$s" =~ ^([[:space:]]*[^[:space:]:]+:)(.*)$ ]] || return 1
    head="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    _cf_split_value "$rest" || return 1
    case "$_CF_VAL" in
        '"'*'"') [ "${#_CF_VAL}" -ge 2 ] && q='"' ;;
        "'"*"'") [ "${#_CF_VAL}" -ge 2 ] && q="'" ;;
    esac
    _CF_REP[idx]="$head $q$new$q$_CF_CMT$cr"
    _CF_HASREP[idx]=1
    return 0
}

# _cf_delete_key IDX — the key line and everything nested under it, including
# trailing comments written at a deeper indent (they describe what is going).
# Comments and blank lines at or above the key's own indent are left where they
# are: they belong to whatever comes next.
#
# A comment sitting immediately *above* the key is left too, even though it
# usually describes it. There is no way to tell that comment apart from a file
# header — a compose file that opens with four lines of prose and then
# `version:` is the ordinary shape, and C05 deleting the header with the key
# would be far worse than one line left describing something that is gone. The
# diff shows it either way.
_cf_delete_key() {
    local idx="$1" ind i n=${#_CF_LINES[@]} last
    _cf_indent "${_CF_LINES[idx]}"; ind=$_CF_IND
    _cf_block_end "$idx"; last=$_CF_END
    [ "$last" -ge "$idx" ] || last=$idx
    for ((i = last + 1; i < n; i++)); do
        if ! _cf_is_comment "${_CF_LINES[i]}"; then break; fi
        _cf_indent "${_CF_LINES[i]}"
        if [ "$_CF_IND" -le "$ind" ]; then break; fi
        last=$i
    done
    for ((i = idx; i <= last; i++)); do _CF_DEL[i]=1; done
    return 0
}

# _cf_yq FILE FILTER → the value, or the empty string on any error. Every rule
# verdict comes through here, so the fix and the rule in lib/check.sh are asking
# the same parser the same question.
_cf_yq() {
    local out
    out="$(yaml_query "$1" "$2" 2>/dev/null || true)"
    case "$out" in null) out="" ;; esac
    printf '%s' "${out%$'\r'}"
    return 0
}

# _cf_has FILE PATH KEY — yq's own answer to "is this key present", which is
# what decides insert versus replace. `has` on a null service is a jq type
# error, and that is a false.
_cf_has() {
    local out
    out="$(yaml_query "$1" "$2 | has(\"$3\")" 2>/dev/null || echo false)"
    [ "${out%$'\r'}" = "true" ]
}

# ----------------------------------------------------------------------------
# The compose planner
# ----------------------------------------------------------------------------
# One pass per service for C01, C02, C03, C08, R01, R02, R03, then the two
# file-level rules C04 and C05. Order matters in exactly one place: C04 asks
# whether anything is on kasbah-net *after* C03's insertions, or the second run
# would find a fix the first one created.

_cf_plan_compose() {
    local f="$1"
    local services svc
    services="$(_cf_yq "$f" '(.services // {}) | keys | .[]')"

    _cf_locate_top services
    local svcs_top=$_CF_IDX svcs_end=-1 svcs_ci=0
    if [ "$svcs_top" -ge 0 ]; then
        _cf_block_end "$svcs_top"; svcs_end=$_CF_END
        _cf_child_indent "$svcs_top"; svcs_ci=$_CF_CI
    fi

    local any_on_hn=0
    local default_hn=0
    [ "$(_cf_yq "$f" '.networks.default.name // ""')" = "kasbah-net" ] && default_hn=1

    local routed_hosts=""
    routed_hosts="$(_traefik_routed_hosts | sort -u)"

    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        if [ "$svcs_top" -lt 0 ]; then
            _cf_left "compose: cannot find the top-level services: key in the file's text — --fix edits block mappings, not a flow-style document"
            break
        fi
        _cf_locate_child "$svc" "$svcs_top" "$svcs_end" "$svcs_ci"
        local s_idx=$_CF_IDX
        if [ "$s_idx" -lt 0 ]; then
            _cf_left "compose: cannot find service '$svc' in the file's text — left untouched"
            continue
        fi
        if _cf_key_inline "$s_idx"; then
            _cf_left "compose: service '$svc' is written inline (${_CF_RAW}) — --fix edits block mappings only"
            continue
        fi
        _cf_block_end "$s_idx";   local s_end=$_CF_END
        _cf_child_indent "$s_idx"; local s_ci=$_CF_CI
        _CF_SVC_STEP=$_CF_STEP
        local s_at=$s_end
        [ "$s_at" -ge 0 ] || s_at=$s_idx
        local pre
        printf -v pre '%*s' "$s_ci" ''

        _cf_c01 "$f" "$svc" "$s_idx" "$s_end" "$s_ci" "$s_at" "$pre"
        _cf_c08 "$f" "$svc" "$s_idx" "$s_end" "$s_ci"

        # C03 first, then the two limits, then logging: the inserted keys come
        # out in that order, which is the order compose files in this repo are
        # written in.
        local joined=0
        if [ "$(_cf_yq "$f" ".services[\"$svc\"].networks | if . == null then [] elif type == \"object\" then keys else . end | any(. == \"kasbah-net\")")" = "true" ]; then
            joined=1
        elif [ "$default_hn" = 1 ] && ! _cf_has "$f" ".services[\"$svc\"]" networks; then
            joined=1
        fi
        [ "$joined" = 1 ] && any_on_hn=1
        local cn routed=0
        cn="$(_cf_yq "$f" ".services[\"$svc\"].container_name // \"\"")"
        if [ -n "$cn" ] && [ -n "$routed_hosts" ] && grep -qxF -- "$cn" <<<"$routed_hosts"; then
            routed=1
        fi
        if [ "$routed" = 1 ] && [ "$joined" = 0 ]; then
            # C04 is asked about the file this fix leaves behind, not the one it
            # read: a service joining kasbah-net here is what makes the network
            # declaration matter, and a C04 planned on the *next* run would mean
            # the first run had not settled.
            if _cf_c03 "$f" "$svc" "$s_idx" "$s_end" "$s_ci" "$s_at" "$pre"; then
                any_on_hn=1
            fi
        fi

        _cf_r01_r02 "$f" "$svc" "$s_idx" "$s_end" "$s_ci" "$s_at" "$pre"
        _cf_c02 "$f" "$svc" "$s_idx" "$s_end" "$s_ci" "$s_at" "$pre"
        _cf_r03 "$f" "$svc" "$s_idx" "$s_end" "$s_ci"
    done <<<"$services"

    _cf_c04 "$f" "$any_on_hn" "$default_hn"
    _cf_c05 "$f"
    return 0
}

# C01 — every service sets a restart policy. `no` (compose's default, written
# out) and a missing key are the same failure with two different repairs.
_cf_c01() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5" s_at="$6" pre="$7"
    local r valid='^(unless-stopped|always|on-failure(:[0-9]+)?)$'
    r="$(_cf_yq "$f" ".services[\"$svc\"].restart // \"\"")"
    [[ "$r" =~ $valid ]] && return 0
    if _cf_has "$f" ".services[\"$svc\"]" restart; then
        _cf_locate_child restart "$s_idx" "$s_end" "$s_ci"
        if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" unless-stopped; then
            _cf_left "C01 $svc — its restart: is written in a shape --fix cannot rewrite"
            return 0
        fi
        _cf_mask services "$svc" restart
        _cf_plan "C01 $svc — restart: ${r:-(empty)} → unless-stopped"
        return 0
    fi
    _cf_insert_after "$s_at" "${pre}restart: unless-stopped"
    _cf_set '"unless-stopped"' services "$svc" restart
    _cf_plan "C01 $svc — add restart: unless-stopped"
    return 0
}

# C02 — json-file with rotation. Repaired part by part rather than by replacing
# the block, so a comment inside someone's logging: survives the fix to it.
_cf_c02() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5" s_at="$6" pre="$7"
    local drv ms mf
    drv="$(_cf_yq "$f" ".services[\"$svc\"].logging.driver // \"\"")"
    ms="$(_cf_yq  "$f" ".services[\"$svc\"].logging.options[\"max-size\"] // \"\"")"
    mf="$(_cf_yq  "$f" ".services[\"$svc\"].logging.options[\"max-file\"] // \"\"")"
    if [ "$drv" = "json-file" ] && [ -n "$ms" ] && [ -n "$mf" ]; then return 0; fi

    if ! _cf_has "$f" ".services[\"$svc\"]" logging; then
        local p2 p4
        printf -v p2 '%*s' $((s_ci + _CF_SVC_STEP)) ''
        printf -v p4 '%*s' $((s_ci + 2 * _CF_SVC_STEP)) ''
        _cf_insert_after "$s_at" "${pre}logging:
${p2}driver: json-file
${p2}options:
${p4}max-size: \"10m\"
${p4}max-file: \"3\""
        _cf_set '{"driver":"json-file","options":{"max-size":"10m","max-file":"3"}}' services "$svc" logging
        _cf_plan "C02 $svc — add json-file logging with max-size 10m, max-file 3"
        return 0
    fi

    _cf_locate_child logging "$s_idx" "$s_end" "$s_ci"
    local l_idx=$_CF_IDX
    if [ "$l_idx" -lt 0 ] || _cf_key_inline "$l_idx"; then
        _cf_left "C02 $svc — its logging: is written in a shape --fix cannot edit; set driver json-file with max-size and max-file by hand"
        return 0
    fi
    _cf_block_end "$l_idx";    local l_end=$_CF_END
    _cf_child_indent "$l_idx"; local l_ci=$_CF_CI l_step=$_CF_STEP
    local l_at=$l_end
    [ "$l_at" -ge 0 ] || l_at=$l_idx
    local lpre
    printf -v lpre '%*s' "$l_ci" ''

    if [ "$drv" != "json-file" ]; then
        if _cf_has "$f" ".services[\"$svc\"].logging" driver; then
            _cf_locate_child driver "$l_idx" "$l_end" "$l_ci"
            if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" json-file; then
                _cf_left "C02 $svc — its logging.driver is written in a shape --fix cannot rewrite"
                return 0
            fi
            _cf_mask services "$svc" logging driver
            _cf_plan "C02 $svc — logging.driver: ${drv:-(empty)} → json-file"
        else
            _cf_insert_after "$l_at" "${lpre}driver: json-file"
            _cf_set '"json-file"' services "$svc" logging driver
            _cf_plan "C02 $svc — add logging.driver: json-file"
        fi
    fi

    [ -n "$ms" ] && [ -n "$mf" ] && return 0

    if ! _cf_has "$f" ".services[\"$svc\"].logging" options; then
        local o2
        printf -v o2 '%*s' $((l_ci + l_step)) ''
        _cf_insert_after "$l_at" "${lpre}options:
${o2}max-size: \"10m\"
${o2}max-file: \"3\""
        _cf_set '{"max-size":"10m","max-file":"3"}' services "$svc" logging options
        _cf_plan "C02 $svc — add logging.options max-size 10m, max-file 3"
        return 0
    fi

    _cf_locate_child options "$l_idx" "$l_end" "$l_ci"
    local o_idx=$_CF_IDX
    if [ "$o_idx" -lt 0 ] || _cf_key_inline "$o_idx"; then
        _cf_left "C02 $svc — its logging.options is written in a shape --fix cannot edit; add max-size and max-file by hand"
        return 0
    fi
    _cf_block_end "$o_idx";    local o_end=$_CF_END
    _cf_child_indent "$o_idx"; local o_ci=$_CF_CI
    local o_at=$o_end
    [ "$o_at" -ge 0 ] || o_at=$o_idx
    local opre
    printf -v opre '%*s' "$o_ci" ''
    local k v
    for k in max-size max-file; do
        v="$ms"; [ "$k" = max-file ] && v="$mf"
        [ -n "$v" ] && continue
        if _cf_has "$f" ".services[\"$svc\"].logging.options" "$k"; then
            _cf_locate_child "$k" "$o_idx" "$o_end" "$o_ci"
            local nv='"10m"'; [ "$k" = max-file ] && nv='"3"'
            if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" "${nv//\"/}"; then
                _cf_left "C02 $svc — its logging.options.$k is written in a shape --fix cannot rewrite"
                continue
            fi
            _cf_mask services "$svc" logging options "$k"
            _cf_plan "C02 $svc — logging.options.$k → ${nv//\"/}"
        else
            if [ "$k" = max-size ]; then
                _cf_insert_after "$o_at" "${opre}max-size: \"10m\""
                _cf_set '"10m"' services "$svc" logging options max-size
                _cf_plan "C02 $svc — add logging.options.max-size: \"10m\""
            else
                _cf_insert_after "$o_at" "${opre}max-file: \"3\""
                _cf_set '"3"' services "$svc" logging options max-file
                _cf_plan "C02 $svc — add logging.options.max-file: \"3\""
            fi
        fi
    done
    return 0
}

# C03 — a routed service joins kasbah-net. Only ever *adds* a membership: when
# the service declares no networks: at all it is on compose's implicit default,
# and an explicit list naming only kasbah-net would take it off that network
# without saying so, which is the topology guess C07 is unfixable for. `default`
# is therefore spelled out alongside, so the service keeps every network it had.
# Returns 0 only when an edit was planned.
_cf_c03() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5" s_at="$6" pre="$7"
    local p2
    printf -v p2 '%*s' $((s_ci + _CF_SVC_STEP)) ''

    if ! _cf_has "$f" ".services[\"$svc\"]" networks; then
        _cf_insert_after "$s_at" "${pre}networks:
${p2}- default
${p2}- kasbah-net"
        _cf_app '"default"' services "$svc" networks
        _cf_app '"kasbah-net"' services "$svc" networks
        _cf_plan "C03 $svc — add networks: [default, kasbah-net] (default spelled out so the service keeps the network it had implicitly)"
        return 0
    fi

    _cf_locate_child networks "$s_idx" "$s_end" "$s_ci"
    local n_idx=$_CF_IDX
    if [ "$n_idx" -lt 0 ]; then
        _cf_left "C03 $svc — cannot find its networks: in the file's text"
        return 1
    fi

    if _cf_key_inline "$n_idx"; then
        # A flow sequence gets one more member; a flow mapping is left alone —
        # its members carry aliases and options this would have to invent.
        local raw="$_CF_RAW" cr="" line
        case "$raw" in
            '['*']')
                line="${_CF_LINES[n_idx]}"
                case "$line" in *$'\r') cr=$'\r'; line="${line%$'\r'}" ;; esac
                [[ "$line" =~ ^(.*\[)([^]]*)(\].*)$ ]] || {
                    _cf_left "C03 $svc — its networks: list spans more than one line; add kasbah-net by hand"
                    return 1
                }
                # All three captures first: the next [[ =~ ]] replaces
                # BASH_REMATCH, and the tail would come back as the head.
                local lhead="${BASH_REMATCH[1]}" body="${BASH_REMATCH[2]}"
                local ltail="${BASH_REMATCH[3]}" sep=", "
                [[ "$body" =~ ^[[:space:]]*$ ]] && sep=""
                _CF_REP[n_idx]="${lhead}${body}${sep}kasbah-net${ltail}$cr"
                _CF_HASREP[n_idx]=1
                _cf_app '"kasbah-net"' services "$svc" networks
                _cf_plan "C03 $svc — add kasbah-net to its networks list"
                return 0
                ;;
            *)
                _cf_left "C03 $svc — its networks: is written inline as $raw; add kasbah-net by hand"
                return 1
                ;;
        esac
    fi

    _cf_block_end "$n_idx";    local n_end=$_CF_END
    _cf_child_indent "$n_idx"; local n_ci=$_CF_CI
    if [ "$n_end" -lt 0 ]; then
        # `networks:` with nothing under it — same reasoning as the absent key.
        _cf_insert_after "$n_idx" "${p2}- default
${p2}- kasbah-net"
        _cf_app '"default"' services "$svc" networks
        _cf_app '"kasbah-net"' services "$svc" networks
        _cf_plan "C03 $svc — fill its empty networks: with default and kasbah-net"
        return 0
    fi
    local npre
    printf -v npre '%*s' "$n_ci" ''
    local kind
    kind="$(_cf_yq "$f" ".services[\"$svc\"].networks | type")"
    if [ "$kind" = "object" ]; then
        _cf_insert_after "$n_end" "${npre}kasbah-net:"
        _cf_set null services "$svc" networks kasbah-net
        _cf_plan "C03 $svc — add kasbah-net to its networks mapping"
    else
        _cf_insert_after "$n_end" "${npre}- kasbah-net"
        _cf_app '"kasbah-net"' services "$svc" networks
        _cf_plan "C03 $svc — add kasbah-net to its networks list"
    fi
    return 0
}

# C04 — kasbah-net is external. Only asked when something is on it, which is the
# rule's own condition, and never under the banned default-alias shape: setting
# external: true on the default network there would entrench the thing C07 is
# failing on.
_cf_c04() {
    local f="$1" any_on_hn="$2" default_hn="$3"
    [ "$any_on_hn" = 1 ] || return 0
    if [ "$default_hn" = 1 ]; then
        local dext
        dext="$(_cf_yq "$f" '.networks.default.external // false')"
        [ "$dext" = "true" ] && return 0
        _cf_left "C04 — the default network aliases kasbah-net (C07). Making it external: true would entrench that shape; join kasbah-net per routed service instead"
        return 0
    fi
    local ext
    ext="$(_cf_yq "$f" '.networks["kasbah-net"].external // false')"
    [ "$ext" = "true" ] && return 0

    _cf_locate_top networks
    local t_idx=$_CF_IDX
    if [ "$t_idx" -lt 0 ]; then
        local n=${#_CF_LINES[@]}
        [ "$n" -gt 0 ] || { _cf_left "C04 — compose.prod.yml is empty"; return 0; }
        # A whole block appended at the end of the file, indented by the step
        # `services:` uses — there is no networks: block to take one from, and a
        # 4-space file should not gain a 2-space corner.
        local step=2 a1 a2
        _cf_locate_top services
        if [ "$_CF_IDX" -ge 0 ]; then
            _cf_child_indent "$_CF_IDX"
            step=$_CF_STEP
        fi
        printf -v a1 '%*s' "$step" ''
        printf -v a2 '%*s' $((step * 2)) ''
        _cf_insert_after $((n - 1)) "
networks:
${a1}kasbah-net:
${a2}external: true"
        _cf_set '{"external":true}' networks kasbah-net
        _cf_plan "C04 — add a top-level networks: with kasbah-net external: true"
        return 0
    fi
    if _cf_key_inline "$t_idx"; then
        _cf_left "C04 — the top-level networks: is written inline; declare kasbah-net external: true by hand"
        return 0
    fi
    _cf_block_end "$t_idx";    local t_end=$_CF_END
    _cf_child_indent "$t_idx"; local t_ci=$_CF_CI t_step=$_CF_STEP
    local tpre
    printf -v tpre '%*s' "$t_ci" ''
    if ! _cf_has "$f" '.networks' kasbah-net; then
        local at=$t_end
        [ "$at" -ge 0 ] || at=$t_idx
        local t2
        printf -v t2 '%*s' $((t_ci + t_step)) ''
        _cf_insert_after "$at" "${tpre}kasbah-net:
${t2}external: true"
        _cf_set '{"external":true}' networks kasbah-net
        _cf_plan "C04 — declare kasbah-net external: true"
        return 0
    fi
    _cf_locate_child kasbah-net "$t_idx" "$t_end" "$t_ci"
    local k_idx=$_CF_IDX
    if [ "$k_idx" -lt 0 ]; then
        _cf_left "C04 — cannot find the kasbah-net network in the file's text"
        return 0
    fi
    if _cf_key_inline "$k_idx"; then
        if [ "$_CF_RAW" = "{}" ]; then
            if _cf_set_value "$k_idx" "{external: true}"; then
                _cf_set '{"external":true}' networks kasbah-net
                _cf_plan "C04 — kasbah-net: {} → {external: true}"
                return 0
            fi
        fi
        _cf_left "C04 — kasbah-net is declared inline as $_CF_RAW; set external: true by hand"
        return 0
    fi
    _cf_block_end "$k_idx";    local k_end=$_CF_END
    _cf_child_indent "$k_idx"; local k_ci=$_CF_CI
    if _cf_has "$f" '.networks["kasbah-net"]' external; then
        _cf_locate_child external "$k_idx" "$k_end" "$k_ci"
        if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" true; then
            _cf_left "C04 — kasbah-net's external: is written in a shape --fix cannot rewrite"
            return 0
        fi
        _cf_mask networks kasbah-net external
        _cf_plan "C04 — kasbah-net external: $ext → true"
        return 0
    fi
    local at=$k_end
    [ "$at" -ge 0 ] || at=$k_idx
    local kpre
    printf -v kpre '%*s' "$k_ci" ''
    _cf_insert_after "$at" "${kpre}external: true"
    _cf_set true networks kasbah-net external
    _cf_plan "C04 — add external: true to kasbah-net"
    return 0
}

# C05 — the deprecated top-level version:. Deleted, and nothing around it is
# touched: a comment above it was the author's and may still say something.
_cf_c05() {
    local f="$1" v
    v="$(_cf_yq "$f" '.version // ""')"
    [ -n "$v" ] || return 0
    _cf_locate_top version
    if [ "$_CF_IDX" -lt 0 ]; then
        _cf_left "C05 — cannot find the top-level version: in the file's text"
        return 0
    fi
    _cf_delete_key "$_CF_IDX"
    _cf_del version
    _cf_plan "C05 — remove the deprecated top-level version: $v"
    return 0
}

# C08 — a built service's image is the tag deploy moves. compliance.md calls
# this "a mechanical tag rewrite", and that is exactly its scope: a service that
# names no image at all is left alone, because the image name is not something
# kasbah can derive from anything in the file.
_cf_c08() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5"
    _cf_has "$f" ".services[\"$svc\"]" build || return 0
    local img base
    img="$(_cf_yq "$f" ".services[\"$svc\"].image // \"\"")"
    if [ -z "$img" ]; then
        _cf_left "C08 $svc — builds an image but names no image:, and kasbah will not invent one. Add 'image: <name>:current'"
        return 0
    fi
    case "$img" in *:current) return 0 ;; esac
    case "$img" in *@*)
        _cf_left "C08 $svc — its image: is pinned by digest ($img); retag it <name>:current by hand"
        return 0
        ;;
    esac
    image_base "$img" base
    _cf_locate_child image "$s_idx" "$s_end" "$s_ci"
    if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" "$base:current"; then
        _cf_left "C08 $svc — its image: is written in a shape --fix cannot rewrite"
        return 0
    fi
    _cf_mask services "$svc" image
    _cf_plan "C08 $svc — image: $img → $base:current"
    return 0
}

# R01/R02 — the limits, as references and never as literals, so they scale with
# whichever host the project lands on.
_cf_r01_r02() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5" s_at="$6" pre="$7"
    local key want cur rule
    for key in cpus mem_limit; do
        if [ "$key" = cpus ]; then want='${KASBAH_CPU_LIMIT}'; rule=R01
        else                       want='${KASBAH_MEM_LIMIT}'; rule=R02; fi
        cur="$(_cf_yq "$f" ".services[\"$svc\"].$key // \"\"")"
        [ "$cur" = "$want" ] && continue
        if _cf_has "$f" ".services[\"$svc\"]" "$key"; then
            _cf_locate_child "$key" "$s_idx" "$s_end" "$s_ci"
            if [ "$_CF_IDX" -lt 0 ] || ! _cf_set_value "$_CF_IDX" "$want"; then
                _cf_left "$rule $svc — its $key: is written in a shape --fix cannot rewrite"
                continue
            fi
            _cf_mask services "$svc" "$key"
            _cf_plan "$rule $svc — $key: ${cur:-(empty)} → $want"
        else
            _cf_insert_after "$s_at" "${pre}$key: $want"
            _cf_set "\"$want\"" services "$svc" "$key"
            _cf_plan "$rule $svc — add $key: $want"
        fi
    done
    return 0
}

# R03 — reservations are banned. Removing deploy.resources.reservations can
# leave `resources:` and then `deploy:` holding nothing, so each empty parent
# goes with it; a `deploy:` carrying anything else, or `resources:` carrying
# limits, stays exactly as it is.
_cf_r03() {
    local f="$1" svc="$2" s_idx="$3" s_end="$4" s_ci="$5"

    local memr
    memr="$(_cf_yq "$f" ".services[\"$svc\"].mem_reservation // \"\"")"
    if [ -n "$memr" ]; then
        _cf_locate_child mem_reservation "$s_idx" "$s_end" "$s_ci"
        if [ "$_CF_IDX" -lt 0 ]; then
            _cf_left "R03 $svc — cannot find its mem_reservation: in the file's text"
        else
            _cf_delete_key "$_CF_IDX"
            _cf_del services "$svc" mem_reservation
            _cf_plan "R03 $svc — remove mem_reservation"
        fi
    fi

    local resv
    resv="$(_cf_yq "$f" ".services[\"$svc\"].deploy.resources.reservations // \"\"")"
    [ -n "$resv" ] || return 0

    _cf_locate_child deploy "$s_idx" "$s_end" "$s_ci"
    local d_idx=$_CF_IDX
    if [ "$d_idx" -lt 0 ] || _cf_key_inline "$d_idx"; then
        _cf_left "R03 $svc — its deploy: is written in a shape --fix cannot edit; remove the reservations by hand"
        return 0
    fi
    _cf_block_end "$d_idx";    local d_end=$_CF_END
    _cf_child_indent "$d_idx"; local d_ci=$_CF_CI
    _cf_locate_child resources "$d_idx" "$d_end" "$d_ci"
    local rs_idx=$_CF_IDX
    if [ "$rs_idx" -lt 0 ] || _cf_key_inline "$rs_idx"; then
        _cf_left "R03 $svc — its deploy.resources is written in a shape --fix cannot edit; remove the reservations by hand"
        return 0
    fi
    _cf_block_end "$rs_idx";    local rs_end=$_CF_END
    _cf_child_indent "$rs_idx"; local rs_ci=$_CF_CI
    _cf_locate_child reservations "$rs_idx" "$rs_end" "$rs_ci"
    local rv_idx=$_CF_IDX
    if [ "$rv_idx" -lt 0 ]; then
        _cf_left "R03 $svc — cannot find deploy.resources.reservations in the file's text"
        return 0
    fi

    local res_keys dep_keys target="deploy.resources.reservations"
    res_keys="$(_cf_yq "$f" ".services[\"$svc\"].deploy.resources | keys | length")"
    dep_keys="$(_cf_yq "$f" ".services[\"$svc\"].deploy | keys | length")"
    if [ "$res_keys" = "1" ] && [ "$dep_keys" = "1" ]; then
        _cf_delete_key "$d_idx"
        _cf_del services "$svc" deploy
        target="deploy (it held nothing else)"
    elif [ "$res_keys" = "1" ]; then
        _cf_delete_key "$rs_idx"
        _cf_del services "$svc" deploy resources
        target="deploy.resources (it held nothing else)"
    else
        _cf_delete_key "$rv_idx"
        _cf_del services "$svc" deploy resources reservations
    fi
    _cf_plan "R03 $svc — remove $target"
    return 0
}

# ----------------------------------------------------------------------------
# The manifest planner — one rule, and only when the key is absent
# ----------------------------------------------------------------------------
# docs/compliance.md: "Adding kasbah_version to manifest if missing". A key that
# is present and says something else is the author's statement about which
# kasbah the project was written for, and is not this command's to overwrite.

_cf_plan_manifest() {
    local f="$1"
    _cf_has "$f" '.' kasbah_version && return 0
    _cf_locate_top schema
    if [ "$_CF_IDX" -lt 0 ]; then
        _cf_left "kasbah.yml — cannot find the schema: line to write kasbah_version after; add 'kasbah_version: $KASBAH_VERSION' by hand"
        return 0
    fi
    _cf_insert_after "$_CF_IDX" "kasbah_version: $KASBAH_VERSION"
    _cf_mask kasbah_version
    _cf_plan "kasbah.yml — add kasbah_version: $KASBAH_VERSION"
    return 0
}

# ----------------------------------------------------------------------------
# Staging, verifying, showing and writing
# ----------------------------------------------------------------------------

# _cf_verify_compose ORIG NEW — the shapes that must not change. An edit that
# lands at the wrong indentation can still parse; what it cannot do is leave the
# same top-level keys and the same service names. `version` is the one key --fix
# is allowed to remove.
_cf_verify_compose() {
    local ka kb sa sb k
    ka="$(yaml_query "$1" 'keys | .[]' 2>/dev/null || true)"
    kb="$(yaml_query "$2" 'keys | .[]' 2>/dev/null || true)"
    # `version` is the one key --fix removes (C05) and `networks` the one it
    # adds (C04). Anything else appearing or disappearing at the top level is an
    # edit that landed at the wrong indentation.
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        grep -qxF -- "$k" <<<"$kb" && continue
        [ "$k" = version ] || return 1
    done <<<"$ka"
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        grep -qxF -- "$k" <<<"$ka" && continue
        [ "$k" = networks ] || return 1
    done <<<"$kb"
    sa="$(yaml_query "$1" '(.services // {}) | keys | .[]' 2>/dev/null || true)"
    sb="$(yaml_query "$2" '(.services // {}) | keys | .[]' 2>/dev/null || true)"
    [ "$sa" = "$sb" ] || return 1
    return 0
}

# _cf_verify_manifest ORIG NEW — the same idea. kasbah_version is ignored on
# both sides, since it is the only key this file's planner touches; every other
# top-level key has to be there before and after.
_cf_verify_manifest() {
    local ka kb
    ka="$(yaml_query "$1" 'keys | .[]' 2>/dev/null || true)"
    kb="$(yaml_query "$2" 'keys | .[]' 2>/dev/null || true)"
    kb="$(grep -vx kasbah_version <<<"$kb" || true)"
    ka="$(grep -vx kasbah_version <<<"$ka" || true)"
    [ "$ka" = "$kb" ] || return 1
    return 0
}

# _cf_guard ORIG NEW — each document of NEW is ORIG's with exactly the planned
# edits applied, masked paths aside on both: a text edit that landed where the
# scanner misread the file changes some other value, and is refused. One jq
# over the two cached conversions; on stdin, which has no argument-size limit.
_cf_guard() {
    local a="${_KASBAH_YAML_JSON[$1]-}" b="${_KASBAH_YAML_JSON[$2]-}"
    printf '[%s]\n[%s]\n' "${a//$'\n'/,}" "${b//$'\n'/,}" \
        | jq -e -n "input as \$a | input as \$b
            | (\$a | map(. $_CF_OPS $_CF_MASK)) == (\$b | map(. $_CF_MASK))" >/dev/null 2>&1
}

# _cf_stage FILE PLANNER VERIFIER
#   0 — edits staged, _CF_TMP holds the candidate and _CF_PLAN_TEXT the lines
#       to show for it
#   1 — nothing to fix
#   2 — refused; the reason is already on stderr or in _CF_LEFT
#
# The candidate is written before it is shown, because three things have to be
# true of it and only a file can be asked: it parses, it keeps the same keys,
# and re-planning it finds nothing left to do. That last check is idempotency
# proved on this run rather than assumed — a fix that would grow the file on
# every invocation is refused here instead of shipping.
_cf_stage() {
    local f="$1" planner="$2" verifier="$3"
    _CF_TMP=""
    _CF_PLAN_TEXT=""

    if ! _cf_read_file "$f"; then
        err "check --fix: cannot read $f — it was left alone"
        _cf_left "$f — could not be read; it was left exactly as it was"
        return 2
    fi
    _cf_reset_edits
    _CF_COLLECT=1
    "$planner" "$f"
    [ "${#_CF_PLAN[@]}" -gt 0 ] || return 1
    _CF_PLAN_TEXT="$(printf '    %s\n' "${_CF_PLAN[@]}")"

    # Beside the file, so the rename below is atomic. This lives in the tree
    # `deploy` rsyncs, so every path out of here removes it; a killed run can
    # leave one `.kasbah-fix.<pid>` behind, the same caveat lib/env.sh carries.
    # Beside what FILE resolves to, so the rename that commits it is atomic
    # even through a symlink.
    local base="$f"
    if [ -L "$f" ]; then
        base="$(readlink -f -- "$f")" || {
            err "check --fix: cannot resolve the symlink $f — it was left alone"
            _cf_left "$f — its symlink could not be resolved; it was left exactly as it was"
            return 2
        }
    fi
    local tmp="$base.kasbah-fix.$$"
    rm -f "$tmp" 2>/dev/null || true
    _CF_TEMPS+=("$tmp")
    if ! (umask 077; : > "$tmp") 2>/dev/null; then
        err "check --fix: cannot write beside $f — nothing was changed"
        _cf_left "$f — nothing could be written beside it, so it was left exactly as it was"
        return 2
    fi
    # Written first, mode copied after. `chmod --reference` on a read-only
    # target makes the candidate read-only too, and the redirection that then
    # fails is reported by the shell *before* `2>/dev/null` is applied to the
    # command — a raw `Permission denied` ahead of the tidy message.
    if ! _cf_render 2>/dev/null > "$tmp"; then
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: cannot write beside $f — nothing was changed"
        _cf_left "$f — nothing could be written beside it, so it was left exactly as it was"
        return 2
    fi
    chmod --reference="$f" "$tmp" 2>/dev/null || true

    # Converting the candidate is the parse check, and it caches the JSON the
    # verifier and the re-plan two steps down are about to query.
    if ! yaml_load "$tmp"; then
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: the edited $f would not parse as YAML — nothing was written"
        _cf_left "$f — the edited file would not have parsed as YAML; it was left exactly as it was"
        return 2
    fi
    if ! "$verifier" "$f" "$tmp"; then
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: the edited $f no longer declares the same keys — nothing was written"
        _cf_left "$f — the edited file no longer declared the same keys; it was left exactly as it was"
        return 2
    fi

    if ! _cf_guard "$f" "$tmp"; then
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: the edited $f would change values the fix did not plan to — nothing was written"
        _cf_left "$f — the edit would have changed more than the fix planned; it was left exactly as it was"
        return 2
    fi

    _cf_read_file "$tmp" || return 2
    _cf_reset_edits
    _CF_COLLECT=0
    "$planner" "$tmp"
    _CF_COLLECT=1
    if [ "${#_CF_PLAN[@]}" -ne 0 ]; then
        local leftover="${_CF_PLAN[*]}"
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: the fix to $f did not settle — a second run would change it again ($leftover). Nothing was written"
        _cf_left "$f — the fix did not settle, so a second run would change it again; it was left exactly as it was"
        return 2
    fi

    _CF_TMP="$tmp"
    return 0
}

# _cf_show_diff FILE TMP — unified, with the real path on both sides so the
# temp name never appears. `--label` is GNU; a diff without it still gets to
# print, with its own header.
_cf_show_diff() {
    local f="$1" tmp="$2" rc=0
    diff -u --label "a/$f" --label "b/$f" -- "$f" "$tmp" || rc=$?
    if [ "$rc" -gt 1 ]; then
        rc=0
        diff -u -- "$f" "$tmp" || rc=$?
    fi
    [ "$rc" -le 1 ] || return 1
    return 0
}

# _cf_commit FILE TMP — rename, never copy, so a reader sees the whole old file
# or the whole new one. A symlinked target is written through: renaming over the
# link would leave a regular file in its place and orphan what it pointed at.
_cf_commit() {
    local f="$1" tmp="$2" target="$1"
    if [ -L "$f" ]; then
        target="$(readlink -f -- "$f")" || {
            rm -f "$tmp"; yaml_forget "$tmp"
            err "check --fix: cannot resolve the symlink $f — it was left alone"
            return 1
        }
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"; yaml_forget "$tmp"
        err "check --fix: could not replace $f"
        return 1
    fi
    # The bytes at $f are now the candidate's, and nothing watches mtimes
    # (lib/common.sh → yaml_load), so any conversion cached for these paths is
    # now a lie about a file this function changed. The writer says so, rather
    # than leaving it to whoever reads next: cmd_check does reload both files
    # after the fix, but that is the report phase drawing its own boundary and
    # not a guarantee this function may lean on.
    yaml_forget "$f"
    yaml_forget "$target"
    yaml_forget "$tmp"
    return 0
}

# Removes any candidate still on disk. Idempotent, and safe to run when every
# candidate has already been renamed into place: those paths no longer exist.
_cf_cleanup() {
    local t
    for t in ${_CF_TEMPS[@]+"${_CF_TEMPS[@]}"}; do
        rm -f "$t" 2>/dev/null || true
        yaml_forget "$t"
    done
    return 0
}

# check_fix_run YES_GIVEN — the whole of `--fix`, run before the report so the
# report that follows describes the project as it now is.
#
# YES_GIVEN is "yes" when `--yes` was passed and empty otherwise: the diff is a
# decision point, so an unset flag means *ask*, never "no" (docs/overview.md →
# Interactivity). Without a terminal and without `--yes`, prompt_confirm ends
# the run naming the flag rather than deciding on the operator's behalf.
check_fix_run() {
    local yes_given="${1:-}"
    command -v diff >/dev/null \
        || die "check --fix: diff is required (install diffutils and retry)"

    _CF_LEFT=()
    _CF_COLLECT=1
    _CF_TEMPS=()
    # Installed before the first candidate exists, and — because cmd_check runs
    # the fix before it connects — before any `--server` run reaches
    # check_server_connect, whose own EXIT trap chains onto whatever is already
    # there (lib/ssh.sh). Moving this call after the connect would drop that one.
    trap '_cf_cleanup' EXIT

    local -a files=() tmps=() plans=()
    local rc=0

    # C03's planner asks `_traefik_routed_hosts` which service is routed, and it
    # asks from inside a `$(…)`. A conversion made there dies with the subshell
    # (lib/common.sh → yaml_load), so the fragment is converted here instead —
    # once, rather than once for the plan and again for the idempotency re-plan.
    # `--fix` never edits it; cmd_check converts it again for the report, which
    # is that phase's own boundary and not this one's business.
    if [ -f traefik-dynamic.yml ]; then yaml_load traefik-dynamic.yml || true; fi

    if [ -f compose.prod.yml ]; then
        if ! yaml_load compose.prod.yml; then
            _cf_left "compose.prod.yml does not parse as YAML — --fix will not pattern-match its way through a file it cannot read"
        else
            rc=0
            _cf_stage compose.prod.yml _cf_plan_compose _cf_verify_compose || rc=$?
            if [ "$rc" = 0 ]; then
                files+=(compose.prod.yml); tmps+=("$_CF_TMP"); plans+=("$_CF_PLAN_TEXT")
            fi
        fi
    fi

    rc=0
    _cf_stage "$KASBAH_MANIFEST_FILE" _cf_plan_manifest _cf_verify_manifest || rc=$?
    if [ "$rc" = 0 ]; then
        files+=("$KASBAH_MANIFEST_FILE"); tmps+=("$_CF_TMP"); plans+=("$_CF_PLAN_TEXT")
    fi

    echo "Fix:"
    # Only when there was genuinely nothing to do. A run that staged nothing
    # *because it refused something* has its reasons under "Left alone:" below,
    # and printing "nothing --fix can change" over them says the opposite.
    if [ "${#files[@]}" -eq 0 ] && [ "${#_CF_LEFT[@]}" -eq 0 ]; then
        echo "  nothing --fix can change"
    fi
    local i
    for ((i = 0; i < ${#files[@]}; i++)); do
        printf '  %s\n' "${files[i]}"
        printf '%s\n' "${plans[i]}"
    done
    if [ "${#_CF_LEFT[@]}" -gt 0 ]; then
        echo "  Left alone:"
        printf '    %s\n' "${_CF_LEFT[@]}"
    fi
    echo "  --fix applies C01–C05, C08, R01–R03 and the kasbah_version backfill, to"
    echo "  compose.prod.yml and kasbah.yml only. C07, C09, every Traefik rule, Hooks"
    echo "  and Mail claims are by hand — see docs/compliance.md → \`--fix\` behavior."

    if [ "${#files[@]}" -eq 0 ]; then
        echo
        return 0
    fi

    echo
    for ((i = 0; i < ${#files[@]}; i++)); do
        _cf_show_diff "${files[i]}" "${tmps[i]}" || true
    done
    echo

    if ! prompt_confirm yes "Apply these edits?" "$yes_given"; then
        for ((i = 0; i < ${#files[@]}; i++)); do rm -f "${tmps[i]}"; yaml_forget "${tmps[i]}"; done
        echo "  nothing was written"
        echo
        return 0
    fi

    for ((i = 0; i < ${#files[@]}; i++)); do
        if _cf_commit "${files[i]}" "${tmps[i]}"; then
            printf '  wrote %s\n' "${files[i]}"
        fi
    done
    echo
    return 0
}
