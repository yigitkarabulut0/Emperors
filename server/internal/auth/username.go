package auth

import (
	"fmt"
	"strings"
	"unicode"
)

// Reserved names that must not be claimable, so nobody can impersonate the game
// itself in a battle log or on a leaderboard.
var reservedUsernames = map[string]bool{
	"admin": true, "administrator": true, "moderator": true, "mod": true,
	"emperors": true, "system": true, "support": true, "staff": true,
	"official": true, "root": true, "null": true, "undefined": true,
	"you": true, "me": true, "server": true, "bot": true,
}

// NormalizeUsername validates a username and returns its canonical lowercase
// form, which is what uniqueness is enforced on.
//
// ASCII letters, digits and underscore only. This is not xenophobia about
// names: it is homograph defence. Allowing Unicode means "Аdmin" with a
// Cyrillic А is a different string that renders identically, and in a game
// where you attack people by name that is a real impersonation vector.
// Display names can be liberalised later; the login identifier should not be.
func NormalizeUsername(raw string) (canonical string, display string, err error) {
	display = strings.TrimSpace(raw)

	if n := len([]rune(display)); n < 3 || n > 16 {
		return "", "", fmt.Errorf("username must be between 3 and 16 characters")
	}
	for _, r := range display {
		if r > unicode.MaxASCII || !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_') {
			return "", "", fmt.Errorf("username may contain only letters, digits and underscore")
		}
	}
	if !unicode.IsLetter(rune(display[0])) {
		return "", "", fmt.Errorf("username must start with a letter")
	}

	canonical = strings.ToLower(display)
	if reservedUsernames[canonical] {
		return "", "", fmt.Errorf("that username is reserved")
	}
	return canonical, display, nil
}
