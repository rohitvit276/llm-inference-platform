// k6 load test: ramp virtual users against the gateway and watch KEDA
// scale the model deployment. Run with:
//   k6 run -e GATEWAY_URL=http://<nlb-dns> -e API_KEY=dev-key loadtest/chat.js
import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  stages: [
    { duration: "1m", target: 2 },   // warm up
    { duration: "3m", target: 8 },   // push past the KEDA threshold
    { duration: "2m", target: 8 },   // hold — replicas should scale out
    { duration: "2m", target: 0 },   // ramp down — watch scale-in
  ],
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<30000"],
  },
};

const PROMPTS = [
  "Explain what a Kubernetes pod is in one sentence.",
  "Write a haiku about servers.",
  "What does CI/CD stand for?",
  "Name three uses for a message queue.",
  "Summarize what DNS does in one line.",
];

export default function () {
  const url = `${__ENV.GATEWAY_URL}/v1/chat/completions`;
  const payload = JSON.stringify({
    model: "qwen2.5-0.5b-instruct",
    max_tokens: 64,
    messages: [
      { role: "user", content: PROMPTS[Math.floor(Math.random() * PROMPTS.length)] },
    ],
  });
  const res = http.post(url, payload, {
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${__ENV.API_KEY || "dev-key"}`,
    },
    timeout: "120s",
  });
  check(res, {
    "status 200": (r) => r.status === 200,
    "has completion": (r) => r.status === 200 && r.json("choices.0.message.content") !== "",
  });
  sleep(1);
}
