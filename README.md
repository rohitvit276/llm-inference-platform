# LLM Inference Platform on EKS

Self-hosted, open-weight LLM serving on AWS — built as a platform-engineering
exercise: infrastructure as code, observability, event-driven autoscaling and
load-tested evidence that it all works.

**Stack:** Terraform · EKS (spot) · llama.cpp (Qwen2.5-0.5B-Instruct) ·
FastAPI gateway · Prometheus + Grafana · KEDA · k6 · GitHub Actions (OIDC)

## Architecture

```
                        ┌──────────────────────── EKS (spot nodes) ───────────────────────┐
                        │                                                                  │
  k6 load test ──► NLB ─┼─► llm-gateway (FastAPI)          llm-model (llama.cpp server)   │
                        │     · bearer-token auth     ──►    · OpenAI-compatible API      │
                        │     · rate limiting                · Qwen2.5-0.5B GGUF, CPU     │
                        │     · /metrics                     · /metrics (tokens/s, slots) │
                        │            │                              ▲                     │
                        │            ▼                              │ scales replicas     │
                        │      Prometheus ◄── ServiceMonitors ── KEDA (request-rate       │
                        │            │                             trigger via PromQL)    │
                        │            ▼                                                    │
                        │        Grafana (latency p95, tokens/sec, replica count)         │
                        └──────────────────────────────────────────────────────────────────┘

  GitHub Actions ── OIDC (no stored keys) ──► ECR ──► Helm deploy
```

## Design decisions (the interesting bits)

- **CPU inference on spot instances.** A 0.5B-parameter model quantized to
  Q4_K_M serves genuinely useful completions on 2 vCPUs. The point of the
  project is the *platform* around the model — the same chart serves a 70B
  model on GPU nodes by changing `values.yaml`.
- **KEDA over plain HPA.** Autoscaling on *request rate from Prometheus*
  rather than CPU: LLM inference saturates CPU at one request, so CPU-based
  HPA can't distinguish "busy" from "overloaded". Request rate can.
- **Public subnets, no NAT gateway.** Saves ~$32/month; a deliberate lab
  trade-off documented here so it reads as a choice, not an oversight.
- **Cost guardrails.** Spot capacity, ECR lifecycle policy, AWS Budget with
  email alerts at 50/80/100%, and `make down` destroys everything. A full
  work session costs well under $1.

## Runbook

```bash
cd terraform && cp example.tfvars terraform.tfvars   # set your alert email
make up            # ~12 min: VPC, EKS, ECR, budget alarm
make deploy-infra  # kube-prometheus-stack + KEDA
make build         # gateway image → ECR
make deploy        # helm install; prints the NLB endpoint
make loadtest GATEWAY_URL=http://<nlb-dns>
make grafana       # port-forward dashboards
make down          # destroy everything — end of session!
```

Smoke test:

```bash
curl -s http://<nlb-dns>/v1/chat/completions \
  -H "Authorization: Bearer dev-key" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello in 5 words"}],"max_tokens":32}'
```

## Load-test results

_TODO after first full run: k6 summary, Grafana screenshots showing replica
count scaling 1→4 under load and p95 latency, and a paragraph on what the
bottleneck was._

## What I'd do differently in production

- Private subnets + NAT (or VPC endpoints), IRSA-scoped pods
- Model weights baked into an image or pulled from S3 (HuggingFace is a
  single point of failure at pod start)
- vLLM on GPU nodes with continuous batching for real throughput
- Streaming (SSE) support through the gateway
- Per-key quotas in Redis instead of in-memory (survives replica restarts)
