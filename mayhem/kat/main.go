// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which LD_PRELOADs a shim whose
// constructor calls _exit(0) for non-system executables) cannot neuter it — a suite that only runs
// `go test` is therefore immune to the sabotage check and does NOT prove the oracle is behavioral.
// This probe is built with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, it prints nothing, and test.sh's exact string assertions
// below fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it feeds FIXED shell/JSON input through the real
// parser/printer/typedjson round-trip and asserts the EXACT resulting string — shfmt's whole job. A
// patch that stubs the parser to stop a crash cannot reproduce these strings, so it fails the oracle.
//
// Prints two lines, which test.sh matches EXACTLY:
//
//	KAT_PARSE_PRINT=<formatted output of the messy fixed shell snippet>
//	KAT_TYPEDJSON_DECODE=<formatted output of the decoded fixed JSON literal>
package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"

	"mvdan.cc/sh/v3/syntax"
	"mvdan.cc/sh/v3/syntax/typedjson"
)

func main() {
	// ── 1) parser + printer round-trip: messy shell in, canonical shfmt output out ──
	const src = "if [ a = b ];then echo x;fi\n"
	parser := syntax.NewParser(syntax.KeepComments(true))
	prog, err := parser.Parse(strings.NewReader(src), "")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: parse: %v\n", err)
		os.Exit(1)
	}
	var pbuf bytes.Buffer
	if err := syntax.NewPrinter().Print(&pbuf, prog); err != nil {
		fmt.Fprintf(os.Stderr, "kat: print: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_PARSE_PRINT=%s\n", strconv.Quote(pbuf.String()))

	// ── 2) typedjson.Decode of a fixed, hand-written JSON literal (echo hi), reprinted ──
	const j = `{"Type":"File","Stmts":[{"Cmd":{"Type":"CallExpr","Args":[{"Parts":[{"Type":"Lit","Value":"echo"}]},{"Parts":[{"Type":"Lit","Value":"hi"}]}]}}]}`
	node, err := typedjson.Decode(strings.NewReader(j))
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: typedjson decode: %v\n", err)
		os.Exit(1)
	}
	var jbuf bytes.Buffer
	if err := syntax.NewPrinter().Print(&jbuf, node); err != nil {
		fmt.Fprintf(os.Stderr, "kat: print decoded node: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_TYPEDJSON_DECODE=%s\n", strconv.Quote(jbuf.String()))
}
