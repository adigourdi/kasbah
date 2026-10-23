package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocate(t *testing.T) {
	tmp := t.TempDir()
	installed := filepath.Join(tmp, "lib", "1.2.0", "kasbah")
	loose := filepath.Join(tmp, "Downloads", "kasbah_1.2.0_linux_amd64")
	for _, p := range []string{installed, loose} {
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("x"), 0o755)
	}
	os.MkdirAll(filepath.Join(tmp, "bin"), 0o755)
	toInstalled, toLoose := filepath.Join(tmp, "bin", "kasbah"), filepath.Join(tmp, "bin", "k")
	os.Symlink(installed, toInstalled)
	os.Symlink(loose, toLoose)
	for _, tt := range []struct {
		exe, real string
		loose     bool
	}{
		{installed, installed, false},
		{toInstalled, installed, false},
		{loose, loose, true},
		{toLoose, loose, true},
	} {
		if real, l := locate(tt.exe); real != tt.real || l != tt.loose {
			t.Errorf("locate(%s) = %s, %v; want %s, %v", tt.exe, real, l, tt.real, tt.loose)
		}
	}
}
