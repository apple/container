#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# --- usage ---
# Builds the OCX package ocx.sh/extra-code/container from the fork revision in ocx/source-revision.
#
# Usage:
#   ocx-package.sh check TAG          Check TAG (ocx-X.Y.Z_NN) against ocx/source-revision, the branches
#                                     and the apple/container tags, which it fetches.
#   ocx-package.sh build SRC ROOT     Run the release build in SRC and install it into ROOT without sudo.
#   ocx-package.sh verify ROOT        Check signatures, entitlements, links and modes under ROOT.
#   ocx-package.sh create ROOT TAG    Run ocx package create into out/container-X.Y.Z_NN.tar.xz.
#   ocx-package.sh --self-test        Offline checks of every step.
#   ocx-package.sh -h | --help        Print this usage.
#
# Environment:
#   OCX_PACKAGE_BASE_REF     The ref the source revision must be on (default origin/parbake).
#   OCX_PACKAGE_BRANCH_REF   The ref HEAD must be on (default origin/ocx-package).
#
# Exit codes: 0 success; 1 a failed step; 2 a usage error.
# --- end usage ---
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"
METADATA="${REPO_ROOT}/ocx/metadata.json"

TAG_RE='^ocx-([0-9]+\.[0-9]+\.[0-9]+)_[0-9]{2}$'
PLUGINS_REL="libexec/container/plugins"
REQUIRED_PLUGINS=(container-runtime-linux container-network-vmnet container-core-images)
SUDO_SCRIPTS=(bin/update-container.sh bin/uninstall-container.sh)
ENTITLEMENT="com.apple.security.virtualization"
# The binaries that must carry the virtualization entitlement. No other binary carries any.
ENTITLED="container-runtime-linux container-network-vmnet"
# The Mach-O files verify requires, each at its install path.
REQUIRED_BINARIES=(bin/container bin/container-apiserver)
for _plugin in "${REQUIRED_PLUGINS[@]}"; do
    REQUIRED_BINARIES+=("${PLUGINS_REL}/${_plugin}/bin/${_plugin}")
done
unset _plugin

# check reads apple/container's tags from here. No environment variable can change it.
UPSTREAM_URL="https://github.com/apple/container"
UPSTREAM_FILE_PROTOCOL=never

PROBLEMS=0

die() {
    printf 'ocx-package.sh: %s\n' "$*" >&2
    return 1
}

usage_error() {
    printf 'ocx-package.sh: %s\n' "$*" >&2
    printf 'usage: ocx-package.sh check TAG | build SRC ROOT | verify ROOT | create ROOT TAG | --self-test | -h\n' >&2
    return 2
}

# tag_version TAG: prints X.Y.Z_NN for a well-formed TAG.
tag_version() {
    [[ "$1" =~ ${TAG_RE} ]] || return 1
    printf '%s' "${1#ocx-}"
}

valid_tag() {
    [[ "$1" =~ ${TAG_RE} ]] || usage_error "tag \"$1\" does not match ${TAG_RE}"
}

