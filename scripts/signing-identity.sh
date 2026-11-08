# Code-signing identity helpers, sourced by scripts/bundle.sh and
# scripts/release.sh (zsh).
#
# Allowance Bar is signed with the project's Developer ID Application
# certificate (team GC28C3K5G9). An Apple-issued certificate with a team ID
# gives the app's Keychain items the partition "teamid:GC28C3K5G9", which
# stays the same across builds and certificate renewals, so macOS asks for
# Keychain access once instead of after every build or update.

ALLOWANCEBAR_TEAM_ID="${ALLOWANCEBAR_TEAM_ID:-GC28C3K5G9}"

# Prints the SHA-1 of the first valid "Developer ID Application" identity of
# the team in the keychain search list, or nothing. Choosing it by hash keeps
# codesign unambiguous while an old and a renewed certificate overlap.
find_developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -v team="(${ALLOWANCEBAR_TEAM_ID})\"" \
            '/"Developer ID Application: / && index($0, team) { print $2; exit }'
}

# Succeeds when the identity (a SHA-1 or a certificate name) is a valid
# Developer ID Application identity in the keychain.
is_developer_id_identity() {
    [[ -n "$1" && "$1" != "-" ]] || return 1
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -F -- "$1" \
        | grep -q '"Developer ID Application: '
}
