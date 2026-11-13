package version

import "testing"

func TestDocsURL(t *testing.T) {
	const blob, tree = RepoURL + "/blob/", RepoURL + "/tree/"
	tests := []struct{ stamp, file, want string }{
		{"1.0.0", "cli.md", blob + "v1.0.0/docs/cli.md"},
		{"1.1.0-rc.1", "compliance.md", blob + "v1.1.0-rc.1/docs/compliance.md"},
		{"1.0.1-dev.212.1760790000+g5114f85", "cli.md", blob + "main/docs/cli.md"},
		{"1.0.1-dev.212.1760790000+g5114f85.dirty", "cli.md", blob + "main/docs/cli.md"},
		{"1.0.1-dev.0.1760790000", "cli.md", blob + "main/docs/cli.md"},
		{"", "cli.md", blob + "main/docs/cli.md"},
		{"not a version", "cli.md", blob + "main/docs/cli.md"},
		{"1.0.0", "", tree + "v1.0.0/docs"},
		{"", "", tree + "main/docs"},
	}
	for _, tt := range tests {
		if got := DocsURL(tt.stamp, tt.file); got != tt.want {
			t.Errorf("DocsURL(%q, %q) = %q, want %q", tt.stamp, tt.file, got, tt.want)
		}
	}
}
