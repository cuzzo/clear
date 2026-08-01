package main

import (
	"os"
	"testing"
)

// TestGigaLineageIntegrationE2E drives the real `giga summary --format json`
// binary through loadLineage and asserts the units parse. Skips unless the
// E2E_* env vars point at a built giga binary and a giga-built database.
func TestGigaLineageIntegrationE2E(t *testing.T) {
	db := os.Getenv("E2E_GIGA_DB")
	giga := os.Getenv("E2E_GIGA_BIN")
	repo := os.Getenv("E2E_REPO")
	if db == "" || giga == "" || repo == "" {
		t.Skip("set E2E_GIGA_DB, E2E_GIGA_BIN, E2E_REPO to run")
	}
	// The command is the bare binary; loadLineage supplies the `summary` verb
	// and its flags itself.
	idx := loadLineage(db, repo, nil, 10, giga)
	if idx.Status != "ok" {
		t.Fatalf("loadLineage status = %q, want ok", idx.Status)
	}
	if len(idx.Units) == 0 {
		t.Fatal("loadLineage returned no units")
	}
	t.Logf("parsed %d lineage units from giga; top unit %q in %s risk=%.2f",
		len(idx.Units), idx.Units[0].Name, idx.Units[0].File, idx.Units[0].RiskScore)
}
