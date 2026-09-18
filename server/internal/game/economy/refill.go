package economy

// RefillQuote is what the next full energy refill of the day costs, if there is
// one left to buy.
type RefillQuote struct {
	// The diamonds it costs. Zero for a free one.
	Price int64
	// What it costs off sale: Price before OnSale took from it. Equal to Price
	// when nothing is on.
	Regular int64
	// A free refill (Crown Patronage), taken before any paid one.
	Free bool
	// Which refill of the day this is, from 1.
	Number int
	// How many the day allows, free and paid together.
	Limit int
	// How many are left after this one is bought.
	Left int
	// False once the day's refills are spent.
	Available bool
}

// QuoteRefill prices the next refill of the day.
//
// prices is the paid ladder (store.energy_refill_prices); freePerDay refills come
// first and cost nothing; usedToday is how many the player has already taken
// today, free or paid. The ladder's length is the daily limit on bought energy:
// that bound is what stops a purchasable premium currency from being unlimited
// gold and experience.
func QuoteRefill(prices []int64, freePerDay, usedToday int) RefillQuote {
	if freePerDay < 0 {
		freePerDay = 0
	}
	if usedToday < 0 {
		usedToday = 0
	}
	q := RefillQuote{Limit: freePerDay + len(prices), Number: usedToday + 1}
	switch {
	case usedToday < freePerDay:
		q.Free, q.Available = true, true
	case usedToday-freePerDay < len(prices):
		q.Price, q.Available = prices[usedToday-freePerDay], true
		q.Regular = q.Price
	default:
		q.Number = q.Limit
		return q
	}
	q.Left = q.Limit - usedToday - 1
	return q
}

// OnSale takes a sale's basis points off a quote's price, rounded down in the
// buyer's favour and never below one diamond. The day's count and limit are
// untouched: a sale makes a refill cheaper, never more of them.
func OnSale(q RefillQuote, bp int64) RefillQuote {
	if q.Price <= 0 || bp <= 0 {
		return q
	}
	if bp > 10000 {
		bp = 10000
	}
	q.Price = max(1, q.Price*(10000-bp)/10000)
	return q
}
