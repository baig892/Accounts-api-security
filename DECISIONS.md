# accounts-api security — decisions document

Time-boxed to ~4 hours. This document is the reasoning; the repo is the evidence. Where I ran
out of time to build something, I've said so and written the approach instead, per the brief.

## 1. Scoping: what kind of system is this, actually

Before picking controls I want to name what `accounts-api` is in regulatory terms, because that
determines where I spend the 4 hours.

- It holds **name, email, phone, IBAN, balance, last-4 of card**. Last-4 only (not full PAN,
  not track data) puts this **outside full PCI-DSS cardholder data scope** for the card field —
  but IBAN + balance + PII together is squarely **financial services customer data** under most
  banking regulators' data-protection regimes (India: RBI's data localisation and IT rules,
  given `ap-south-1`; the general shape applies under GDPR/PSD2-style regimes too). **Assumption:**
  I'm treating this as "regulated financial PII, not full PCI cardholder data" — that's why I did
  not build PCI-specific controls like full tokenisation of the last-4, and did build strong
  encryption-at-rest/in-transit and access-scoping instead.
- It's on a **shared EKS cluster** with ~12 other teams. The single biggest risk this creates
  isn't "someone hacks accounts-api" — it's **another team's compromised or careless workload
  becoming a lateral path into accounts-api's data**, because Kubernetes gives you nothing for
  free across namespaces. Most of my Kubernetes-layer effort goes here.
- **40 engineers can merge, 2 people are on the platform team, no dedicated security team.**
  This is an organisational fact with technical consequences: controls that depend on a human
  reviewing something carefully (manual security review of every PR, a security team triaging
  every finding) will not hold at this ratio. I biased toward controls that are **enforced by a
  machine at merge/admission time**, not controls that depend on 40 people consistently doing
  the right thing, or 2 people catching what 40 people do.

**What this means for where the 4 hours went:** I implemented, in order of priority —
(1) supply chain integrity from commit to running pod, because it's the one control that
constrains *all 40 engineers* without asking any of them to do anything differently;
(2) namespace-level blast-radius controls for the shared-cluster fact; (3) IAM/secrets scoped
tightly enough that a compromised pod can't pivot. I explicitly did **not** spend time on
things a 2-person platform team can't realistically operate day-to-day (see §5).

## 2. What's enforced, and where

| Control | Where it lives | Why there and not somewhere else |
|---|---|---|
| Secret scanning | CI, pre-build | Cheapest, fastest fail; no point scanning/building on top of a leaked cred |
| SAST (Semgrep) | CI | Catches classes of bug (injection, auth bypass patterns) before image exists |
| IaC scanning (Checkov) | CI | Terraform is also "code that can misconfigure prod" - same gate philosophy |
| Vulnerability scan (Trivy), gate on Critical/High | CI, after build, before push | Scanning post-build means we scan what actually ships, not a Dockerfile guess |
| SBOM generation + attestation | CI, attached to the signed image | Answers "were we affected by CVE-X" in minutes, not a fire-drill grep |
| Image signing (cosign, keyless/OIDC) | CI, only on push to main | No private key to leak; signature is cryptographically tied to *this exact repo+workflow* |
| **Signature verification (admission gate)** | **Kyverno, in-cluster** | **This is the actual control, not the signing step.** Signing with nothing checking it is theatre. |
| Non-root / no-priv-esc / dropped caps / resource limits | Kyverno, in-cluster | Pod spec is attacker/author-controlled; admission-time enforcement can't be bypassed by a bad manifest |
| Default-deny network + explicit allows | NetworkPolicy, in-cluster | Direct mitigation for "shared cluster with 12 other teams" |
| IRSA scoped to one secret path, no wildcard | Terraform (`iam.tf`) | Removes blast radius of a container-escape or SSRF turning into "read all secrets in the account" |
| CMK per data class, decrypt-only for the app | Terraform (`kms.tf`) | Key usage is attributable to accounts-api specifically in CloudTrail; app can't re-encrypt/exfiltrate via key mgmt actions |
| GitHub OIDC → AWS role, locked to `refs/heads/main` | Terraform (`ecr.tf`) | No long-lived AWS keys in GitHub secrets at all; a PR branch cannot assume the deploy role |

