// Command yaml2json prints each YAML document of a file (or stdin) as one line
// of JSON, keys in source order, for the black-box suites to pipe into jq.
// Documents read before a parse error are still printed, then it exits 1.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"go.yaml.in/yaml/v3"
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
	dec := yaml.NewDecoder(in)
	for {
		var doc yaml.Node
		err := dec.Decode(&doc)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		var b bytes.Buffer
		if err := emit(&b, &doc); err != nil {
			return err
		}
		b.WriteByte('\n')
		if _, err := out.Write(b.Bytes()); err != nil {
			return err
		}
	}
}

func emit(b *bytes.Buffer, n *yaml.Node) error {
	switch n.Kind {
	case yaml.DocumentNode:
		if len(n.Content) == 0 {
			b.WriteString("null")
			return nil
		}
		return emit(b, n.Content[0])
	case yaml.AliasNode:
		return emit(b, n.Alias)
	case yaml.SequenceNode:
		b.WriteByte('[')
		for i, c := range n.Content {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := emit(b, c); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case yaml.MappingNode:
		b.WriteByte('{')
		for i := 0; i+1 < len(n.Content); i += 2 {
			if i > 0 {
				b.WriteByte(',')
			}
			var k string
			if err := n.Content[i].Decode(&k); err != nil {
				k = n.Content[i].Value
			}
			if err := scalar(b, k); err != nil {
				return err
			}
			b.WriteByte(':')
			if err := emit(b, n.Content[i+1]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		var v any
		if err := n.Decode(&v); err != nil {
			return err
		}
		return scalar(b, v)
	}
	return nil
}

func scalar(b *bytes.Buffer, v any) error {
	if bs, ok := v.([]byte); ok {
		v = string(bs)
	}
	enc, err := marshal(v)
	if err != nil {
		return err
	}
	b.Write(enc)
	return nil
}

// marshal is json.Marshal without HTML escaping.
func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}
