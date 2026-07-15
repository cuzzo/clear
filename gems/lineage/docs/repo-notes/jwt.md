# jwt — Go

**Revision:** `1a11d3724e63` · **Scope:** production root `*.go` files ·
**Result:** token parsing/validation and crypto-key handling are correctly
highlighted; no security or performance bug is claimed from static evidence.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 21 files, 95 methods, 44 fields; no Type Next for Go. |
| Espalier | 59/95 bounds unknown (62.1%). `Validator` and parser state are top owners. |
| Decomplex | 31 convergences: `Parser.ParseWithClaims`, `ParseUnverified`, RSA signing, and EC/RSA PEM parsing. |

## Independent source audit

- `ParseWithClaims` splits token segments, selects the signing method, decodes
  claims, invokes a key callback, validates, and verifies. It is the natural
  high-risk error/validation boundary.
- `ParseUnverified` intentionally stops before signature validation; analyzer
  attention is appropriate, but its security semantics require call-site data
  flow, not complexity metrics.
- RSA/EC signing and PEM parsing mostly delegate cryptographic/library work;
  their static branch pressure does not establish unsafe crypto behavior or bad
  asymptotics.

## Assessment and follow-up

- Ranking is useful for security review triage. Complexity needs input length,
  claim-map size, and crypto-operation opaque components.
- No probable library bug. Any finding around unverified parsing must be
  validated interprocedurally against use-before-verify, rather than inferred
  from this function alone.
