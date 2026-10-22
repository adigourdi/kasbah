package releasekey

import (
	"bytes"
	"os"
	"testing"
)

func TestMatchesRepoRoot(t *testing.T) {
	root, err := os.ReadFile("../../release.pub")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(root, File) {
		t.Fatal("internal/releasekey/release.pub differs from release.pub at the repository root — copy it over")
	}
	k, err := Key()
	if err != nil {
		t.Fatal(err)
	}
	if k.IDString() != ID {
		t.Errorf("key id %s, expected %s", k.IDString(), ID)
	}
}
