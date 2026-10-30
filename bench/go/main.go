// Command parse-go is the Go arm of `just bench-compare` (bench/README.md):
// golang.org/x/net/html parsing each corpus document from memory into its
// node tree.
//
// Usage, from the repository root:
//
//	parse-go [-count N]   benchmark rows in the Go benchmark format
//	parse-go check        node counts per document, and one parse's allocations
//
// Each row times html.Parse over the document's bytes with Go's own
// testing.Benchmark, so the garbage collector's work is inside the row.
// x/net/html refuses documents nested deeper than 512 elements; their rows
// are a `# SKIP` comment, which benchstat ignores.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

const corpus = "bench/corpus-gen"

type document struct {
	name string
	data []byte
}

func load() []document {
	entries, err := os.ReadDir(corpus)
	if err != nil {
		fail("read %s: %v (run `just bench-corpus`)", corpus, err)
	}
	var docs []document
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".html") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(corpus, entry.Name()))
		if err != nil {
			fail("read %s: %v", entry.Name(), err)
		}
		docs = append(docs, document{strings.TrimSuffix(entry.Name(), ".html"), data})
	}
	sort.Slice(docs, func(i, j int) bool { return docs[i].name < docs[j].name })
	return docs
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "parse-go: "+format+"\n", args...)
	os.Exit(1)
}

func parse(data []byte) (*html.Node, error) {
	return html.Parse(bytes.NewReader(data))
}

func main() {
	testing.Init()
	count := flag.Int("count", 1, "run each benchmark N times")
	flag.Parse()
	docs := load()
	if flag.Arg(0) == "check" {
		check(docs)
		return
	}
	for range *count {
		for _, doc := range docs {
			if _, err := parse(doc.data); err != nil {
				fmt.Printf("# SKIP BenchmarkParse/%s: %v\n", doc.name, err)
				continue
			}
			result := testing.Benchmark(func(b *testing.B) {
				b.SetBytes(int64(len(doc.data)))
				for b.Loop() {
					parse(doc.data)
				}
			})
			fmt.Printf("BenchmarkParse/%s\t%s\n", doc.name, result.String())
		}
	}
}

type counts struct {
	elements, attributes, texts, textBytes, comments int
}

func (c *counts) walk(n *html.Node) {
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		switch child.Type {
		case html.ElementNode:
			c.elements++
			c.attributes += len(child.Attr)
		case html.TextNode:
			c.texts++
			c.textBytes += len(child.Data)
		case html.CommentNode:
			c.comments++
		}
		c.walk(child)
	}
}

func check(docs []document) {
	for _, doc := range docs {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		root, err := parse(doc.data)
		runtime.ReadMemStats(&after)
		if err != nil {
			fmt.Printf("%s error=%q\n", doc.name, err.Error())
			continue
		}
		var c counts
		c.walk(root)
		fmt.Printf("%s elements=%d attributes=%d texts=%d text_bytes=%d comments=%d\tallocs=%d bytes=%d\n",
			doc.name, c.elements, c.attributes, c.texts, c.textBytes, c.comments,
			after.Mallocs-before.Mallocs, after.TotalAlloc-before.TotalAlloc)
	}
}
