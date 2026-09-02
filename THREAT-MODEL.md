accounts-api — Threat Model
Trust boundaries
Internet ↔ CloudFront/ALB — public edge, unauthenticated traffic hits here first.
ALB ↔ accounts-api pod — entry into the EKS cluster and into the accounts-api namespace.
accounts-api pod ↔ other ~12 teams' pods — same cluster, different owners, different (unknown-to-us) security posture. No boundary exists here by default in Kubernetes.
accounts-api pod ↔ RDS (PostgreSQL) — holds the actual regulated data at rest.
accounts-api pod ↔ message stream (event consumer) — inbound trust from whatever publishes those events; we assume we don't control the publisher's security either.
accounts-api pod ↔ third-party KYC provider — our only planned, intentional egress to the public internet; a real external party we don't control.
Engineer laptop / PR → CI → registry → cluster admission — the software supply chain; the boundary 40 people and their dependencies sit on the wrong side of by default.
Workload AWS account ↔ rest of the AWS Organization — IAM/KMS boundary between this service's blast radius and everything else the bank runs.

Top 5 threats, ranked by likelihood of actually materialising here
#	Threat	Entry point	What it reaches	Control in this submission / risk accepted
T1	A bad or compromised commit reaches production	Any of 40 engineers' PRs, or a compromised transitive dependency — no security team reviewing, one bad merge is enough	Whatever the running container can do: full read/write on customer PII, IBAN, balance via the app's own DB credentials	Implemented. Gitleaks + Semgrep + Trivy (hard gate) in CI, cosign signing, and — critically — Kyverno require-signed-images refusing to run anything unsigned in-cluster. This is ranked #1 because it needs no external attacker at all, just scale (40 mergers) and normal human error.
T2	Lateral movement from a neighbouring team's compromised pod on the shared cluster	Any of the ~12 other teams' workloads — owned and secured by people we have no visibility into	Flat pod-to-pod networking by default; could reach accounts-api pods, or shared node-level resources	Implemented. Default-deny NetworkPolicy + explicit allow-list (ALB ingress, RDS/DNS/KYC egress only) + IRSA instead of a node-level IAM role reachable via IMDS.
T3	An app-level bug (SSRF, deserialisation, the KYC call itself) turns into a full data-plane breach because the pod's AWS identity is over-privileged	Application code, most plausibly the outbound KYC HTTP call or an API input handler	If IAM is broad: every secret in the account, other teams' resources, key management actions	Implemented. IRSA role scoped to exactly one Secrets Manager path and kms:Decrypt/GenerateDataKey only — no secretsmanager:*, no kms:*, no wildcard resources for the app role.
T4	Secret sprawl — a DB password, AWS key, or KYC API key ends up in git history, a CI log, or an engineer's laptop	40 people, none of them a security specialist, over time; this is a "when," not an "if"	Direct DB access bypassing the app entirely, or AWS account access	Implemented. Gitleaks on every PR (fails closed, no default allowlist), ExternalSecrets pulling from Secrets Manager at runtime (nothing static ever lands in git or a k8s manifest), GitHub OIDC → AWS role (no long-lived AWS_ACCESS_KEY_ID in repo secrets at all).
T5	A known-vulnerable dependency or base image sits in production after a CVE is published post-deploy	No specific attacker action — just time passing after the last build	Whatever the CVE allows (commonly RCE or priv-esc) inside the pod; bounded afterward by T2/T3's controls	Partially accepted risk. Trivy gates new builds and ECR scan-on-push re-scans images already pushed, but I did not build an automated "new Critical CVE found → force rebuild/redeploy" trigger in the 4-hour window. Documented gap, not hidden — see DECISIONS.md.
One threat I consider overrated for this system: volumetric DDoS at the edge

CloudFront + AWS Shield Standard already give automatic, free volumetric DDoS absorption in front of the ALB — that's infrastructure, not something this exercise needs to re-derive with custom WAF rate-limiting rules. More importantly: a successful DDoS against accounts-api costs availability, and this system's actual regulatory exposure is around confidentiality and integrity of IBAN/PII/balance data. A bank examiner asking about this service is going to ask "who can read a customer's IBAN and how do you know," not "what's your peak req/sec before you fall over." Spending a 2-person platform team's scarce time hand-tuning WAF rules here would be lower-value than any of T1–T4 above, so I didn't build it.

Traceability note

Every control built in the remaining sections maps to a T# above. Anything that doesn't will say so explicitly and state why it was built anyway (see DECISIONS.md §1 for the KMS/CMK rationale, which sits slightly outside T1–T5 but supports auditability for the regulator, not a named attacker threat).