# abs_path PATH: the absolute form with symlinks resolved in the existing part. A ".." component is
# refused, because the rest of the path may not exist yet.
abs_path() {
    local path="$1" rest="" part
    [[ -n "${path}" ]] || return 1
    [[ "${path}" == /* ]] || path="$(pwd)/${path}"
    case "/${path}/" in
        */../*) return 1 ;;
    esac
    while [[ ! -d "${path}" && "${path}" != / ]]; do
        part="$(basename "${path}")"
        rest="/${part}${rest}"
        path="$(dirname "${path}")"
    done
    path="$(cd -P "${path}" && pwd)"
    [[ "${path}" == / ]] && path=""
    printf '%s%s' "${path}" "${rest}"
}

# safe_rm BASE PATH: rm -rf PATH, only when PATH lies strictly below BASE. The callers pass out/, the
# build root, or the staging parent in the source checkout as BASE.
safe_rm() {
    local base="${1:-}" path="${2:-}" resolved
    [[ -n "${base}" && -n "${path}" ]] || die "rm: refusing to remove \"${path}\"" || return 1
    resolved="$(abs_path "${path}")" || die "rm: refusing to remove ${path}" || return 1
    base="$(abs_path "${base}")" || die "rm: refusing to remove ${path}" || return 1
    [[ -n "${base}" && "${resolved}" == "${base}/"* ]] || die "rm: refusing to remove ${path}" || return 1
    rm -rf -- "${resolved}"
}

# --- check ---

# fetch_upstream_tags REPO: apple/container's tags into refs/upstream-tags/*, without credentials.
# Only https may run. The self-test alone sets UPSTREAM_FILE_PROTOCOL to reach its file:// fixture.
fetch_upstream_tags() {
    GIT_TERMINAL_PROMPT=0 git -C "$1" \
        -c protocol.allow=never -c protocol.https.allow=always -c "protocol.file.allow=${UPSTREAM_FILE_PROTOCOL}" \
        -c credential.helper= -c http.extraHeader= \
        fetch --quiet --no-tags --no-write-fetch-head --prune -- "${UPSTREAM_URL}" \
        '+refs/tags/*:refs/upstream-tags/*'
}

# highest_upstream_tag REPO REV: the highest X.Y.Z upstream tag merged into REV, or nothing.
highest_upstream_tag() {
    git -C "$1" for-each-ref --merged "$2" --format='%(refname:strip=2)' refs/upstream-tags |
        { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# check_tag REPO TAG: the rules that tie TAG, ocx/source-revision, the two branches and the
# apple/container tags together. The fork's own tags are never consulted, because anyone who can
# push to the fork can write them.
check_tag() {
    local repo="$1" tag="$2" upstream rev file highest
    local base_ref="${OCX_PACKAGE_BASE_REF:-origin/parbake}" branch_ref="${OCX_PACKAGE_BRANCH_REF:-origin/ocx-package}"
    [[ "${tag}" =~ ${TAG_RE} ]] || die "check: tag \"${tag}\" does not match ${TAG_RE}" || return 1
    upstream="${BASH_REMATCH[1]}"
    file="${repo}/ocx/source-revision"
    [[ -f "${file}" ]] || die "check: ${file} is missing" || return 1
    rev="$(tr -d '[:space:]' <"${file}")"
    [[ "$(wc -l <"${file}" | tr -d ' ')" -eq 1 ]] ||
        die "check: ocx/source-revision must be exactly one line" || return 1
    [[ "${rev}" =~ ^[0-9a-f]{40}$ ]] ||
        die "check: ocx/source-revision \"${rev}\" is not 40 lowercase hex digits" || return 1
    git -C "${repo}" cat-file -e "${rev}^{commit}" 2>/dev/null ||
        die "check: source revision ${rev} is not a commit in this clone" || return 1
    git -C "${repo}" merge-base --is-ancestor "${rev}" HEAD 2>/dev/null ||
        die "check: source revision ${rev} is not an ancestor of HEAD" || return 1
    git -C "${repo}" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null ||
        die "check: ref ${base_ref} does not exist; fetch it first" || return 1
    git -C "${repo}" merge-base --is-ancestor "${rev}" "${base_ref}" 2>/dev/null ||
        die "check: source revision ${rev} is not an ancestor of ${base_ref}" || return 1
    git -C "${repo}" rev-parse --verify --quiet "${branch_ref}^{commit}" >/dev/null ||
        die "check: ref ${branch_ref} does not exist; fetch it first" || return 1
    git -C "${repo}" merge-base --is-ancestor HEAD "${branch_ref}" 2>/dev/null ||
        die "check: HEAD is not an ancestor of ${branch_ref}, so the tag is not on the packaging branch" || return 1
    fetch_upstream_tags "${repo}" ||
        die "check: cannot fetch the upstream tags of ${UPSTREAM_URL}" || return 1
    git -C "${repo}" rev-parse --verify --quiet "refs/upstream-tags/${upstream}^{commit}" >/dev/null ||
        die "check: upstream ${upstream} is not a tag of ${UPSTREAM_URL}" || return 1
    git -C "${repo}" merge-base --is-ancestor "refs/upstream-tags/${upstream}" "${rev}" 2>/dev/null ||
        die "check: upstream tag ${upstream} is not an ancestor of source revision ${rev}" || return 1
    highest="$(highest_upstream_tag "${repo}" "${rev}")" ||
        die "check: cannot list the upstream tags merged into ${rev}" || return 1
    [[ "${highest}" == "${upstream}" ]] ||
        die "check: tag ${tag} names upstream ${upstream}, but the highest upstream tag merged into ${rev} is ${highest}" || return 1
    printf 'tag: %s\nsource revision: %s\nupstream: %s\n' "${tag}" "${rev}" "${upstream}"
}

# --- build ---

# check_installed_root ROOT: the files the fork's install must leave in ROOT.
check_installed_root() {
    local root="$1" plugins="$1/${PLUGINS_REL}" file name dir count=0
    for file in bin/container bin/container-apiserver; do
        [[ -f "${root}/${file}" ]] || die "build: ${root}/${file} is missing" || return 1
    done
    for dir in "${plugins}/"*/; do
        [[ -d "${dir}" ]] || continue
        name="$(basename "${dir}")"
        count=$((count + 1))
        for file in "bin/${name}" config.toml; do
            [[ -f "${plugins}/${name}/${file}" ]] || die "build: ${plugins}/${name}/${file} is missing" || return 1
        done
    done
    [[ "${count}" -gt 0 ]] || die "build: no plugin directory under ${plugins}" || return 1
    for name in "${REQUIRED_PLUGINS[@]}"; do
        [[ -d "${plugins}/${name}" ]] || die "build: required plugin ${plugins}/${name} is missing" || return 1
    done
}

# drop_sudo_scripts ROOT: removes the two scripts that act on /usr/local with sudo.
drop_sudo_scripts() {
    local root="$1" script
    for script in "${SUDO_SCRIPTS[@]}"; do
        safe_rm "${root}" "${root}/${script}" || return 1
    done
}

# build SRC ROOT: the fork's release build, installed without sudo into an empty ROOT.
build() {
    local src root dir
    src="$(abs_path "$1")" || die "build: invalid source path $1" || return 1
    root="$(abs_path "$2")" || die "build: invalid root path $2" || return 1
    [[ -f "${src}/Makefile" ]] || die "build: no fork checkout at ${src}" || return 1
    command -v make >/dev/null 2>&1 || die "build: make not found" || return 1
    if [[ -e "${root}" && -n "$(ls -A "${root}" 2>/dev/null)" ]]; then
        die "build: ${root} is not empty" || return 1
    fi
    # make treats a leftover staging tree as up to date and would skip the install copy. A symlinked
    # bin or bin/release would move the rm base out of SRC.
    for dir in "${src}/bin" "${src}/bin/release"; do
        [[ ! -L "${dir}" ]] || die "build: ${dir} is a symlink; refusing to remove the staging tree" || return 1
    done
    safe_rm "${src}/bin/release" "${src}/bin/release/staging" || return 1
    mkdir -p "${root}"
    (cd "${src}" && make BUILD_CONFIGURATION=release build) || die "build: make build failed" || return 1
    (cd "${src}" && make BUILD_CONFIGURATION=release DEST_DIR="${root}/" SUDO= install) ||
        die "build: make install failed" || return 1
    check_installed_root "${root}" || return 1
    drop_sudo_scripts "${root}" || return 1
    printf 'container root: %s\n' "${root}"
}

# --- verify ---

problem() {
    printf 'ocx-package.sh: verify: %s\n' "$*" >&2
    PROBLEMS=$((PROBLEMS + 1))
}

# entitlement_keys FILE: the entitlement keys of a signed file, one per line.
entitlement_keys() {
    local dump
    dump="$(codesign -d --entitlements :- "$1" 2>/dev/null)" || return 1
    awk '{
        while (match($0, /<key>[^<]*<\/key>/)) {
            print substr($0, RSTART + 5, RLENGTH - 11)
            $0 = substr($0, RSTART + RLENGTH)
        }
    }' <<<"${dump}"
}

# entitlement_is_true FILE: the virtualization entitlement has the value true.
entitlement_is_true() {
    local flat
    flat="$(codesign -d --entitlements :- "$1" 2>/dev/null | tr -d ' \t\n')" || return 1
    [[ "${flat}" == *"<key>${ENTITLEMENT}</key><true/>"* ]]
}

# verify_file FILE: the signature and entitlement problems of one Mach-O file.
verify_file() {
    local file="$1" name info keys key
    name="$(basename "${file}")"
    codesign --verify --strict "${file}" >/dev/null 2>&1 || problem "bad signature: ${file}"
    info="$(codesign -dv "${file}" 2>&1)" || problem "cannot read the signature: ${file}"
    [[ "${info}" == *"Signature=adhoc"* ]] || problem "signature is not ad hoc: ${file}"
    keys="$(entitlement_keys "${file}")" || {
        problem "cannot read the entitlements: ${file}"
        keys=""
    }
    while IFS= read -r key; do
        [[ -z "${key}" || "${key}" == "${ENTITLEMENT}" ]] || problem "unexpected entitlement ${key}: ${file}"
    done <<<"${keys}"
    case " ${ENTITLED} " in
        *" ${name} "*)
            if [[ $'\n'"${keys}"$'\n' != *$'\n'"${ENTITLEMENT}"$'\n'* ]]; then
                problem "missing ${ENTITLEMENT}: ${file}"
            elif ! entitlement_is_true "${file}"; then
                problem "${ENTITLEMENT} is not true: ${file}"
            fi
            ;;
        *)
            [[ $'\n'"${keys}"$'\n' != *$'\n'"${ENTITLEMENT}"$'\n'* ]] ||
                problem "${ENTITLEMENT} must be absent: ${file}"
            ;;
    esac
}