Each of these has a passing, machine-checked test in the repo except where noted in §4.

## 3. What I deliberately left un-enforced, and the compensating control

Being honest about scope is the point of this exercise, so here's what I did not build, and
what I'd put in its place today if this were real and I only had 4 hours.

**Egress from `accounts-api` to the KYC provider (public internet).** Kubernetes `NetworkPolicy`
cannot match on FQDN/SNI — I can allow port 443 egress or block it, not "allow only
`kyc-provider.example.com`". Left as `allow 443 to anywhere` in `k8s/networkpolicy.yaml`, which
is honestly a gap: a compromised pod can exfiltrate over 443 to anywhere.
*Compensating control:* a Cilium `CiliumNetworkPolicy` with an `toFQDNs` rule (if the CNI
supports it) or, more conservatively, force the KYC call through a fixed egress NAT gateway /
forward proxy with an explicit allowlist enforced at the VPC layer, so DNS/SNI-based egress
control happens outside the CNI's limitations. I'd build this next, not skip it forever.

**Runtime detection (Falco).** I did not wire up Falco rules for anomalous syscalls in the
accounts-api pod (e.g., a shell spawned inside a container that should never spawn one).
*Compensating control, for now:* `readOnlyRootFilesystem: true` + all capabilities dropped +
`seccomp: RuntimeDefault` in the pod spec meaningfully shrinks what a code-exec bug can *do*
even without detection watching for it. This is prevention substituting for detection, which is
weaker than having both — I'm naming that weakness, not hiding it.

