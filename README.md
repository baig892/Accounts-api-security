# accounts-api security — take-home submission

Read `DECISIONS.md` first — it's the actual deliverable. This README is just "how do I run
what's here."

## Repo layout

```
app/                      Dockerfile (hardened, distroless, non-root, multi-stage)
k8s/                      Namespace, NetworkPolicy (default-deny + explicit allows),
                          Deployment (hardened SecurityContext, IRSA ServiceAccount),
                          ExternalSecret (Secrets Manager -> k8s secret, no plaintext secrets)
policy/kyverno/policies/  Two ClusterPolicies: require-signed-images, restrict-pod-security
policy/kyverno/tests/     kyverno test suite - 10/10 passing, see below
terraform/                IAM (IRSA + GitHub OIDC), KMS (CMK for RDS/Secrets Manager), ECR
.github/workflows/ci.yaml Gitleaks -> Semgrep/Checkov/Kyverno -> build -> Trivy -> SBOM -> cosign sign
DECISIONS.md              Threat model, what's enforced, what's deliberately not, why, and
                          an honest accounting of what was actually validated vs. authored-only
```

## What a reviewer can actually run

### 1. Kyverno pod-security policy — fully tested, run this

```bash
# Install the Kyverno CLI (no cluster needed for this one):
curl -sL https://github.com/kyverno/kyverno/releases/latest/download/kyverno-cli_linux_x86_64.tar.gz | tar xz

cd policy/kyverno/tests
../../../kyverno test .
```

Expect `10 tests passed, 0 failed`. The suite covers: a fully-compliant pod passing every rule,
a privileged pod being blocked, a pod that's compliant on everything except resource limits
being blocked *only* on that rule (proves the rules are independent, not one big pattern), and
a pod in a different team's namespace being correctly skipped (proves the blast-radius scoping
actually works, not just "trust me").

### 2. Terraform — static analysis via checkov (real scan, no `terraform` binary needed)

```bash
pip install checkov --break-system-packages
cd terraform
checkov -d . --framework terraform
```

Expect `Passed checks: 78, Failed checks: 3`. The 3 are explained in `DECISIONS.md` §4 — they're
a known checkov pattern on KMS key policies (`resources=["*"]` is correct AWS shape for a
resource-based key policy), not an actual overly-broad grant. I did not have `terraform`
binary network access in my authoring sandbox to run `validate`/`plan`; the files are
hand-checked for structural correctness.

### 3. `require-signed-images` Kyverno policy — authored, not fully testable offline

This policy's YAML loads cleanly under the Kyverno CLI, but `verifyImages` rules need a live
registry + Rekor/Fulcio round-trip that the offline `kyverno test` harness can't fake — see
`DECISIONS.md` §4 for exactly what that limitation looks like and what proving it for real would
take (a `kind` cluster + a local registry + one signed and one unsigned image).

### 4. CI pipeline

Not runnable outside a real GitHub repo with Actions enabled. Push this repo to GitHub, and it
runs on `pull_request` and `push` to `main` using free GitHub-hosted runners — no paid account
needed. The Trivy step hard-fails the build on any Critical/High CVE with an available fix.

## Known gaps (see DECISIONS.md §3 for the full reasoning + compensating controls)

- Egress to the third-party KYC provider is allowed on 443 to any destination — Kubernetes
  `NetworkPolicy` can't do FQDN matching. Compensating control and next step documented.
- No Falco/runtime detection wired up. Prevention (dropped caps, read-only rootfs, seccomp)
  substitutes for detection today; that's a real gap, named as one.
- CloudTrail/GuardDuty are assumed enabled at the AWS Organization level, not re-built here.
