// Package social is the pure core of Sosyal: the hall's word filter and its
// rate limit, the friends' gift, the kingdom's aid and its shared goal.
//
// Pure, like every other package under internal/game: no http, no database, no
// time.Now. Time arrives as a parameter, which is what lets a rate limit be
// tested without waiting.
package social

import (
	"strings"
	"unicode"
)

// The stems are normalised once, at start, into exactly the shape a line is
// reduced to -- lower case, folded, and runs of one letter collapsed. A stem
// written "bollocks" must become "bolocks" to meet the text, because that is
// what "bolllocks" and "bollocks" both come out as.
func init() {
	fold := func(list []string) []string {
		out := make([]string, 0, len(list))
		seen := map[string]bool{}
		for _, w := range list {
			n := reduce(w).text
			if n == "" || seen[n] {
				continue
			}
			seen[n] = true
			out = append(out, n)
		}
		return out
	}
	blocked = fold(blocked)
	masked = fold(masked)
	nameBanned = fold(nameBanned)
}

// Verdict is what the hall does with a line.
type Verdict int

const (
	// Clean: said as written.
	Clean Verdict = iota
	// Masked: said with the word starred out, and nothing counted against the
	// lord. A masked word costs nothing because most of them are not malice.
	Masked
	// Blocked: never said, and a strike. Three inside the window shut the hall
	// for an hour -- time, never a fine, because a fine prices bad words.
	Blocked
)

func (v Verdict) String() string {
	switch v {
	case Masked:
		return "masked"
	case Blocked:
		return "blocked"
	}
	return "clean"
}

// The most a stem may be and still have to stand as a whole word. Short stems
// matched inside longer words are how a filter starts refusing Scunthorpe,
// Sussex and the Turkish "sikke" (a coin, which this game has).
const wholeWordUpTo = 5

// The stars a masked word is replaced with.
const stars = "***"

// Check reads a line and says what the hall should do with it.
//
// It returns the text to SHOW, which is the line with any masked word starred
// out, and the verdict. A blocked line's shown text is the original: the caller
// never stores it as said, and the moderation queue has to read the words that
// were actually typed.
func Check(text string) (string, Verdict) {
	if _, ok := firstHit(text, blocked); ok {
		return text, Blocked
	}
	shown := text
	found := false
	// One word at a time, re-reading the line after each: the stars move
	// everything after them, and a second hit has to be found in the new line.
	for range 12 {
		span, ok := firstHit(shown, masked)
		if !ok {
			break
		}
		found = true
		shown = shown[:span.from] + stars + shown[span.to:]
	}
	if found {
		return shown, Masked
	}
	return text, Clean
}

// CheckName holds a name to a harder line than a line of talk: a name is worn
// in front of lords who never chose to read it, and "Admin" over a lord's head
// is a phishing attack with no message attached.
//
// Names have no middle ground -- there is nothing to star out in a name -- so
// this answers only clean or blocked. It also reads TheirCase as two words:
// "ShitLord" is one word to a computer and two to everybody else.
func CheckName(name string) Verdict {
	split := splitCase(name)
	for _, list := range [][]string{blocked, masked, nameBanned} {
		if _, ok := firstHit(split, list); ok {
			return Blocked
		}
	}
	return Clean
}

// span is where a hit sits in the ORIGINAL text, in bytes.
type span struct{ from, to int }

// firstHit finds the earliest place any stem in the list appears, in the
// original text's own bytes.
//
// It looks in two readings of the line. The plain one is the line reduced:
// folded, collapsed, punctuation inside a word dropped ("s.h.i.t" is "shit"),
// whitespace still separating words. The other joins runs of single letters
// ("s h i t" is "shit"), which is the one evasion that spacing buys -- and it
// is applied ONLY to those runs, so "we marched on Scunthorpe" is never
// rewritten into a word it does not contain.
func firstHit(text string, stems []string) (span, bool) {
	best, found := span{}, false
	for _, form := range []reduced{reduce(text), joinSingles(reduce(text))} {
		for _, stem := range stems {
			at := findStem(form.text, stem)
			if at < 0 {
				continue
			}
			s := span{from: form.back[at], to: form.back[at+len(stem)-1] + form.width[at+len(stem)-1]}
			if !found || s.from < best.from {
				best, found = s, true
			}
		}
	}
	return best, found
}

// findStem returns where the stem is in a reduced line, or -1: anywhere for a
// long stem, and only as a whole word for a short one.
func findStem(norm, stem string) int {
	from := 0
	for {
		i := strings.Index(norm[from:], stem)
		if i < 0 {
			return -1
		}
		at := from + i
		if len(stem) > wholeWordUpTo || wholeWord(norm, at, len(stem)) {
			return at
		}
		from = at + 1
	}
}

// wholeWord reports whether the span stands alone in the reduced line, which
// has single spaces between words and nothing else.
func wholeWord(norm string, at, n int) bool {
	if at > 0 && norm[at-1] != ' ' {
		return false
	}
	end := at + n
	return end >= len(norm) || norm[end] == ' '
}

