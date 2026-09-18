package legal

import (
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

func render(t *testing.T, p *Pages, terms bool) (string, map[string]string) {
	t.Helper()
	w := httptest.NewRecorder()
	if terms {
		p.Terms(w, httptest.NewRequest("GET", "/legal/terms", nil))
	} else {
		p.Privacy(w, httptest.NewRequest("GET", "/legal/privacy", nil))
	}
	h := map[string]string{}
	for k := range w.Header() {
		h[k] = w.Header().Get(k)
	}
	return w.Body.String(), h
}

// Both pages render, say what App Review asks a subscription's terms to say,
// and load nothing from anywhere else.
func TestThePagesSayWhatTheyMust(t *testing.T) {
	p, err := New(Operator{})
	if err != nil {
		t.Fatal(err)
	}
	terms, h := render(t, p, true)
	privacy, _ := render(t, p, false)
	for _, want := range []string{
		"renews automatically", "24 hours", "Settings", "Subscriptions",
		"Restore Purchases", "third-party beneficiaries", "the developer of Emperors",
		"the support link on the game's App Store page",
	} {
		if !strings.Contains(terms, want) {
			t.Errorf("the terms do not say %q", want)
		}
	}
	for _, want := range []string{
		"Delete account", "Germany", "180 days", "400 days", "90 days",
		"do not sell", "no third-party advertising", "under 13",
	} {
		if !strings.Contains(privacy, want) {
			t.Errorf("the privacy policy does not say %q", want)
		}
	}
	if h["Content-Type"] != "text/html; charset=utf-8" || !strings.Contains(h["Content-Security-Policy"], "default-src 'none'") {
		t.Fatalf("headers: %v", h)
	}
	// No script, no remote font, stylesheet or image: nothing that tells a
	// third party who read the page. The one outside link is Apple's refund page.
	remote := regexp.MustCompile(`(?i)(src|href)="https?://([^"/]+)`)
	for name, page := range map[string]string{"terms": terms, "privacy": privacy} {
		if strings.Contains(strings.ToLower(page), "<script") {
			t.Errorf("the %s page carries a script", name)
		}
		for _, m := range remote.FindAllStringSubmatch(page, -1) {
			if m[1] == "src" || m[2] != "reportaproblem.apple.com" {
				t.Errorf("the %s page reaches %s (%s)", name, m[2], m[1])
			}
		}
	}
}

// The operator's name and address, when set, replace the defaults everywhere.
func TestTheOperatorIsNamed(t *testing.T) {
	p, err := New(Operator{Name: "Example Games Ltd", Contact: "help@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	for _, terms := range []bool{true, false} {
		page, _ := render(t, p, terms)
		if !strings.Contains(page, "Example Games Ltd") || !strings.Contains(page, `mailto:help@example.com`) {
			t.Fatalf("the operator is not named on the %v page", terms)
		}
		if strings.Contains(page, "the developer of Emperors") || strings.Contains(page, "App Store page") {
			t.Fatal("a default survived beside the operator's own name")
		}
	}
}
