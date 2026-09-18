# The painting prompt book, generated

`docs/art/PAINTING_BRIEFS_2.md` and the owner's prompt page are built from one
list of briefs, so the document and the page never disagree.

    cd scripts/art-briefs
    python3 briefs2.py /tmp/briefs2.json                        # the list
    python3 briefs2_md.py /tmp/briefs2.json ../../docs/art/PAINTING_BRIEFS_2.md
    python3 briefs2_html.py /tmp/briefs2.json /tmp/tablo-kitapcigi-2.html

`briefs2.py` reads the shared prompt blocks (STYLE, SHEET, TEXT RULE, AVOID ...)
from `docs/art/PAINTING_BRIEFS.md` and declares each brief with `add(...)`:
`group` is `fix`, `new` or `more` (a later round), `prio` 1-3. The HTML page is
published as the owner's artifact; republish it to the same URL after a change.
