package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/yigitkarabulut0/emperors/server/internal/auth"
	"github.com/yigitkarabulut0/emperors/server/internal/db/sqlcdb"
)

// AdminSessionTTL is short on purpose. This panel can grant currency and ban
// accounts; a session left open on a laptop overnight is a real risk, and
// signing in again costs seconds.
const AdminSessionTTL = 8 * time.Hour

// Identity is who is making a request.
type Identity struct {
	ID       uuid.UUID
	Username string
	Role     string
}

// Login exchanges credentials for an opaque session token.
//
// Opaque and stored, not a JWT: an admin session must be revocable the instant
// something looks wrong, and a stateless token cannot be revoked.
func (s *Service) Login(ctx context.Context, username, password string) (string, *Identity, error) {
	q := sqlcdb.New(s.Pool)

	u, err := q.GetAdminByUsername(ctx, username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Burn comparable time on an unknown user so response timing does not
			// disclose which admin accounts exist.
			_ = auth.VerifyPassword(password, dummyAdminHash)
			return "", nil, ErrBadCredentials
		}
		return "", nil, err
	}
	if u.Disabled {
		return "", nil, ErrBadCredentials
	}
	if err := auth.VerifyPassword(password, u.PasswordHash); err != nil {
		return "", nil, ErrBadCredentials
	}

	token, hash, err := auth.NewRefreshToken()
	if err != nil {
		return "", nil, err
	}
	if _, err := q.CreateAdminSession(ctx, sqlcdb.CreateAdminSessionParams{
		AdminID: u.ID, TokenHash: hash, ExpiresAt: time.Now().Add(AdminSessionTTL),
	}); err != nil {
		return "", nil, err
	}
	_ = q.TouchAdminLogin(ctx, u.ID)

	return token, &Identity{ID: u.ID, Username: u.Username, Role: u.Role}, nil
}

// Authenticate resolves a session token.
func (s *Service) Authenticate(ctx context.Context, token string) (*Identity, error) {
	if token == "" {
		return nil, ErrUnauthorized
	}
	row, err := sqlcdb.New(s.Pool).GetAdminSession(ctx, auth.HashRefreshToken(token))
	if err != nil {
		return nil, ErrUnauthorized
	}
	if row.RevokedAt != nil || row.Disabled || time.Now().After(row.ExpiresAt) {
		return nil, ErrUnauthorized
	}
	return &Identity{ID: row.AdminID, Username: row.Username, Role: row.Role}, nil
}

// Logout revokes a session.
func (s *Service) Logout(ctx context.Context, token string) error {
	return sqlcdb.New(s.Pool).RevokeAdminSession(ctx, auth.HashRefreshToken(token))
}

// Audit records an action with what it looked like before and after.
//
// Every mutating admin path calls this. Without it there is no way to answer
// "who granted this player a million gold, and why" three months later — and
// that question always eventually gets asked.
func (s *Service) Audit(ctx context.Context, who *Identity, action, subject string, before, after any, note string) {
	var b, a []byte
	if before != nil {
		b, _ = json.Marshal(before)
	}
	if after != nil {
		a, _ = json.Marshal(after)
	}
	var id *uuid.UUID
	name := "system"
	if who != nil {
		id = &who.ID
		name = who.Username
	}
	if err := sqlcdb.New(s.Pool).WriteAudit(ctx, sqlcdb.WriteAuditParams{
		AdminID: id, AdminName: name, Action: action,
		Subject: nullable(subject), Before: b, After: a, Note: note,
	}); err != nil {
		// An audit failure must not swallow the action that succeeded, but it is
		// worth surfacing loudly.
		fmt.Printf("AUDIT WRITE FAILED action=%s subject=%s err=%v\n", action, subject, err)
	}
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// dummyAdminHash is a real Argon2id hash, used to spend comparable CPU on an
// unknown username.
const dummyAdminHash = "$argon2id$v=19$m=65536,t=2,p=4$YWRtaW5zYWx0dmFsdWU$3P4kKQ0mVQ0KJc9nQ0Zz5x8Yq1rW2sT3uV4wX5yZ6a0"

// AuditEntry is one row of the trail.
type AuditEntry struct {
	ID      int64  `json:"id"`
	Admin   string `json:"admin"`
	Action  string `json:"action"`
	Subject string `json:"subject"`
	Note    string `json:"note"`
	At      string `json:"at"`
}

func (s *Service) AuditLog(ctx context.Context, limit int32) ([]AuditEntry, error) {
	rows, err := sqlcdb.New(s.Pool).ListAudit(ctx, limit)
	if err != nil {
		return nil, err
	}
	out := make([]AuditEntry, 0, len(rows))
	for _, r := range rows {
		subject := ""
		if r.Subject != nil {
			subject = *r.Subject
		}
		out = append(out, AuditEntry{
			ID: r.ID, Admin: r.AdminName, Action: r.Action, Subject: subject,
			Note: r.Note, At: r.CreatedAt.UTC().Format("2006-01-02 15:04:05"),
		})
	}
	return out, nil
}