**CloudTrail / GuardDuty wiring specific to this workload.** Brief allows referencing these
without building them. *Compensating control:* the KMS key policy (§ terraform/kms.tf) makes
every decrypt/encrypt call against this specific key attributable in the account's existing
CloudTrail (assumed already enabled org-wide — a bank's control baseline should already have
this; I'm not re-deriving org-wide logging in a per-service exercise).

**Full mTLS between accounts-api and RDS / the event stream.** RDS connections here rely on
TLS-in-transit (assumption: `rds.force_ssl=1` at the parameter-group level, not shown — that's
an RDS parameter group resource I didn't get to write in Terraform) plus network-layer
restriction via NetworkPolicy, not certificate-based mutual auth between the pod and the
database. *Compensating control:* the IAM/secrets scoping means even a fully sniffed connection
string requires the attacker to also be inside the `accounts-api` NetworkPolicy egress path to
use it, and DB credentials rotate hourly via the ExternalSecrets refresh interval.

**Semgrep/SAST ruleset is generic (`p/golang p/owasp-top-ten`), not accounts-api-specific.**
A real 4-hour-scoped exercise for a bank would add custom rules for the specific things that
matter here — e.g., flagging any log statement that might include IBAN/PAN fields, or any SQL
built by string concatenation touching the accounts table. I named this rather than pretend the
generic ruleset covers it.

## 4. Honesty about what's actually tested vs. authored-only

This sandbox has no network egress to Terraform's release host, Trivy's, Cosign's, or Gitleaks'
distribution points, and no Docker daemon or live Kubernetes cluster. I was able to fetch and
run **checkov** (PyPI) and the **Kyverno CLI** (its GitHub release happened to be reachable) for
real, so:

- **`terraform/*.tf`**: authored and hand-checked for brace/syntax balance; **not** run through
  `terraform validate`/`plan` in this environment. Passed a real `checkov` scan: **78 passed, 3
  failed**. The 3 failures (`CKV_AWS_111`, `CKV_AWS_356`, `CKV_AWS_109`) are all the same root
  cause: a KMS **key policy** (resource-based) legitimately uses `resources = ["*"]` to mean
  "this key" — that's the standard AWS shape for a key policy, not an identity-policy wildcard
  over every resource in the account. I added inline `#checkov:skip` comments with the
  justification; this checkov version doesn't honor skip comments on `data` blocks, so the
  findings still print, but the reasoning is documented here and in `kms.tf` rather than the scan
  being silently "fixed" to look green.
- **`policy/kyverno/policies/restrict-pod-security.yaml`**: **fully tested**, `kyverno test`
  passes 10/10, including a negative test proving another team's namespace is untouched by the
  policy. Run it yourself — see `README.md`.
- **`policy/kyverno/policies/require-signed-images.yaml`**: authored, YAML-valid, loads cleanly
  under the Kyverno CLI. I could **not** get a meaningful `kyverno test` result for the actual
  signature-verification path, because `verifyImages` rules call out to a real registry +
  Rekor/Fulcio and the CLI's offline test harness doesn't emit a comparable result for that rule
  type without one (confirmed: it returns `Fail / Not found` for every case, including ones that
  should structurally pass — a CLI/test-harness limitation, not a policy bug). What I'd do with
  more time: stand up a `kind` cluster, install Kyverno for real, push a signed and an unsigned
  image to a local registry, and prove it against both. I did not fake a passing test for this.
- **`.github/workflows/ci.yaml`**: YAML-valid, uses real, current action versions
  (`gitleaks-action@v2`, `trivy-action@0.24.0`, `sbom-action@v0`, `cosign-installer@v3`). Not
  run end-to-end (would need a real GitHub repo + runners) — the individual tools it invokes
  (Trivy, cosign, Syft) are genuinely maintained OSS tools I'm confident in from direct use, not
  guessed at.

I'd rather show you exactly this split than present four unverified YAML files as if they were
all equally proven.

## 5. Two things I chose *not* to build, on purpose, given the team shape

- **A security champions / manual-review process.** With 40 mergers and 2 platform engineers,
  a policy that says "get a security review before merging" is a policy that gets skipped under
  deadline pressure by definition — there's no capacity to actually staff it. I put the
  enforcement in CI/admission control instead, which doesn't get tired or deprioritised.
- **A large policy surface (six-plus scanners half-wired).** The brief explicitly rewards one
  control done right over six done shallowly, and I agree with that framing for a 2-person
  platform team specifically: every additional enforced Kyverno policy or CI gate is something
  those 2 people have to triage false positives on and keep current. I picked signed-images +
  pod-security + network segmentation because they're the three that most directly answer "can
  a compromised or malicious commit, or a neighbouring team's compromised pod, get at customer
  financial data" — the actual threat this system faces — and left the rest named above as next
  steps with their compensating controls stated.

## 6. Assumptions log (one line each, per the brief)

- Service is written in Go (`Dockerfile` assumes this); doesn't change the security architecture
  either way.
- Trunk-based dev, protected `main`, PRs required to merge — not shown as a GitHub branch
  protection API call, but assumed as the mechanism that makes the CI gates actually load-bearing.
- Remote Terraform state lives in a separate, already-hardened platform/security AWS account,
  configured out-of-band from this repo (no backend block committed).
- `rds.force_ssl` and RDS-level encryption-at-rest with the same CMK are assumed configured;
  I did not write the `aws_db_instance` resource itself (brief says the service exists already;
  I focused Terraform on the identity/key/registry layer this exercise is actually testing).
- CloudTrail/GuardDuty are assumed already enabled at the AWS Organization level as a baseline
  control, not something this single service's Terraform should be re-establishing.
- Registry mapping: brief allows a free registry; I used `ghcr.io` in CI and describe the ECR
  equivalent in Terraform (`ecr.tf`). Swapping CI to push to ECR means changing the login step
  and the OIDC role's trust condition to the workload account — no other pipeline logic changes.