# verify_root ROOT: signatures, entitlements, modes, links, sudo scripts and quarantine under ROOT.
verify_root() {
    local root="$1" file name ftype xattrs real top scans
    local machos=()
    PROBLEMS=0
    [[ -d "${root}" ]] || die "verify: no container root at ${root}; run build first" || return 1
    top="$(cd -P "${root}" && pwd)"
    scans="$(mktemp -d)" || die "verify: cannot make a temp directory" || return 1
    find "${root}" -type f -print0 >"${scans}/files" || problem "cannot scan ${root}"
    find "${root}" ! -type l \( -perm -4000 -o -perm -2000 -o -perm -0002 \) -print0 >"${scans}/modes" ||
        problem "cannot scan ${root} for setuid and world-writable files"
    find "${root}" -type l -print0 >"${scans}/links" || problem "cannot scan ${root} for symlinks"
    while IFS= read -r -d '' file; do
        ftype="$(file -b "${file}")" || {
            problem "cannot identify the file type: ${file}"
            continue
        }
        [[ "${ftype}" == *Mach-O* ]] || continue
        machos+=("${file}")
        verify_file "${file}"
    done <"${scans}/files"
    [[ "${#machos[@]}" -gt 0 ]] || problem "no Mach-O file under ${root}"
    for name in "${REQUIRED_BINARIES[@]}"; do
        file="${root}/${name}"
        if [[ -L "${file}" || ! -f "${file}" ]]; then
            problem "${name} is not in the root"
        elif [[ "$(file -b "${file}" 2>/dev/null)" != *Mach-O* ]]; then
            problem "${name} is not a Mach-O file"
        fi
    done
    for file in ${machos[@]+"${machos[@]}"}; do
        case "${file}" in
            */bin/*) [[ -x "${file}" ]] || problem "not executable: ${file}" ;;
        esac
    done
    while IFS= read -r -d '' file; do
        problem "setuid, setgid or world-writable: ${file}"
    done <"${scans}/modes"
    while IFS= read -r -d '' file; do
        real="$(realpath "${file}" 2>/dev/null)" || real=""
        [[ -n "${real}" && ("${real}" == "${top}" || "${real}" == "${top}/"*) ]] ||
            problem "symlink leaves the root: ${file}"
    done <"${scans}/links"
    for name in "${SUDO_SCRIPTS[@]}"; do
        [[ ! -e "${root}/${name}" && ! -L "${root}/${name}" ]] || problem "${name} is still in the root"
    done
    xattrs="$(xattr -rl "${root}" 2>&1)" || problem "cannot read the extended attributes of ${root}"
    [[ "${xattrs}" != *com.apple.quarantine* ]] || problem "a file carries com.apple.quarantine"
    rm -rf "${scans}"
    [[ "${PROBLEMS}" -eq 0 ]] || die "verify: ${PROBLEMS} problem(s) in ${root}" || return 1
}

verify() {
    verify_root "$1" || return 1
    printf 'verified %s\n' "$1"
}

# --- create ---

# check_archive ARCHIVE: no absolute and no .. member.
check_archive() {
    local listing
    listing="$(tar -tf "$1")" || die "create: cannot list $1" || return 1
    if grep -Eq '^/|(^|/)\.\.(/|$)' <<<"${listing}"; then
        die "create: $1 has an absolute or .. member" || return 1
    fi
}

# create ROOT TAG: out/container-X.Y.Z_NN.tar.xz and its compiled metadata next to it.
create() {
    local root="$1" version archive compiled name
    version="$(tag_version "$2")" || die "create: tag \"$2\" does not match ${TAG_RE}" || return 1
    [[ -d "${root}" ]] || die "create: no container root at ${root}" || return 1
    command -v ocx >/dev/null 2>&1 || die "create: ocx not found" || return 1
    archive="${OUT_DIR}/container-${version}.tar.xz"
    compiled="${OUT_DIR}/container-${version}-metadata.json"
    mkdir -p "${OUT_DIR}"
    for name in "${archive}" "${compiled}" "${OUT_DIR}/container-${version}-receipt.json"; do
        safe_rm "${OUT_DIR}" "${name}" || return 1
    done
    ocx package create "${root}" -p darwin/arm64 -m "${METADATA}" --bin-scan -o "${archive}" ||
        die "create: ocx package create failed" || return 1
    [[ -f "${archive}" ]] || die "create: ${archive} was not written" || return 1
    [[ -f "${compiled}" ]] || die "create: ${compiled} was not written" || return 1
    check_archive "${archive}" || {
        safe_rm "${OUT_DIR}" "${archive}"
        return 1
    }
    printf 'archive: %s\nmetadata: %s\n' "${archive}" "${compiled}"
}

usage() {
    sed -n '/^# --- usage ---$/,/^# --- end usage ---$/p' "$0" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

# --- self-test -------------------------------------------------------------------------------

STATUS=0

pass() { printf 'self-test ok: %s\n' "$1"; }
fail() {
    printf 'self-test FAILED: %s\n' "$1" >&2
    STATUS=1
}

# expect_code DESCRIPTION WANT COMMAND...: the command exits with exactly WANT.
expect_code() {
    local description="$1" want="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, want ${want}"
    fi
}

# expect_message DESCRIPTION TEXT COMMAND...: the command fails and its output contains TEXT.
expect_message() {
    local description="$1" text="$2" out got=0
    shift 2
    out="$("$@" 2>&1)" || got=$?
    if [[ "${got}" -ne 0 && "${out}" == *"${text}"* ]]; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, output: ${out}"
    fi
}

self_test_usage() {
    local self="${BASH_SOURCE[0]}" out tag
    out="$("${self}" --help)" || fail "--help exits non-zero"
    if [[ "${out}" == *"Usage:"* && "${out}" == *"--self-test"* && "${out}" != *"--- usage ---"* ]]; then
        pass "--help prints the usage header"
    else
        fail "--help output"
    fi
    expect_code "-h exits 0" 0 "${self}" -h
    expect_code "no subcommand exits 2" 2 "${self}"
    expect_code "an unknown subcommand exits 2" 2 "${self}" frobnicate
    expect_code "check without TAG exits 2" 2 "${self}" check
    expect_code "build with one argument exits 2" 2 "${self}" build src
    expect_code "verify without ROOT exits 2" 2 "${self}" verify
    expect_code "create without TAG exits 2" 2 "${self}" create root
    for tag in 1.6.1_01 ocx-1.6.1 ocx-1.6.1_1 ocx-1.6.1_001 ocx-1.6_01 ocx-v1.6.1_01 ocx-1.6.1-rc1_01 ""; do
        expect_code "check \"${tag}\" exits 2" 2 "${self}" check "${tag}"
        expect_code "create root \"${tag}\" exits 2" 2 "${self}" create root "${tag}"
    done
    if [[ "$(tag_version ocx-1.6.1_01)" == "1.6.1_01" ]]; then
        pass "tag_version strips the ocx- prefix"
    else
        fail "tag_version ocx-1.6.1_01"
    fi
}

self_test_metadata() {
    local got
    got="$(python3 -I -c 'import json, sys
m = json.load(open(sys.argv[1]))
paths = [e["value"] for e in m["env"] if e["key"] == "PATH" and e.get("visibility") == "public"]
print(m["type"], m["version"], " ".join(paths), " ".join(sorted(m["binaries"])))' "${METADATA}" 2>&1)" || got="error: ${got}"
    # shellcheck disable=SC2016 # ${installPath} is literal text that OCX expands.
    if [[ "${got}" == 'bundle 1 ${installPath}/bin container container-apiserver' ]]; then
        pass "ocx/metadata.json declares the bundle, its PATH and both binaries"
    else
        fail "ocx/metadata.json: ${got}"
    fi
    if [[ "$(cat "${REPO_ROOT}/ocx/source-revision")" =~ ^[0-9a-f]{40}$ ]]; then
        pass "ocx/source-revision is one 40-hex line"
    else
        fail "ocx/source-revision is not one 40-hex line"
    fi
}

# fixture_git ARGS...: git without the user's or the system's config, so no hook or signing runs.
fixture_git() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -c user.name=self-test -c user.email=self-test@example.invalid \
        -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"
}

# fixture_commit REPO MESSAGE: an empty commit, quiet.
fixture_commit() {
    fixture_git -C "$1" commit --quiet --allow-empty -m "$2"
}

# make_fixture DIR: an "upstream" repository with tags 1.6.0 and 1.6.1, and a fork clone of it with
# no upstream tag: a patch commit on origin/parbake, a packaging commit on origin/ocx-package whose
# ocx/source-revision names the patch commit, and a fork tag 9.9.9 that check must ignore. Upstream
# then moves on to 1.6.2, which is not an ancestor of the patch commit.
make_fixture() {
    local dir="$1" upstream="$1/upstream" repo="$1/repo" rev
    mkdir -p "${upstream}"
    fixture_git init --quiet "${upstream}"
    fixture_commit "${upstream}" "upstream 1.6.0"
    fixture_git -C "${upstream}" tag 1.6.0
    fixture_commit "${upstream}" "upstream 1.6.1"
    fixture_git -C "${upstream}" tag -a -m 1.6.1 1.6.1
    fixture_git -C "${upstream}" tag not-a-version
    fixture_git clone --quiet --no-tags "${upstream}" "${repo}"
    fixture_commit "${repo}" "parbake patch"
    fixture_git -C "${repo}" tag -a -m "fork tag" 9.9.9
    rev="$(fixture_git -C "${repo}" rev-parse HEAD)"
    fixture_git -C "${repo}" update-ref refs/remotes/origin/parbake "${rev}"
    mkdir -p "${repo}/ocx"
    printf '%s\n' "${rev}" >"${repo}/ocx/source-revision"
    fixture_git -C "${repo}" add ocx/source-revision
    fixture_commit "${repo}" "packaging"
    fixture_git -C "${repo}" update-ref refs/remotes/origin/ocx-package HEAD
    fixture_commit "${upstream}" "upstream 1.6.2"
    fixture_git -C "${upstream}" tag 1.6.2
}

# fixture_check DIR TAG: check_tag on the fixture fork, reading tags from the fixture upstream.
fixture_check() {
    local UPSTREAM_URL="file://$1/upstream" UPSTREAM_FILE_PROTOCOL=always
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null check_tag "$1/repo" "$2"
}

self_test_check() {
    local dir="$1/check" repo rev other out
    repo="${dir}/repo"
    make_fixture "${dir}"
    rev="$(cat "${repo}/ocx/source-revision")"
    out="$(fixture_check "${dir}" ocx-1.6.1_01 2>&1)" || fail "check refuses the good fixture: ${out}"
    if [[ "${out}" == *"source revision: ${rev}"* && "${out}" == *"upstream: 1.6.1"* ]]; then
        pass "check accepts ocx-1.6.1_01 on the fixture and ignores the fork tag 9.9.9"
    else
        fail "check output on the good fixture: ${out}"
    fi
    if [[ -z "$(fixture_git -C "${repo}" tag -l '1.*')" ]]; then
        pass "check writes no upstream tag into refs/tags"
    else
        fail "check wrote an upstream tag into refs/tags"
    fi
    expect_message "check names the tag rule" "does not match" fixture_check "${dir}" ocx-1.6.1_1
    expect_message "check ignores a fork tag that upstream does not have" "upstream 9.9.9 is not a tag of file://" \
        fixture_check "${dir}" ocx-9.9.9_01
    expect_message "check names an upstream tag that is not an ancestor" \
        "upstream tag 1.6.2 is not an ancestor of source revision ${rev}" fixture_check "${dir}" ocx-1.6.2_01
    expect_message "check names a higher merged upstream tag" \
        "names upstream 1.6.0, but the highest upstream tag merged into ${rev} is 1.6.1" \
        fixture_check "${dir}" ocx-1.6.0_01

    # 1.6.10 sorts above 1.6.9 and 1.6.1 as a version. Deleting it upstream prunes it again.
    fixture_git -C "${dir}/upstream" tag 1.6.9 1.6.1
    fixture_git -C "${dir}/upstream" tag 1.6.10 1.6.1
    expect_message "check sorts the upstream tags as versions" "is 1.6.10" fixture_check "${dir}" ocx-1.6.1_01
    fixture_git -C "${dir}/upstream" tag -d 1.6.9 1.6.10 >/dev/null
    expect_code "check prunes upstream tags that upstream deleted" 0 fixture_check "${dir}" ocx-1.6.1_01

    expect_message "check names an upstream it cannot fetch" "cannot fetch the upstream tags" \
        check_with_upstream "file://${dir}/absent" always "${repo}"
    expect_message "check fetches nothing over file:// outside the self-test" "cannot fetch the upstream tags" \
        check_with_upstream "file://${dir}/upstream" never "${repo}"
    OCX_PACKAGE_BASE_REF=refs/remotes/origin/missing expect_message "check names a missing base ref" \
        "ref refs/remotes/origin/missing does not exist" fixture_check "${dir}" ocx-1.6.1_01
    OCX_PACKAGE_BRANCH_REF=refs/remotes/origin/missing expect_message "check names a missing packaging ref" \
        "ref refs/remotes/origin/missing does not exist" fixture_check "${dir}" ocx-1.6.1_01

    # The base ref moved below the source revision: the revision is not on parbake.
    fixture_git -C "${repo}" update-ref refs/remotes/origin/parbake "${rev}^"
    expect_message "check names a revision off the base ref" "is not an ancestor of origin/parbake" \
        fixture_check "${dir}" ocx-1.6.1_01
    fixture_git -C "${repo}" update-ref refs/remotes/origin/parbake "${rev}"

    # HEAD is a commit the packaging branch does not contain.
    fixture_commit "${repo}" "stray commit"
    expect_message "check names a HEAD off the packaging branch" "is not an ancestor of origin/ocx-package" \
        fixture_check "${dir}" ocx-1.6.1_01
    fixture_git -C "${repo}" reset --quiet --hard origin/ocx-package

    printf '%s\n' "${rev:0:12}" >"${repo}/ocx/source-revision"
    expect_message "check names a short source revision" "is not 40 lowercase hex digits" \
        fixture_check "${dir}" ocx-1.6.1_01
    tr 'a-f' 'A-F' <<<"${rev}" >"${repo}/ocx/source-revision"
    expect_message "check names an uppercase source revision" "is not 40 lowercase hex digits" \
        fixture_check "${dir}" ocx-1.6.1_01
    printf '%s\n%s\n' "${rev}" "${rev}" >"${repo}/ocx/source-revision"
    expect_message "check names a source revision of two lines" "exactly one line" \
        fixture_check "${dir}" ocx-1.6.1_01
    printf '%s\n' "0123456789abcdef0123456789abcdef01234567" >"${repo}/ocx/source-revision"
    expect_message "check names a revision that is not a commit" "is not a commit in this clone" \
        fixture_check "${dir}" ocx-1.6.1_01

    # A commit on a side branch: on neither HEAD nor parbake.
    fixture_git -C "${repo}" reset --quiet --hard
    fixture_git -C "${repo}" checkout --quiet -b side "${rev}^"
    fixture_commit "${repo}" "side commit"
    other="$(fixture_git -C "${repo}" rev-parse HEAD)"
    fixture_git -C "${repo}" checkout --quiet -
    printf '%s\n' "${other}" >"${repo}/ocx/source-revision"
    expect_message "check names a revision that is not an ancestor of HEAD" "is not an ancestor of HEAD" \
        fixture_check "${dir}" ocx-1.6.1_01
    rm -f "${repo}/ocx/source-revision"
    expect_message "check names a missing ocx/source-revision" "source-revision is missing" \
        fixture_check "${dir}" ocx-1.6.1_01
}

# check_with_upstream URL FILE_PROTOCOL REPO: check_tag ocx-1.6.1_01 on REPO against another upstream.
check_with_upstream() {
    local UPSTREAM_URL="$1" UPSTREAM_FILE_PROTOCOL="$2"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null check_tag "$3" ocx-1.6.1_01
}

# make_install_root DIR [OMIT]: a root as the fork's install leaves it. OMIT is a file to leave out.
make_install_root() {
    local root="$1" omit="${2:-}" name plugins="$1/${PLUGINS_REL}"
    mkdir -p "${root}/bin"
    printf 'x' >"${root}/bin/container"
    printf 'x' >"${root}/bin/container-apiserver"
    for name in "${REQUIRED_PLUGINS[@]}" builder; do
        mkdir -p "${plugins}/${name}/bin"
        printf 'x' >"${plugins}/${name}/bin/${name}"
        printf 'x' >"${plugins}/${name}/config.toml"
    done
    if [[ -n "${omit}" ]]; then
        rm -rf "${root:?}/${omit}"
    fi
}

self_test_build() {
    local dir="$1/build" p="${PLUGINS_REL}" script
    make_install_root "${dir}/good"
    expect_code "check_installed_root accepts a good root" 0 check_installed_root "${dir}/good"
    make_install_root "${dir}/no-linux" "${p}/container-runtime-linux"
    expect_message "check_installed_root names a missing required plugin" "${p}/container-runtime-linux is missing" \
        check_installed_root "${dir}/no-linux"
    make_install_root "${dir}/no-config" "${p}/container-network-vmnet/config.toml"
    expect_message "check_installed_root names a missing config.toml" "container-network-vmnet/config.toml is missing" \
        check_installed_root "${dir}/no-config"
    make_install_root "${dir}/no-bin" "${p}/builder/bin/builder"
    expect_message "check_installed_root names a missing plugin binary" "builder/bin/builder is missing" \
        check_installed_root "${dir}/no-bin"
    make_install_root "${dir}/no-apiserver" bin/container-apiserver
    expect_message "check_installed_root names a missing container-apiserver" "bin/container-apiserver is missing" \
        check_installed_root "${dir}/no-apiserver"
    mkdir -p "${dir}/no-plugins/bin"
    printf 'x' | tee "${dir}/no-plugins/bin/container" >"${dir}/no-plugins/bin/container-apiserver"
    expect_message "check_installed_root refuses a root without plugins" "no plugin directory" \
        check_installed_root "${dir}/no-plugins"
    for script in "${SUDO_SCRIPTS[@]}"; do
        printf '#!/bin/sh\n' >"${dir}/good/${script}"
    done
    expect_code "drop_sudo_scripts succeeds" 0 drop_sudo_scripts "${dir}/good"
    if [[ -z "$(find "${dir}/good" -name '*.sh')" && -f "${dir}/good/bin/container" ]]; then
        pass "drop_sudo_scripts removes both scripts and keeps the binaries"
    else
        fail "drop_sudo_scripts left a script or removed a binary"
    fi
    mkdir -p "${dir}/src/bin/release/staging/bin" "${dir}/full/bin"
    printf 'x' >"${dir}/src/Makefile"
    printf 'x' >"${dir}/full/bin/old"
    expect_message "build refuses a root that is not empty" "is not empty" build "${dir}/src" "${dir}/full"
    if [[ -d "${dir}/src/bin/release/staging" ]]; then
        pass "build removes nothing before it refuses a full root"
    else
        fail "build removed the staging tree before it refused a full root"
    fi
    expect_message "build refuses a source without a Makefile" "no fork checkout" build "${dir}/full" "${dir}/new-root"

    # A symlinked bin or bin/release would point the staging rm outside SRC.
    mkdir -p "${dir}/elsewhere/release/staging" "${dir}/link-bin" "${dir}/link-release/bin"
    printf 'x' | tee "${dir}/link-bin/Makefile" >"${dir}/link-release/Makefile"
    ln -s "${dir}/elsewhere" "${dir}/link-bin/bin"
    ln -s "${dir}/elsewhere/release" "${dir}/link-release/bin/release"
    expect_message "build refuses a symlinked SRC/bin" "bin is a symlink" build "${dir}/link-bin" "${dir}/root-a"
    expect_message "build refuses a symlinked SRC/bin/release" "release is a symlink" \
        build "${dir}/link-release" "${dir}/root-b"
    if [[ -d "${dir}/elsewhere/release/staging" && ! -e "${dir}/root-a" && ! -e "${dir}/root-b" ]]; then
        pass "build removes nothing through a symlinked bin"
    else
        fail "build removed the staging tree through a symlink or made the root"
    fi
}

# expect_problem DESCRIPTION TEXT ROOT: verify_root fails on ROOT and its report contains TEXT.
expect_problem() {
    local out got=0
    out="$(verify_root "$3" 2>&1)" || got=$?
    if [[ "${got}" -ne 0 && "${out}" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1: exit ${got}, report: ${out}"
    fi
}

# sign_copy FILE [ENTITLEMENTS]: FILE becomes an ad-hoc signed copy of /usr/bin/true.
sign_copy() {
    mkdir -p "$(dirname "$1")"
    cp /usr/bin/true "$1"
    chmod 0755 "$1"
    if [[ -n "${2:-}" ]]; then
        codesign -s - -f --entitlements "$2" "$1" >/dev/null 2>&1
    else
        codesign -s - -f "$1" >/dev/null 2>&1
    fi
}

# plist FILE KEY...: an entitlements plist with each KEY set to true.
plist() {
    local file="$1" key
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        for key in "$@"; do
            printf '<key>%s</key><true/>' "${key}"
        done
        printf '</dict></plist>\n'
    } >"${file}"
}

self_test_verify() {
    local dir="$1/verify" ent extra good bad p="${PLUGINS_REL}"
    mkdir -p "${dir}"
    ent="${dir}/virt.plist"
    extra="${dir}/extra.plist"
    plist "${ent}" "${ENTITLEMENT}"
    plist "${extra}" "${ENTITLEMENT}" com.apple.security.get-task-allow
    good="${dir}/good"
    sign_copy "${good}/bin/container"
    sign_copy "${good}/bin/container-apiserver"
    sign_copy "${good}/${p}/container-runtime-linux/bin/container-runtime-linux" "${ent}"
    sign_copy "${good}/${p}/container-network-vmnet/bin/container-network-vmnet" "${ent}"
    sign_copy "${good}/${p}/container-core-images/bin/container-core-images"
    printf 'x' >"${good}/${p}/container-core-images/config.toml"
    ln -s ../container-core-images "${good}/${p}/container-runtime-linux/sibling"
    expect_code "verify_root accepts a good root with an inner symlink" 0 verify_root "${good}"

    bad="${dir}/broken"
    cp -R "${good}" "${bad}"
    printf 'x' >>"${bad}/bin/container-apiserver"
    expect_problem "verify_root refuses a broken signature" "bad signature" "${bad}"

    bad="${dir}/extra-entitlement"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/${p}/container-network-vmnet/bin/container-network-vmnet" "${extra}"
    expect_problem "verify_root refuses an extra entitlement" "unexpected entitlement com.apple.security.get-task-allow" "${bad}"

    bad="${dir}/unentitled"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/${p}/container-runtime-linux/bin/container-runtime-linux"
    expect_problem "verify_root refuses a missing virtualization entitlement" "missing ${ENTITLEMENT}" "${bad}"

    bad="${dir}/cli-entitled"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/bin/container" "${ent}"
    expect_problem "verify_root refuses the virtualization entitlement on container" "must be absent" "${bad}"

    bad="${dir}/symlink"
    cp -R "${good}" "${bad}"
    ln -s /usr/bin "${bad}/bin/escape"
    expect_problem "verify_root refuses a symlink leaving the root" "symlink leaves the root" "${bad}"

    bad="${dir}/dangling"
    cp -R "${good}" "${bad}"
    ln -s ../../nowhere/at/all "${bad}/bin/dangling"
    expect_problem "verify_root refuses a dangling symlink" "symlink leaves the root" "${bad}"

    bad="${dir}/sudo-script"
    cp -R "${good}" "${bad}"
    printf '#!/bin/sh\n' >"${bad}/bin/uninstall-container.sh"
    expect_problem "verify_root refuses a leftover sudo script" "bin/uninstall-container.sh is still in the root" "${bad}"

    bad="${dir}/missing-binary"
    cp -R "${good}" "${bad}"
    rm -f "${bad}/bin/container-apiserver"
    expect_problem "verify_root refuses a root without container-apiserver" "bin/container-apiserver is not in the root" "${bad}"

    bad="${dir}/moved-binary"
    cp -R "${good}" "${bad}"
    mv "${bad}/${p}/container-core-images/bin/container-core-images" "${bad}/bin/container-core-images"
    expect_problem "verify_root requires each binary at its install path" \
        "${p}/container-core-images/bin/container-core-images is not in the root" "${bad}"

    bad="${dir}/not-macho"
    cp -R "${good}" "${bad}"
    printf '#!/bin/sh\n' >"${bad}/bin/container"
    chmod 0755 "${bad}/bin/container"
    expect_problem "verify_root requires each binary to be Mach-O" "bin/container is not a Mach-O file" "${bad}"

    bad="${dir}/setuid"
    cp -R "${good}" "${bad}"
    chmod 4755 "${bad}/bin/container"
    expect_problem "verify_root refuses a setuid file" "setuid, setgid or world-writable" "${bad}"

    bad="${dir}/world-writable"
    cp -R "${good}" "${bad}"
    chmod 0666 "${bad}/${p}/container-core-images/config.toml"
    expect_problem "verify_root refuses a world-writable file" "config.toml" "${bad}"

    bad="${dir}/not-executable"
    cp -R "${good}" "${bad}"
    chmod 0644 "${bad}/bin/container"
    expect_problem "verify_root refuses a binary without the execute bit" "not executable" "${bad}"

    bad="${dir}/quarantine"
    cp -R "${good}" "${bad}"
    xattr -w com.apple.quarantine "0081;00000000;test;" "${bad}/bin/container"
    expect_problem "verify_root refuses a quarantined file" "quarantine" "${bad}"

    mkdir -p "${dir}/empty"
    expect_problem "verify_root refuses a root without Mach-O files" "no Mach-O" "${dir}/empty"
    expect_message "verify refuses a missing root" "no container root" verify_root "${dir}/absent"
}

self_test_create() {
    local dir="$1/create"
    mkdir -p "${dir}/tar/inner"
    printf 'x' >"${dir}/tar/inner/file"
    tar -cf "${dir}/good.tar" -C "${dir}/tar" inner
    tar -cPf "${dir}/absolute.tar" "${dir}/tar/inner/file"
    tar -cf "${dir}/dotdot.tar" -C "${dir}/tar/inner" ../inner/file
    expect_code "check_archive accepts a plain archive" 0 check_archive "${dir}/good.tar"
    expect_message "check_archive refuses an absolute member" "absolute or .. member" check_archive "${dir}/absolute.tar"
    expect_message "check_archive refuses a .. member" "absolute or .. member" check_archive "${dir}/dotdot.tar"
    expect_message "create refuses a missing root" "no container root" create "${dir}/absent" ocx-1.6.1_01
}

self_test_rm_guard() {
    local base="$1/rm/out" outside="$1/rm/outside"
    mkdir -p "${base}/inside/deep" "${outside}"
    expect_code "rm guard refuses an empty path" 1 safe_rm "${base}" ""
    expect_code "rm guard refuses an empty base" 1 safe_rm "" "${base}/inside"
    expect_code "rm guard refuses /" 1 safe_rm "${base}" /
    expect_code "rm guard refuses a path outside the base" 1 safe_rm "${base}" "${outside}"
    expect_code "rm guard refuses the base itself" 1 safe_rm "${base}" "${base}"
    expect_code "rm guard refuses .. out of the base" 1 safe_rm "${base}" "${base}/../outside"
    expect_code "rm guard refuses a base of /" 1 safe_rm / "${outside}"
    ln -s "${outside}" "${base}/link"
    expect_code "rm guard refuses a symlink leaving the base" 1 safe_rm "${base}" "${base}/link/x"
    if [[ -d "${outside}" && -d "${base}" ]]; then
        pass "the refused paths are still there"
    else
        fail "a refused path was removed"
    fi
    expect_code "rm guard accepts a path inside the base" 0 safe_rm "${base}" "${base}/inside"
    if [[ ! -e "${base}/inside" ]]; then
        pass "the accepted path is removed"
    else
        fail "the accepted path is still there"
    fi
}

# repo_state: the untracked and ignored files of the repository, plus out/ and changed tracked files.
repo_state() {
    (
        cd "${REPO_ROOT}"
        ls -lR out 2>/dev/null || true
        git status --porcelain --ignored --untracked-files=all 2>/dev/null |
            grep -Ev '^(\?\?|!!) (\.build/|\.swiftpm/|\.agents/|.*\.DS_Store$)' || true
    )
}

self_test() {
    local work before after
    work="$(mktemp -d)"
    # shellcheck disable=SC2064 # expand now: work is local to this function.
    trap "rm -rf '${work}'" EXIT
    export TMPDIR="${work}/tmp"
    mkdir -p "${TMPDIR}"
    before="$(repo_state)"
    self_test_usage
    self_test_metadata
    self_test_check "${work}"
    self_test_build "${work}"
    self_test_verify "${work}"
    self_test_create "${work}"
    self_test_rm_guard "${work}"
    after="$(repo_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "the self-test leaves the repository as it was"
    else
        fail "the self-test changed out/ or the untracked files"
    fi
    if [[ "${STATUS}" -eq 0 ]]; then
        printf 'ocx-package.sh self-test passed\n'
    fi
    return "${STATUS}"
}

main() {
    case "${1:-}" in
        --self-test)
            [[ $# -eq 1 ]] || usage_error "--self-test takes no argument" || return 2
            self_test
            ;;
        -h | --help) usage ;;
        check)
            [[ $# -eq 2 ]] || usage_error "check needs TAG" || return 2
            valid_tag "$2" || return 2
            check_tag "${REPO_ROOT}" "$2"
            ;;
        build)
            [[ $# -eq 3 ]] || usage_error "build needs SRC and ROOT" || return 2
            build "$2" "$3"
            ;;
        verify)
            [[ $# -eq 2 ]] || usage_error "verify needs ROOT" || return 2
            verify "$2"
            ;;
        create)
            [[ $# -eq 3 ]] || usage_error "create needs ROOT and TAG" || return 2
            valid_tag "$3" || return 2
            create "$2" "$3"
            ;;
        "") usage_error "no subcommand" ;;
        *) usage_error "unknown subcommand \"$1\"" ;;
    esac
}

main "$@"
