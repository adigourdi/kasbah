// Command yaml2json prints each YAML document of a file (or stdin) as one line
// of JSON, read by internal/yamlx, for the black-box suites to pipe into jq.
// A stream that does not read prints nothing and exits 1.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

func main() {
	var in io.Reader = os.Stdin
	if len(os.Args) > 2 {
		fmt.Fprintln(os.Stderr, "usage: yaml2json [FILE|-]")
		os.Exit(2)
	}
	if len(os.Args) == 2 && os.Args[1] != "-" {
		f, err := os.Open(os.Args[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, "yaml2json:", err)
			os.Exit(1)
		}
		defer f.Close()
		in = f
	}
	if err := convert(in, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "yaml2json:", strings.ReplaceAll(err.Error(), "\n", " "))
		os.Exit(1)
	}
}

func convert(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	docs, err := yamlx.Load(data)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(out)
	for _, d := range docs {
		w.WriteString(jv.Compact(d))
		w.WriteByte('\n')
	}
	return w.Flush()
}
