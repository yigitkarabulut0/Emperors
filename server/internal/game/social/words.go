package social

// The hall's word lists.
//
// They live in Go rather than in the balance for two reasons. The balance is
// published to the client on every version bump, and a document of slurs is not
// something to ship to a phone; and a list that an operator can edit live is a
// list an operator can empty by accident on a Friday night.
//
// Two lists, because there are two different things to do about a word. A
// masked word is said and starred out: the lord meant no harm, the hall reads
// on, and nothing is counted against them. A blocked word is refused: the line
// is never said, and the lord carries a strike for it. Three strikes inside the
// window and the hall is shut for an hour (social.json's chat section).
//
// Everything here is a STEM matched against the normalised text (see
// normalise): lower case, Turkish letters folded to their ASCII shapes,
// leetspeak digits folded back to letters, and runs of one letter collapsed --
// so "Sh1t", "şiiiit" and "s h i t" all reach the same stem. A stem of five
// letters or fewer must stand as a whole word, because short stems inside
// longer words are how a filter starts refusing Scunthorpe and Sussex.
//
// This list is deliberately short. It covers what actually arrives in a game
// hall in English and Turkish; it is not an attempt at every word in either
// language, and the moderation queue is what catches the rest.

// blocked refuses the line and gives a strike: slurs, and the explicitly
// sexual. A hall that starred these out would still be a hall that let them be
// said.
var blocked = []string{
	// English slurs and the explicitly sexual.
	"nigger", "nigga", "faggot", "fagot", "retard", "tranny", "kike", "spic",
	"chink", "wetback", "coon", "raghead",
	"rape", "rapist", "pedo", "pedophile", "paedophile", "childporn",
	"cunt", "whore", "slut",
	// Turkish, the same two kinds.
	"orospu", "pic", "piclik", "yarrak", "amcik", "amina", "sikis",
	"gavat", "ibne", "pust", "kahpe", "tecavuz", "sikik",
	// Nobody speaks for the crown but the crown. An impersonation in the hall
	// is how a phishing line gets read as an announcement.
	"emperorsadmin", "gamemaster", "officialadmin", "adminhere", "iamadmin",
	"freediamondslink", "diamondgenerator", "freegoldhack",
}

// masked is said, starred out. Ordinary swearing, which a hall has and which
// nobody needs punishing for.
var masked = []string{
	"shit", "fuck", "fucking", "bitch", "bastard", "asshole", "dick", "prick",
	"wanker", "bollocks", "crap", "damn",
	"amk", "aq", "sik", "bok", "salak", "aptal", "gerizekali", "mal",
	"siktir", "lanet",
}

// nameBanned is the extra list a NAME is held to, on top of blocked: a name is
// worn everywhere, in front of lords who never chose to read it, so it is held
// to a harder line than a line of talk. Impersonating the crown or the game is
// the whole of it -- "Admin" over a lord's head is a phishing attack with no
// message attached.
var nameBanned = []string{
	"admin", "administrator", "moderator", "gamemaster", "support",
	"official", "emperors", "staff", "system", "crown",
}
