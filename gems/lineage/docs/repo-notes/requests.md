# requests — Python

**Revision:** `f361ead047be` · **Scope:** `src/requests` · **Result:** no
probable product defect from this static pass.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 19 files, 260 methods, 182 fields; 211 Type Next candidates. Dynamic Python state makes these review leads, not type errors. |
| Espalier | 204/256 time bounds unknown (79.7%). Highest owner: `HTTPAdapter`; `resolve_redirects` has the strongest coordinator/mutator collision. |
| Decomplex | 69 multi-detector convergences, led by `auth.build_digest_header`, `HTTPAdapter.send`, `PreparedRequest.prepare_body`, and `resolve_redirects`. |

## Independent source audit

- `SessionRedirectMixin.resolve_redirects` repeatedly prepares and sends a
  request while maintaining history, auth, cookies, proxy, and body-rewind
  invariants. It is a genuine high-risk state-machine boundary, not a false
  complexity signal.
- `auth.build_digest_header` and `handle_401` assemble several protocol
  variants and retries; their branch density is intrinsic to HTTP Digest rather
  than evidence of a defect.
- `HTTPAdapter.send` and `PreparedRequest.prepare_body` are the meaningful
  performance/error-path surfaces. The former delegates I/O, while the latter
  can process body/header data proportionally to payload size.
- `utils.should_bypass_proxies` performs several independent string/list
  checks. Espalier reports a known component but not a full bound: a reasonable
  missing compositional-sum result, not proof of superlinear behavior.

## Assessment and follow-up

- The ranking usefully puts request preparation, redirect retries, and adapter
  error mapping ahead of incidental helpers. No candidate correctness defect
  emerged from reading these paths.
- The high unknown rate comes from dynamic receivers, external HTTP calls, and
  container/string methods. Better Python receiver/type facts and sum
  composition would make Big-O more actionable.
- The main negative control is `Response`/`HTTPAdapter` owner pressure: public
  API breadth is real, but it should not be interpreted as a request-state
  aliasing bug without a concrete trace.
