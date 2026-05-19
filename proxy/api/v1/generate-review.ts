// POST /api/v1/generate-review
//
// Post-game AI review. Given the puzzle (汤面 + 汤底), the conversation
// transcript, and whether the player won, returns a structured analysis:
// - a one-sentence summary
// - 2-4 key moments (good questions, wrong turns, breakthroughs, stuck points)
// - one actionable tip for next time
//
// Uses tool_use for structured output. Auth: Firebase ID Token.

import { withCORS, preflight } from "../../lib/cors.js";
import { jsonError } from "../../lib/errors.js";
import { requireAuth } from "../../lib/auth-middleware.js";
import { FieldDetector, sseEvent, parseSSEBlock, sseBlocks } from "../../lib/tool-stream.js";

export const config = { runtime: "edge" };

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-4-6";

type Verdict = "yes" | "no" | "irr" | "part" | "win";

interface TranscriptTurn {
  role: "user" | "assistant";
  text: string;
  verdict?: Verdict;
}

interface ReviewRequest {
  puzzle: {
    title: string;
    scenario: string;
    answer: string;
  };
  transcript: TranscriptTurn[];
  isWon: boolean;
  questionCount: number;
  /** When true, returns SSE with progress + complete events instead of one JSON. */
  stream?: boolean;
}

// Review tool_use schema has summary + key_moments[] + tip. key_moments
// is an array of objects so it doesn't surface as a closed "string field"
// from the detector — that's OK, we only care about driving summary and
// tip progress (the long ones).
const REVIEW_FIELDS = ["summary", "tip"] as const;

const SYSTEM_PROMPT = `你是一位海龟汤游戏的复盘教练。游戏结束后，玩家会带着完整对话历史来找你复盘。

你的任务：
1. 给出一句话总结（这局怎么样、用了多少轮）
2. 挑出 2-4 个关键时刻（好的提问、走错的方向、关键突破、卡住的点）
3. 给一条下次类似题目可以用的建议

写作要求：
- 中肯客观，不要一味夸。失败的局要直接指出错在哪。
- 引用对话内容时，用「」括起来，让玩家立刻找到对应回合。
- 关键时刻用 turn 编号定位（玩家提问算第 1 轮，第 2 轮，...）。
- summary ≤ 40 字，每个 key_moment.comment ≤ 60 字，tip ≤ 40 字。
- 不要透露汤底原文，但可以用「关键转折」「真正原因」之类的抽象指代。

你必须调用 submit_review 工具返回结果。`;

const SUBMIT_TOOL = {
  name: "submit_review",
  description: "Submit the AI review of a finished 海龟汤 game.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description: "一句话总结这局表现，≤ 40 字。",
      },
      key_moments: {
        type: "array",
        items: {
          type: "object",
          properties: {
            turn: {
              type: "integer",
              description: "玩家第几轮提问（从 1 开始）。",
            },
            kind: {
              type: "string",
              enum: ["good_question", "wrong_direction", "breakthrough", "got_stuck"],
              description: "这个时刻的类型。",
            },
            comment: {
              type: "string",
              description: "对这一回合的点评，≤ 60 字。",
            },
          },
          required: ["turn", "kind", "comment"],
        },
        minItems: 2,
        maxItems: 4,
      },
      tip: {
        type: "string",
        description: "下次类似题目可以用的一条建议，≤ 40 字。",
      },
    },
    required: ["summary", "key_moments", "tip"],
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
    return withCORS(jsonError(500, "config_missing", "ANTHROPIC_API_KEY not set."));
  }

  let payload: ReviewRequest;
  try {
    payload = (await req.json()) as ReviewRequest;
  } catch {
    return withCORS(jsonError(400, "invalid_json", "Request body must be JSON."));
  }

  // Minimal validation — fail fast on shapes the prompt can't recover from.
  if (!payload.puzzle?.scenario || !payload.puzzle?.answer) {
    return withCORS(jsonError(400, "missing_puzzle", "puzzle.scenario and puzzle.answer required."));
  }
  if (!Array.isArray(payload.transcript) || payload.transcript.length === 0) {
    return withCORS(jsonError(400, "missing_transcript", "transcript must be a non-empty array."));
  }

  const userPrompt = buildUserPrompt(payload);

  if (payload.stream) {
    return handleStreaming(apiKey, userPrompt);
  }

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
        max_tokens: 1200,
        // System prompt is shared across all reviews → cache it. Will silently
        // no-op today (system is ~500 tokens, well under Sonnet 4.6's 2048
        // minimum) but kicks in if we grow the rubric.
        system: [
          {
            type: "text",
            text: SYSTEM_PROMPT,
            cache_control: { type: "ephemeral" },
          },
        ],
        thinking: { type: "disabled" },
        // medium effort: needs to read a transcript carefully and pick out
        // moments — more thoughtful than gameplay verdicts, but no need to
        // burn full reasoning.
        output_config: { effort: "medium" },
        tools: [SUBMIT_TOOL],
        tool_choice: { type: "tool", name: "submit_review" },
        messages: [{ role: "user", content: userPrompt }],
      }),
    });
  } catch (e) {
    return withCORS(
      jsonError(502, "upstream_unreachable", `Failed to reach Anthropic: ${(e as Error).message}`),
    );
  }

  if (!upstream.ok) {
    const errText = await upstream.text();
    return withCORS(jsonError(upstream.status, "upstream_error", errText.slice(0, 500)));
  }

  const data = (await upstream.json()) as {
    content: Array<{ type: string; name?: string; input?: unknown }>;
  };

  const toolUse = data.content.find(
    (b) => b.type === "tool_use" && b.name === "submit_review",
  );
  if (!toolUse?.input) {
    return withCORS(
      jsonError(502, "tool_use_missing", "Claude did not return a submit_review tool call."),
    );
  }

  return withCORS(Response.json({ review: toolUse.input }));
}

