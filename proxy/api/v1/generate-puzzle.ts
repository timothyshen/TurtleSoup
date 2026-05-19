// POST /api/v1/generate-puzzle
//
// AI-assisted puzzle generation. Given a one-liner idea + optional difficulty,
// returns a complete 海龟汤 puzzle: {title, scenario, answer, hint, difficulty}.
//
// Uses Claude tool_use for structured output (no manual JSON parsing or
// markdown fence stripping needed — the SDK guarantees the tool input shape).
//
// Auth: Firebase ID Token required.

import { withCORS, preflight } from "../../lib/cors.js";
import { jsonError } from "../../lib/errors.js";
import { requireAuth } from "../../lib/auth-middleware.js";

export const config = { runtime: "edge" };

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-4-6";

type Difficulty = "简单" | "中等" | "困难";

interface GenerateRequest {
  idea: string;
  difficulty?: Difficulty;
}

interface GeneratedPuzzle {
  title: string;
  scenario: string;
  answer: string;
  hint?: string;
  difficulty: Difficulty;
}

const SYSTEM_PROMPT = `你是一位资深的海龟汤（Lateral Thinking Puzzle）题目作者。

海龟汤的标准结构：
- 汤面（scenario）：一个看起来诡异、矛盾或无法解释的情境，玩家看到的部分。50-150 字。
- 汤底（answer）：完整真相，揭示汤面背后的逻辑链。必须能用现实逻辑解释，避免超自然/玄学。100-300 字。
- 提示（hint）：玩家卡住时给的一句话引导，不直接揭示关键转折。20 字以内。

质量标准：
- 汤面要有钩子（hook），让人想问"为什么"
- 汤底逻辑要严密，每个细节都能在汤面中找到对应
- 难度判断：
  - 简单：单一转折点，3-5 轮提问可解
  - 中等：2 个转折点或需要跨场景联想
  - 困难：多层嵌套，需要打破思维定式

你必须调用 submit_puzzle 工具返回结果，不要输出任何其他文字。`;

const SUBMIT_TOOL = {
  name: "submit_puzzle",
  description: "Submit a generated 海龟汤 puzzle.",
  input_schema: {
    type: "object",
    properties: {
      title: {
        type: "string",
        description: "题目标题，6-15 个字，要有悬念。",
      },
      scenario: {
        type: "string",
        description: "汤面（玩家看到的谜题描述），50-150 字。",
      },
      answer: {
        type: "string",
        description: "汤底（完整真相，仅主持人可见），100-300 字。必须能解释汤面所有细节。",
      },
      hint: {
        type: "string",
        description: "可选提示。20 字以内，不直接揭示关键转折。",
      },
      difficulty: {
        type: "string",
        enum: ["简单", "中等", "困难"],
        description: "题目难度评级。",
      },
    },
    required: ["title", "scenario", "answer", "difficulty"],
  },
};

export default async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") {
    return withCORS(jsonError(405, "method_not_allowed", "Use POST."));
  }

  const auth = await requireAuth(req);
  if (!auth.ok) return auth.response;

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return withCORS(
      jsonError(500, "config_missing", "ANTHROPIC_API_KEY not set."),
    );
  }

  let payload: GenerateRequest;
  try {
    payload = (await req.json()) as GenerateRequest;
  } catch {
    return withCORS(jsonError(400, "invalid_json", "Request body must be JSON."));
  }
  if (typeof payload.idea !== "string" || payload.idea.trim().length === 0) {
    return withCORS(
      jsonError(400, "missing_idea", "Field `idea` is required."),
    );
  }

  const userPrompt = buildUserPrompt(payload);

  let upstream: Response;
  try {
    upstream = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1500,
        system: SYSTEM_PROMPT,
        // Sonnet 4.6: must set effort explicitly (defaults to "high").
        // medium balances quality vs cost for creative tool_use generation.
        // thinking disabled — adaptive would add ~2-5s without measurable quality lift here.
        thinking: { type: "disabled" },
        output_config: { effort: "medium" },
        tools: [SUBMIT_TOOL],
        tool_choice: { type: "tool", name: "submit_puzzle" },
        messages: [{ role: "user", content: userPrompt }],
      }),
    });
  } catch (e) {
    return withCORS(
      jsonError(
        502,
        "upstream_unreachable",
        `Failed to reach Anthropic: ${(e as Error).message}`,
      ),
    );
  }

  if (!upstream.ok) {
    const errText = await upstream.text();
    return withCORS(
      jsonError(upstream.status, "upstream_error", errText.slice(0, 500)),
    );
  }

  const data = (await upstream.json()) as {
    content: Array<{ type: string; name?: string; input?: unknown }>;
  };

  const toolUse = data.content.find(
    (b) => b.type === "tool_use" && b.name === "submit_puzzle",
  );
  if (!toolUse || !toolUse.input) {
    return withCORS(
      jsonError(
        502,
        "tool_use_missing",
        "Claude did not return a submit_puzzle tool call.",
      ),
    );
  }

  const puzzle = toolUse.input as GeneratedPuzzle;
  return withCORS(Response.json({ puzzle }));
}

function buildUserPrompt(req: GenerateRequest): string {
  const lines = [`请基于以下想法生成一个海龟汤题目：`, ``, req.idea.trim()];
  if (req.difficulty) {
    lines.push("", `目标难度：${req.difficulty}`);
  }
  lines.push("", "调用 submit_puzzle 工具返回结果。");
  return lines.join("\n");
}