// reduced is a line as the filter reads it, with a way back to the original:
// back[i] is the byte in the original that the reduced byte i came from, and
// width[i] is how many of the original's bytes it stood for.
type reduced struct {
	text  string
	back  []int
	width []int
}

// foldRunes maps what people actually type to the letter underneath: Turkish
// letters to their ASCII shapes, and the leetspeak digits back to letters. A
// filter that does not fold these is one that a keyboard beats.
var foldRunes = map[rune]rune{
	'ı': 'i', 'İ': 'i', 'ğ': 'g', 'Ğ': 'g', 'ş': 's', 'Ş': 's',
	'ç': 'c', 'Ç': 'c', 'ö': 'o', 'Ö': 'o', 'ü': 'u', 'Ü': 'u',
	'â': 'a', 'î': 'i', 'û': 'u', 'é': 'e', 'á': 'a', 'í': 'i', 'ó': 'o', 'ú': 'u',
	'0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', '$': 's',
}

// reduce turns a line into what the filter reads.
//
// Whitespace always separates words: a hall where "what the" reads as one word
// would find things in it that nobody wrote. Punctuation between two letters is
// dropped instead, because "s.h.i.t" is one word to everyone but a computer.
// Runs of one letter collapse, so "shiiiit" is "shit". Everything folds (see
// foldRunes).
func reduce(text string) reduced {
	var b strings.Builder
	out := reduced{back: make([]int, 0, len(text)), width: make([]int, 0, len(text))}

	var last rune
	gapSpace := false // the run of separators so far holds whitespace
	gapAny := false
	gapFrom := -1
	put := func(r rune, at, w int) {
		b.WriteRune(r)
		for range len(string(r)) {
			out.back = append(out.back, at)
			out.width = append(out.width, w)
		}
	}
	for i, r := range text {
		f := unicode.ToLower(r)
		if m, ok := foldRunes[r]; ok {
			f = m
		} else if m, ok := foldRunes[unicode.ToLower(r)]; ok {
			f = m
		}
		if !unicode.IsLetter(f) {
			if b.Len() > 0 {
				gapAny = true
				gapSpace = gapSpace || unicode.IsSpace(r)
				if gapFrom < 0 {
					gapFrom = i
				}
			}
			continue
		}
		if gapAny {
			if gapSpace {
				put(' ', gapFrom, 1)
				last = ' '
			}
			gapAny, gapSpace, gapFrom = false, false, -1
		}
		if f == last {
			continue // a run of one letter is one letter
		}
		put(f, i, len(string(r)))
		last = f
	}
	out.text = b.String()
	return out
}

// joinSingles rewrites runs of single letters as one word: "s h i t" is "shit",
// and "i a m a d m i n" is "iamadmin". Only runs of two or more single letters
// are joined, so an ordinary line -- where "a" and "I" stand alone -- comes back
// unchanged.
func joinSingles(r reduced) reduced {
	words := strings.Split(r.text, " ")
	if len(words) < 2 {
		return r
	}
	// Where each word starts in the reduced text.
	starts := make([]int, len(words))
	at := 0
	for i, w := range words {
		starts[i] = at
		at += len(w) + 1
	}
	var b strings.Builder
	out := reduced{back: make([]int, 0, len(r.text)), width: make([]int, 0, len(r.text))}
	i := 0
	for i < len(words) {
		run := i
		for run < len(words) && len(words[run]) == 1 {
			run++
		}
		if run-i >= 2 {
			// Joined, and collapsed across the join: "g g" spelled out is the
			// same one letter that "gg" inside a word reduces to, or the stems
			// (which are collapsed) would never meet it.
			var lastLetter byte
			if b.Len() > 0 {
				lastLetter = b.String()[b.Len()-1]
			}
			for j := i; j < run; j++ {
				k := starts[j]
				if words[j][0] == lastLetter {
					continue
				}
				b.WriteString(words[j])
				out.back = append(out.back, r.back[k])
				out.width = append(out.width, r.width[k])
				lastLetter = words[j][0]
			}
			i = run
		} else {
			k := starts[i]
			b.WriteString(words[i])
			for n := range len(words[i]) {
				out.back = append(out.back, r.back[k+n])
				out.width = append(out.width, r.width[k+n])
			}
			i++
		}
		if i < len(words) {
			b.WriteByte(' ')
			k := starts[i] - 1
			if k < 0 || k >= len(r.back) {
				k = starts[i]
			}
			out.back = append(out.back, r.back[k])
			out.width = append(out.width, r.width[k])
		}
	}
	out.text = b.String()
	return out
}

// splitCase puts a space where a word begins inside a word: "ShitLord" is two
// words to everybody except a computer, and a name is where that trick is
// played.
func splitCase(s string) string {
	var b strings.Builder
	var prev rune
	for _, r := range s {
		if unicode.IsUpper(r) && unicode.IsLower(prev) {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
		prev = r
	}
	return b.String()
}