/** See `handleStreaming` in generate-puzzle.ts for the design rationale. */
async function handleStreaming(apiKey: string, userPrompt: string): Promise<Response> {
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
        max_tokens: 1200,
        system: [
          { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
        ],
        thinking: { type: "disabled" },
        output_config: { effort: "medium" },
        tools: [SUBMIT_TOOL],
        tool_choice: { type: "tool", name: "submit_review" },
        stream: true,
        messages: [{ role: "user", content: userPrompt }],
      }),
    });
  } catch (e) {
    return withCORS(
      jsonError(502, "upstream_unreachable", `Failed to reach Anthropic: ${(e as Error).message}`),
    );
  }

  if (!upstream.ok || !upstream.body) {
    const errText = upstream.body ? await upstream.text() : "no body";
    return withCORS(jsonError(upstream.status, "upstream_error", errText.slice(0, 500)));
  }

  const detector = new FieldDetector(REVIEW_FIELDS);
  const encoder = new TextEncoder();
  const upstreamBody = upstream.body;

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const block of sseBlocks(upstreamBody)) {
          const parsed = parseSSEBlock(block);
          if (!parsed) continue;

          const data = parsed.data as {
            type?: string;
            delta?: { type?: string; partial_json?: string };
          };

          if (data.type === "content_block_delta" &&
              data.delta?.type === "input_json_delta" &&
              typeof data.delta.partial_json === "string") {
            const newlyClosed = detector.push(data.delta.partial_json);
            for (const event of newlyClosed) {
              controller.enqueue(encoder.encode(sseEvent({ name: "progress", data: event })));
            }
          } else if (data.type === "message_stop") {
            try {
              const review = JSON.parse(detector.full()) as Record<string, unknown>;
              controller.enqueue(
                encoder.encode(sseEvent({ name: "complete", data: { review } })),
              );
            } catch (e) {
              controller.enqueue(
                encoder.encode(sseEvent({
                  name: "error",
                  data: {
                    code: "parse_failed",
                    message: `Tool input did not parse: ${(e as Error).message}`,
                  },
                })),
              );
            }
            controller.close();
            return;
          }
        }
        controller.close();
      } catch (e) {
        controller.enqueue(
          encoder.encode(sseEvent({
            name: "error",
            data: { code: "stream_failed", message: (e as Error).message },
          })),
        );
        controller.close();
      }
    },
  });

  return withCORS(new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
    },
  }));
}

function buildUserPrompt(req: ReviewRequest): string {
  const lines: string[] = [
    `=== 题目 ===`,
    `标题：${req.puzzle.title}`,
    ``,
    `汤面（玩家看到的）：`,
    req.puzzle.scenario,
    ``,
    `汤底（完整真相，仅你可见）：`,
    req.puzzle.answer,
    ``,
    `=== 结局 ===`,
    req.isWon ? `玩家在第 ${req.questionCount} 轮揭开了真相。` : `玩家在 ${req.questionCount} 轮后放弃。`,
    ``,
    `=== 对话历史 ===`,
  ];

  // Number user turns so the model can reference them by `turn` index.
  let userTurnIndex = 0;
  for (const turn of req.transcript) {
    if (turn.role === "user") {
      userTurnIndex += 1;
      lines.push(`[第 ${userTurnIndex} 轮 玩家] ${turn.text}`);
    } else {
      const verdictLabel = turn.verdict ? ` (${turn.verdict})` : "";
      lines.push(`[主持人${verdictLabel}] ${turn.text || "(空)"}`);
    }
  }

  lines.push(``, `调用 submit_review 工具，给出复盘。`);
  return lines.join("\n");
}
