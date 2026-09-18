package economy

import "testing"

// Three a day at a rising price, then none.
func TestRefillsClimbAndStop(t *testing.T) {
	prices := []int64{20, 30, 45}
	for used, want := range []int64{20, 30, 45} {
		q := QuoteRefill(prices, 0, used)
		if !q.Available || q.Price != want || q.Free {
			t.Fatalf("refill %d: %+v, want %d diamonds", used+1, q, want)
		}
		if q.Number != used+1 || q.Limit != 3 || q.Left != 2-used {
			t.Fatalf("refill %d: number %d limit %d left %d", used+1, q.Number, q.Limit, q.Left)
		}
	}
	if q := QuoteRefill(prices, 0, 3); q.Available {
		t.Fatalf("a fourth refill was offered: %+v", q)
	}
	if q := QuoteRefill(prices, 0, 50); q.Available || q.Left != 0 {
		t.Fatalf("far past the limit: %+v", q)
	}
}

// Free refills come first and do not move the paid ladder.
func TestFreeRefillsComeFirst(t *testing.T) {
	prices := []int64{20, 30, 45}
	q := QuoteRefill(prices, 1, 0)
	if !q.Free || q.Price != 0 || !q.Available || q.Limit != 4 || q.Left != 3 {
		t.Fatalf("first refill with one free: %+v", q)
	}
	q = QuoteRefill(prices, 1, 1)
	if q.Free || q.Price != 20 {
		t.Fatalf("the refill after the free one: %+v, want the first paid price", q)
	}
	if q := QuoteRefill(prices, 1, 4); q.Available {
		t.Fatalf("a fifth refill with one free and three paid: %+v", q)
	}
}

// A negative count from a bad row reads as none used, never as a discount.
func TestRefillQuoteToleratesNonsense(t *testing.T) {
	if q := QuoteRefill([]int64{20}, -3, -1); !q.Available || q.Price != 20 || q.Free {
		t.Fatalf("negative inputs: %+v", q)
	}
}

// Quartermaster's Sale halves the price, rounded in the buyer's favour, and
// leaves the day's count alone; a free refill stays free.
func TestASaleMakesRefillsCheaperNotMore(t *testing.T) {
	prices := []int64{20, 30, 45}
	q := OnSale(QuoteRefill(prices, 0, 2), 5000)
	if q.Price != 22 || q.Regular != 45 || q.Limit != 3 || q.Number != 3 || !q.Available {
		t.Fatalf("the third refill on sale: %+v", q)
	}
	if f := OnSale(QuoteRefill(prices, 1, 0), 5000); f.Price != 0 || !f.Free {
		t.Fatalf("a free refill on sale: %+v", f)
	}
	if spent := OnSale(QuoteRefill(prices, 0, 3), 5000); spent.Available {
		t.Fatal("a sale opened a refill the day had not got")
	}
	if one := OnSale(RefillQuote{Price: 1, Regular: 1, Available: true}, 9999); one.Price != 1 {
		t.Fatalf("a sale took a refill below a diamond: %+v", one)
	}
}
