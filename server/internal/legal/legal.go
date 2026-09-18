// Package legal serves the game's Terms of Use and Privacy Policy.
//
// The App Store asks for both beside every subscription, and the Royal Store
// and the Crown's Favour link to them. They are served by the API itself, so
// they ship, version and deploy with the game they describe, and a change to
// what the game keeps is a change in the same repository as the page that says
// so. Plain HTML, no scripts, no fonts or images from anywhere else: a privacy
// policy that told Google who read it would be a poor start.
package legal

import (
	"bytes"
	_ "embed"
	"html/template"
	"net/http"
)

// Updated is the date both documents were last changed. Change it with them.
const Updated = "15 September 2026"

// Operator names who runs the game and how to reach them. Both are optional:
// without a name the pages say "the developer of Emperors"; without an address
// they send readers to the App Store listing's support link.
type Operator struct {
	Name    string
	Contact string
}

//go:embed terms.html
var termsHTML string

//go:embed privacy.html
var privacyHTML string

//go:embed page.html
var pageHTML string

type page struct {
	Title   string
	Updated string
	Name    string
	Contact string
	Body    template.HTML
}

// Pages renders both documents once, at start, and serves them from memory.
type Pages struct {
	terms, privacy []byte
}

// New renders the documents for this operator.
func New(op Operator) (*Pages, error) {
	if op.Name == "" {
		op.Name = "the developer of Emperors"
	}
	shell, err := template.New("page").Parse(pageHTML)
	if err != nil {
		return nil, err
	}
	render := func(title, body string) ([]byte, error) {
		inner, err := template.New(title).Parse(body)
		if err != nil {
			return nil, err
		}
		var b bytes.Buffer
		if err := inner.Execute(&b, op); err != nil {
			return nil, err
		}
		var out bytes.Buffer
		err = shell.Execute(&out, page{Title: title, Updated: Updated, Name: op.Name, Contact: op.Contact,
			Body: template.HTML(b.String())})
		return out.Bytes(), err
	}
	p := &Pages{}
	if p.terms, err = render("Terms of Use", termsHTML); err != nil {
		return nil, err
	}
	if p.privacy, err = render("Privacy Policy", privacyHTML); err != nil {
		return nil, err
	}
	return p, nil
}

// Terms serves the Terms of Use.
func (p *Pages) Terms(w http.ResponseWriter, _ *http.Request) { p.serve(w, p.terms) }

// Privacy serves the Privacy Policy.
func (p *Pages) Privacy(w http.ResponseWriter, _ *http.Request) { p.serve(w, p.privacy) }

func (p *Pages) serve(w http.ResponseWriter, body []byte) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	// Read in the in-app browser: a page that can run nothing and load nothing.
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")
	h.Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
