// Package dbfs embeds the migration files so the migrate binary is
// self-contained — no "did you copy the sql directory to the server" failures.
package dbfs

import "embed"

//go:embed migrations/*.sql
var Migrations embed.FS
