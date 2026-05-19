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
import { FieldDetector, sseEvent, parseSSEBlock, sseBlocks } from "../../lib/tool-stream.js";

export const config = { runtime: "edge" };

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-4-6";

type Difficulty = "简单" | "中等" | "困难";

interface GenerateRequest {
  idea: string;
  difficulty?: Difficulty;
  /** When true, returns SSE with progress + complete events instead of one JSON. */
  stream?: boolean;
}

const PUZZLE_FIELDS = ["title", "scenario", "answer", "hint", "difficulty"] as const;

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
- 钩子来自反常识/反预期，不是来自血腥猎奇。死亡题材已经被用烂了，优先非死亡场景。
- 避免依赖"刚好"、"碰巧"、"恰好"这类弱因果。每个转折都要有真实动机或物理约束。
- 难度判断：
  - 简单：单一转折点，3-5 轮提问可解
  - 中等：2 个转折点或需要跨场景联想
  - 困难：多层嵌套，需要打破思维定式

---

下面是三个高质量参考示例（用 submit_puzzle 工具调用的形式），展示标准结构、质量与难度梯度。生成时**不要**直接复用这些场景，请基于用户的 idea 创作全新题目。

示例 1（简单）：
\`\`\`
submit_puzzle({
  "title": "公园里的湿长椅",
  "scenario": "李明清晨在公园散步，发现一条长椅是湿的，周围的地面和其他长椅却都是干的。昨晚没下雨，洒水车也没经过这里。他想了一会儿，笑着坐了下去。",
  "answer": "前一晚有一对情侣在长椅上看星星，女生因为感动哭了很久，眼泪打湿了长椅一侧；男生帮她擦了脸，又把自己的外套铺在长椅上，吸饱了泪水后忘了带走。早晨外套被环卫工人收走了，但湿气还在长椅的木板缝里没干透。李明是这个情侣的朋友，从女生发的朋友圈里大概知道了昨晚发生的事，看到湿长椅会心一笑就坐下了。",
  "hint": "湿的来源不一定是雨",
  "difficulty": "简单"
})
\`\`\`

示例 2（中等）：
\`\`\`
submit_puzzle({
  "title": "总是迟到 3 分钟的电车",
  "scenario": "东京一条支线电车每天傍晚的同一班次永远迟到 3 分钟，无论刮风下雨从不例外。铁路公司查过信号、调度、司机记录，一切正常。直到有一天，这班车准时到了，第二天报纸上出现了一则讣告。",
  "answer": "这班车的司机十年前的同一时间，在前一站短暂停车 3 分钟——为了等一位每天都来送便当给他的妻子，她身体不好，走得慢。后来他升任司机长，自己开这班车，便每天悄悄延后 3 分钟，作为对妻子早逝的纪念，公司其实知情但默许了。讣告里去世的是这位司机长，他在退休前一天最后一次开这班车，第一次按表准时到站——作为对妻子的告别。",
  "hint": "迟到不是故障，是仪式",
  "difficulty": "中等"
})
\`\`\`

示例 3（困难）：
\`\`\`
submit_puzzle({
  "title": "录音棚里的两个我",
  "scenario": "钢琴家陈宇独自在录音棚录制专辑。回放时，他清楚地听到录音里有两架钢琴在弹同一段旋律，且节奏完全同步、音色却有微妙差异。录音棚的所有设备都正常，监控摄像头显示当时房间里只有他一个人。",
  "answer": "陈宇有一个失散多年的双胞胎哥哥，哥哥小时候因家庭原因被另一家收养，两人都成为了钢琴家但互不相识。这家录音棚的隔壁就是哥哥常用的工作室，两间录音棚共用一面墙。当天哥哥正好在隔壁弹同一首曲子——这首曲子是他们生母生前最爱听的，两兄弟在不同的人生轨迹里都从养母/养父那里学到了同样的版本。隔音不完美的墙让哥哥的琴声以极低音量渗入这边的录音，因为节奏由相同的童年记忆驱动，所以同步得几乎完美。陈宇后来去隔壁敲门，第一次见到了哥哥。",
  "hint": "墙的另一边",
  "difficulty": "困难"
})
\`\`\`

---

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
        max_tokens: 1500,
        // System prompt as text-block array so we can attach cache_control.
        // tools render before system, so this one breakpoint caches tools +
        // system together. The few-shot examples in SYSTEM_PROMPT push the
        // prefix over Sonnet 4.6's 2048-token minimum; verify via
        // response.usage.cache_read_input_tokens.
        system: [
          {
            type: "text",
            text: SYSTEM_PROMPT,
            cache_control: { type: "ephemeral" },
          },
        ],
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

/**
 * Streaming variant: opens an SSE response to the client and translates
 * Anthropic's upstream stream into a simplified `progress` / `complete`
 * sequence. Progress events fire as each known field of the tool input
 * finishes; complete fires once at the end with the assembled puzzle.
 *
 * If Anthropic returns a non-200, we close the stream with an `error`
 * event rather than throwing — the client is already mid-iteration and
 * can't see a different HTTP status.
 */
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
        max_tokens: 1500,
        system: [
          { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
        ],
        thinking: { type: "disabled" },
        output_config: { effort: "medium" },
        tools: [SUBMIT_TOOL],
        tool_choice: { type: "tool", name: "submit_puzzle" },
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

  // Pipe through a TransformStream so we can write progress events as we go
  // and the client receives them in real time. Edge runtime is ReadableStream-
  // native — no Node Buffer dance needed.
  const detector = new FieldDetector(PUZZLE_FIELDS);
  const encoder = new TextEncoder();
  const upstreamBody = upstream.body;

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const block of sseBlocks(upstreamBody)) {
          const parsed = parseSSEBlock(block);
          if (!parsed) continue;

          // Anthropic's tool_use stream sends input deltas as
          // {type: "content_block_delta", delta: {type: "input_json_delta", partial_json: "..."}}
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
            // Final parse: the accumulated buffer should be the complete
            // tool input JSON. If parsing fails we still emit an error
            // event rather than letting the client hang.
            try {
              const puzzle = JSON.parse(detector.full()) as Record<string, unknown>;
              controller.enqueue(
                encoder.encode(sseEvent({ name: "complete", data: { puzzle } })),
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
        // Stream ended without a message_stop — best-effort close.
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

function buildUserPrompt(req: GenerateRequest): string {
  const lines = [`请基于以下想法生成一个海龟汤题目：`, ``, req.idea.trim()];
  if (req.difficulty) {
    lines.push("", `目标难度：${req.difficulty}`);
  }
  lines.push("", "调用 submit_puzzle 工具返回结果。");
  return lines.join("\n");
}
