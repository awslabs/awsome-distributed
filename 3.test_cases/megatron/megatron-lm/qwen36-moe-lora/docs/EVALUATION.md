# Evaluation methodology and reference results

Two complementary gates evaluate the fine-tuned adapter against the base
model, targeting different failure modes.

## Inference setup

Both models are served by a single vLLM instance via the OpenAI-compatible
`/v1/chat/completions` API. The base is loaded by model name
(`Qwen/Qwen3.6-35B-A3B`); the adapter is loaded under the alias `tools` via
`--lora-modules tools=<path>` and queried by passing `model="tools"`.

All eval requests set `temperature=0.1` (near-deterministic), `max_tokens=512`,
and `chat_template_kwargs={"enable_thinking": False}` to disable Qwen's
`<think>` CoT preamble. Without the thinking-off flag, both models exhaust
token budget on reasoning prose and never emit a tool call.

## Tool-call output format

Qwen3.6 emits tool calls in Qwen-Agent XML form:

```
<tool_call>
<function=search_flights>
<parameter=origin>JFK</parameter>
<parameter=destination>SFO</parameter>
</function>
</tool_call>
```

This is NOT the format vLLM's `--tool-call-parser hermes` expects (Hermes
wants JSON-in-XML). In practice, vLLM leaves the `tool_calls` field empty and
the XML lands in `content`. The eval harness (`src/eval_function_calling.py`)
parses the XML itself with a regex, so scoring works regardless of whether
vLLM surfaces structured `tool_calls` on a given request.

## Gate 1 — Hand-crafted edge cases

Ten prompts exercising specific function-calling behaviors that a correctly
trained model should handle but base models often miss:

| # | Category |
|---|---|
| 1 | Simple single tool |
| 2 | camelCase schema (getUserProfile vs get_user_profile) |
| 3 | Nested object argument |
| 4 | Enum argument (celsius vs fahrenheit) |
| 5 | Multi-tool required (flight + hotel) |
| 6 | Array argument (list of emails) |
| 7 | Integer-type argument |
| 8 | Boolean flag |
| 9 | Ambiguous — should NOT call a tool |
| 10 | Decimal + currency |

A prompt passes if the model emits a parseable tool call with the expected
function name (or no tool call, for prompt #9). Runtime: ~2 minutes total.

### Reference results (reference run)

| Prompt | Base | LoRA |
|---|---|---|
| 1. Simple single tool | ❌ | ✅ |
| 2. camelCase schema | ✅ | ✅ |
| 3. Nested object | ✅ | ❌ |
| 4. Enum argument | ❌ | ✅ |
| 5. Multi-tool required | ❌ | ✅ |
| 6. Array argument | ✅ | ✅ |
| 7. Integer type | ✅ | ✅ |
| 8. Boolean flag | ✅ | ✅ |
| 9. Ambiguous | ✅ | ✅ |
| 10. Decimal + currency | ❌ | ✅ |
| **Total** | **6 / 10** | **9 / 10** |

LoRA wins on 4 prompts (1, 4, 5, 10), loses on 1 (3 — nested object). Net
improvement +3 prompts (+30 percentage points absolute).

The regression on prompt 3 is called out explicitly — fine-tuned adapters
often sharpen common patterns at the cost of rare ones. Mitigations discussed
in the TROUBLESHOOTING doc.

## Gate 2 — LLM-as-judge on xLAM validation

Sample 50 prompts from the xLAM held-out validation split
(`/fsx/datasets/validation.jsonl`). For each:

1. Send to base and to LoRA, collect both outputs.
2. **Randomize A/B position** (coin flip) — eliminates judge position bias.
3. Ask Claude Opus 4.7 via Bedrock: "which is better on (1) valid JSON/format,
   (2) correct tool + args, (3) no extraneous prose — A, B, or TIE?"
4. Map back to BASE / LORA / TIE.

Judge: `us.anthropic.claude-opus-4-7` (US cross-region inference profile).
Note: Opus 4.7 deprecated the `temperature` parameter — do not pass it in the
request body. Runtime: ~4 minutes for 50 samples.

### Reference results

| Outcome | Count | Share |
|---|---|---|
| LoRA wins | **47** | **94%** |
| Base wins | 3 | 6% |
| Ties | 0 | 0% |
| Errors | 0 | 0% |

Zero ties is striking — outputs were qualitatively distinguishable on every
prompt. The 94% win rate is in-distribution (xLAM validation shares the
training distribution's style), so it represents a near-best-case; Gate 1's
+30 pp on out-of-distribution edge cases is a more conservative signal.

## Reproducing

```bash
# With the published reference adapter (no training required):
export LORA_SOURCE=hf
export LORA_REPO=ying2022/qwen3-6-35b-xlam-tools-lora
./scripts/6.deploy-inference.sh
export GATE=all
./scripts/7.run-eval.sh

# Sample output:
# === Summary ===
#   gate1_base             6/10
#   gate1_lora             9/10
#   gate2_lora_wins        47/50
#   gate2_win_rate         94%
```

Expect small run-to-run variation on Gate 2 (±2 wins) due to judge stochasticity
even at `max_tokens=8`; Gate 1 is fully deterministic.
