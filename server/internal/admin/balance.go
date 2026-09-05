// Package admin holds the live-ops surface: balance publishing, player tools
// and the audit trail. It is deliberately separate from the game services, so
// nothing a player can reach shares a code path with anything that can grant
// currency.
package admin

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
	"github.com/yigitkarabulut0/emperors/server/internal/gameconfig"
)

// BalanceLoader reads the active document for the config store.
type BalanceLoader struct{ Pool *pgxpool.Pool }

func (l BalanceLoader) ActiveDoc(ctx context.Context) (int, []byte, error) {
	row, err := sqlcdb.New(l.Pool).ActiveBalance(ctx)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, nil, nil // nothing published; the seed stays live
		}
		return 0, nil, err
	}
	// Verify the seal on every read. A document edited directly in the database,
	// bypassing the panel and its validation, must not silently become live.
	if !bytes.Equal(gameconfig.Seal([]byte(row.Doc)), row.Sha256) {
		return 0, nil, fmt.Errorf("balance version %d fails its checksum; refusing to load it", row.ID)
	}
	return int(row.ID), []byte(row.Doc), nil
}

// VersionSummary is a row in the version history.
type VersionSummary struct {
	ID        int64  `json:"id"`
	Note      string `json:"note"`
	CreatedBy string `json:"created_by"`
	CreatedAt string `json:"created_at"`
	Activated bool   `json:"ever_activated"`
	Live      bool   `json:"live"`
	Bytes     int    `json:"bytes"`
}

// Publish validates a document, stores it as an immutable version, and makes it
// live in one transaction.
//
// Validation happens BEFORE the write. A document that would let a player earn
// infinite gold should never reach the versions table at all, let alone the
// activation log — otherwise a rollback target exists that nobody should ever
// pick.
func (s *Service) Publish(ctx context.Context, doc gameconfig.Doc, note, by string) (*VersionSummary, error) {
	raw, err := gameconfig.MarshalDoc(doc)
	if err != nil {
		return nil, fmt.Errorf("serialise: %w", err)
	}
	if _, err := gameconfig.FromDoc(0, doc); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidBalance, err)
	}

	q := sqlcdb.New(s.Pool)
	v, err := q.CreateBalanceVersion(ctx, sqlcdb.CreateBalanceVersionParams{
		Doc: string(raw), Sha256: gameconfig.Seal(raw), Note: note, CreatedBy: by,
	})
	if err != nil {
		return nil, fmt.Errorf("store version: %w", err)
	}
	if _, err := q.ActivateBalanceVersion(ctx, sqlcdb.ActivateBalanceVersionParams{
		VersionID: v.ID, ActivatedBy: by, Reason: note,
	}); err != nil {
		return nil, fmt.Errorf("activate: %w", err)
	}

	// Swap immediately rather than waiting for the poll, so the panel shows the
	// effect of a publish straight away.
	if err := s.Config.Refresh(ctx); err != nil {
		return nil, fmt.Errorf("published, but the server could not load it: %w", err)
	}
	return &VersionSummary{
		ID: v.ID, Note: v.Note, CreatedBy: v.CreatedBy,
		CreatedAt: v.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
		Activated: true, Live: true, Bytes: len(raw),
	}, nil
}

// Rollback re-activates an existing version.
//
// Another append, never an edit: the history of what was live when is the only
// way to explain an old battle or an old item roll after a rebalance.
func (s *Service) Rollback(ctx context.Context, versionID int64, by, reason string) (*VersionSummary, error) {
	q := sqlcdb.New(s.Pool)
	v, err := q.GetBalanceVersion(ctx, versionID)
	if err != nil {
		return nil, ErrNotFound
	}
	if !bytes.Equal(gameconfig.Seal([]byte(v.Doc)), v.Sha256) {
		return nil, fmt.Errorf("version %d fails its checksum; refusing to activate it", versionID)
	}
	doc, err := gameconfig.ParseDoc([]byte(v.Doc))
	if err != nil {
		return nil, err
	}
	if _, err := gameconfig.FromDoc(0, doc); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidBalance, err)
	}

	if _, err := q.ActivateBalanceVersion(ctx, sqlcdb.ActivateBalanceVersionParams{
		VersionID: versionID, ActivatedBy: by, Reason: reason,
	}); err != nil {
		return nil, err
	}
	if err := s.Config.Refresh(ctx); err != nil {
		return nil, err
	}
	return &VersionSummary{
		ID: v.ID, Note: v.Note, CreatedBy: v.CreatedBy,
		CreatedAt: v.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
		Activated: true, Live: true, Bytes: len(v.Doc),
	}, nil
}

// Versions lists the publication history.
func (s *Service) Versions(ctx context.Context, limit int32) ([]VersionSummary, error) {
	q := sqlcdb.New(s.Pool)
	rows, err := q.ListBalanceVersions(ctx, limit)
	if err != nil {
		return nil, err
	}
	live := int64(s.Config.Get().Version)
	out := make([]VersionSummary, 0, len(rows))
	for _, r := range rows {
		out = append(out, VersionSummary{
			ID: r.ID, Note: r.Note, CreatedBy: r.CreatedBy,
			CreatedAt: r.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
			Activated: r.EverActivated, Live: r.ID == live, Bytes: len(r.Doc),
		})
	}
	return out, nil
}
