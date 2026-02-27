#!/usr/bin/env python3
"""
Offline evaluation harness for the SoundBridge cleaner.

Features:
- zh-CN force-cleaner evaluation
- yue dual-track evaluation (skip baseline + force cleaner)
- OpenAI LLM judge (default) with deterministic JSON scoring
- Heuristic judge fallback for local smoke checks

Outputs:
- cleaner_outputs.jsonl
- judge_scores.jsonl
- summary.json
- summary.zh-CN.json
- summary.yue.skip.json
- summary.yue.force.json
- summary.md
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import os
import re
import statistics
import textwrap
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


CLEANER_PREFIXES = ("清理后：", "清理后:", "清理后: ", "清理后： ")

ZH_FILLERS = (
    "那个",
    "就是",
    "然后",
    "嗯",
    "呃",
    "吧",
    "你知道",
    "怎么说",
)

YUE_FILLERS = (
    "即系",
    "跟住",
    "咁",
    "呢个",
    "然后",
    "呃",
    "呀",
    "啦",
)


@dataclasses.dataclass(frozen=True)
class EvalCase:
    id: str
    locale: str
    category: str
    raw_text: str
    must_keep: list[str]
    expected_risks: list[str]
    notes: str


@dataclasses.dataclass
class CleanerOutput:
    case_id: str
    locale: str
    track: str
    category: str
    raw_text: str
    cleaned_text: str
    force_provider: str
    elapsed_ms: float
    error: str | None = None


@dataclasses.dataclass
class JudgeScore:
    case_id: str
    locale: str
    track: str
    category: str
    faithfulness: float
    disfluency_cleanup: float
    logic_coherence: float
    readability: float
    hallucination_penalty: float
    must_keep_violation: bool
    must_keep_violations: list[str]
    hallucination: bool
    confidence: float
    notes: str
    overall: float
    judge_provider: str
    judge_model: str
    error: str | None = None


class OpenAIChatAPI:
    def __init__(
        self,
        api_key: str,
        model: str,
        base_url: str = "https://api.openai.com/v1",
        timeout_s: int = 120,
        max_retries: int = 2,
        retry_backoff_s: float = 1.5,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.timeout_s = timeout_s
        self.max_retries = max_retries
        self.retry_backoff_s = retry_backoff_s

    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.base_url}{path}"
        body = json.dumps(payload).encode("utf-8")
        last_error: Exception | None = None

        for attempt in range(self.max_retries + 1):
            request = urllib.request.Request(
                url=url,
                data=body,
                method="POST",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=self.timeout_s) as response:
                    data = response.read().decode("utf-8")
                return json.loads(data)
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="ignore")
                last_error = RuntimeError(f"OpenAI HTTP {exc.code}: {detail}")
                retryable = exc.code in (429, 500, 502, 503, 504)
                if retryable and attempt < self.max_retries:
                    time.sleep(self.retry_backoff_s * (2**attempt))
                    continue
                raise last_error from exc
            except urllib.error.URLError as exc:
                last_error = RuntimeError(f"OpenAI request failed: {exc}")
                if attempt < self.max_retries:
                    time.sleep(self.retry_backoff_s * (2**attempt))
                    continue
                raise last_error from exc

        assert last_error is not None
        raise last_error

    @staticmethod
    def _extract_message_text(message_content: Any) -> str:
        if isinstance(message_content, str):
            return message_content
        if isinstance(message_content, list):
            parts: list[str] = []
            for block in message_content:
                if isinstance(block, dict):
                    text = block.get("text")
                    if isinstance(text, str):
                        parts.append(text)
            return "".join(parts)
        return str(message_content)

    def chat_text(
        self,
        messages: list[dict[str, str]],
        temperature: float,
        max_tokens: int,
    ) -> str:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        result = self._post("/chat/completions", payload)
        choices = result.get("choices") or []
        if not choices:
            raise RuntimeError(f"OpenAI returned empty choices: {result}")
        message = choices[0].get("message", {})
        return self._extract_message_text(message.get("content", "")).strip()

    def chat_json(
        self,
        messages: list[dict[str, str]],
        temperature: float,
        max_tokens: int,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "response_format": {"type": "json_object"},
        }
        result = self._post("/chat/completions", payload)
        choices = result.get("choices") or []
        if not choices:
            raise RuntimeError(f"OpenAI returned empty choices: {result}")
        message = choices[0].get("message", {})
        text = self._extract_message_text(message.get("content", "")).strip()
        return parse_json_object(text)


class CleanerRunner:
    def clean(self, raw_text: str, locale: str) -> str:
        raise NotImplementedError


class SkipCleanerRunner(CleanerRunner):
    def clean(self, raw_text: str, locale: str) -> str:
        return raw_text


class OpenAICleanerRunner(CleanerRunner):
    def __init__(
        self,
        api: OpenAIChatAPI,
        temperature: float,
        max_tokens: int,
    ) -> None:
        self.api = api
        self.temperature = temperature
        self.max_tokens = max_tokens

    def clean(self, raw_text: str, locale: str) -> str:
        prompt = build_cleaner_prompt(raw_text=raw_text, locale=locale)
        response = self.api.chat_text(
            messages=[
                {
                    "role": "system",
                    "content": "你是语音转文字的后处理助手。输出只包含清理后的文本。",
                },
                {"role": "user", "content": prompt},
            ],
            temperature=self.temperature,
            max_tokens=self.max_tokens,
        )
        normalized = normalize_cleaner_output(raw_text, response)
        return normalized if normalized else raw_text


class LocalMLXCleanerRunner(CleanerRunner):
    def __init__(self, model_dir: Path, temperature: float, max_tokens: int) -> None:
        self.model_dir = model_dir
        self.temperature = temperature
        self.max_tokens = max_tokens
        self._loaded = False
        self._model: Any = None
        self._tokenizer: Any = None
        self._load_fn: Any = None
        self._generate_fn: Any = None

    def _ensure_loaded(self) -> None:
        if self._loaded:
            return
        try:
            from mlx_lm import generate, load  # type: ignore
        except Exception as exc:  # pragma: no cover - import availability depends on env
            raise RuntimeError(
                "mlx_lm is not installed. Install with: pip install mlx-lm"
            ) from exc

        self._load_fn = load
        self._generate_fn = generate
        self._model, self._tokenizer = self._load_fn(str(self.model_dir))
        self._loaded = True

    def clean(self, raw_text: str, locale: str) -> str:
        self._ensure_loaded()
        prompt = build_cleaner_prompt(raw_text=raw_text, locale=locale)
        from mlx_lm.sample_utils import make_sampler  # type: ignore

        prompt_input: str | list[int] = prompt
        if hasattr(self._tokenizer, "apply_chat_template"):
            try:
                prompt_input = self._tokenizer.apply_chat_template(
                    [{"role": "user", "content": prompt}],
                    tokenize=False,
                    add_generation_prompt=True,
                )
            except Exception:
                prompt_input = prompt

        sampler = make_sampler(temp=self.temperature)
        result = self._generate_fn(
            self._model,
            self._tokenizer,
            prompt=prompt_input,
            max_tokens=self.max_tokens,
            sampler=sampler,
            verbose=False,
        )
        normalized: str
        if isinstance(result, str):
            normalized = normalize_cleaner_output(raw_text, result)
            return normalized if normalized else raw_text
        if isinstance(result, tuple):
            for item in result:
                if isinstance(item, str) and item.strip():
                    normalized = normalize_cleaner_output(raw_text, item)
                    return normalized if normalized else raw_text
        normalized = normalize_cleaner_output(raw_text, str(result))
        return normalized if normalized else raw_text


class Judge:
    def score(self, case: EvalCase, track: str, cleaned_text: str) -> JudgeScore:
        raise NotImplementedError


class HeuristicJudge(Judge):
    def score(self, case: EvalCase, track: str, cleaned_text: str) -> JudgeScore:
        cleaned = cleaned_text.strip()
        missing = [item for item in case.must_keep if item and item not in cleaned]
        must_keep_violation = bool(missing)

        raw_len = max(1, len(case.raw_text))
        cleaned_len = max(1, len(cleaned))
        growth = cleaned_len / raw_len

        raw_fillers = count_fillers(case.raw_text, case.locale)
        cleaned_fillers = count_fillers(cleaned, case.locale)

        if raw_fillers > 0:
            reduction = (raw_fillers - cleaned_fillers) / raw_fillers
            disfluency = clamp_score(2.0 + 3.0 * reduction)
        else:
            disfluency = 4.2 if growth <= 1.1 else 3.4

        keep_ratio = 1.0
        if case.must_keep:
            keep_ratio = (len(case.must_keep) - len(missing)) / len(case.must_keep)

        lexical_overlap = char_overlap_ratio(case.raw_text, cleaned)
        faithfulness = clamp_score(5.0 * (0.65 * keep_ratio + 0.35 * lexical_overlap))

        punctuation_bonus = 0.5 if re.search(r"[。！？!?]", cleaned) else 0.0
        long_repetition_penalty = 0.8 if has_heavy_repetition(cleaned) else 0.0
        logic = clamp_score(3.4 + punctuation_bonus - long_repetition_penalty)

        readability = clamp_score(
            3.0
            + (0.8 if punctuation_bonus > 0 else 0.0)
            - (0.6 if growth > 1.4 else 0.0)
            - (0.6 if has_heavy_repetition(cleaned) else 0.0)
        )

        hallucination = growth > 1.45 and lexical_overlap < 0.55
        hallucination_penalty = 1.0 if hallucination else 0.0

        overall = weighted_overall(
            faithfulness=faithfulness,
            disfluency_cleanup=disfluency,
            logic_coherence=logic,
            readability=readability,
            hallucination_penalty=hallucination_penalty,
        )

        notes = "heuristic fallback"
        if missing:
            notes += f"; missing must_keep={missing}"

        return JudgeScore(
            case_id=case.id,
            locale=case.locale,
            track=track,
            category=case.category,
            faithfulness=faithfulness,
            disfluency_cleanup=disfluency,
            logic_coherence=logic,
            readability=readability,
            hallucination_penalty=hallucination_penalty,
            must_keep_violation=must_keep_violation,
            must_keep_violations=missing,
            hallucination=hallucination,
            confidence=0.35,
            notes=notes,
            overall=overall,
            judge_provider="heuristic",
            judge_model="heuristic-v1",
            error=None,
        )


class OpenAIJudge(Judge):
    def __init__(
        self,
        api: OpenAIChatAPI,
        prompt_text: str,
        temperature: float,
        max_tokens: int,
    ) -> None:
        self.api = api
        self.prompt_text = prompt_text
        self.temperature = temperature
        self.max_tokens = max_tokens

    def score(self, case: EvalCase, track: str, cleaned_text: str) -> JudgeScore:
        user_payload = {
            "case_id": case.id,
            "locale": case.locale,
            "track": track,
            "category": case.category,
            "raw_text": case.raw_text,
            "cleaned_text": cleaned_text,
            "must_keep": case.must_keep,
            "expected_risks": case.expected_risks,
            "notes": case.notes,
        }

        response = self.api.chat_json(
            messages=[
                {"role": "system", "content": self.prompt_text},
                {
                    "role": "user",
                    "content": json.dumps(user_payload, ensure_ascii=False),
                },
            ],
            temperature=self.temperature,
            max_tokens=self.max_tokens,
        )
        normalized = normalize_judge_payload(response)
        overall = weighted_overall(
            faithfulness=normalized["faithfulness"],
            disfluency_cleanup=normalized["disfluency_cleanup"],
            logic_coherence=normalized["logic_coherence"],
            readability=normalized["readability"],
            hallucination_penalty=normalized["hallucination_penalty"],
        )

        return JudgeScore(
            case_id=case.id,
            locale=case.locale,
            track=track,
            category=case.category,
            faithfulness=normalized["faithfulness"],
            disfluency_cleanup=normalized["disfluency_cleanup"],
            logic_coherence=normalized["logic_coherence"],
            readability=normalized["readability"],
            hallucination_penalty=normalized["hallucination_penalty"],
            must_keep_violation=normalized["must_keep_violation"],
            must_keep_violations=normalized["must_keep_violations"],
            hallucination=normalized["hallucination"],
            confidence=normalized["confidence"],
            notes=normalized["notes"],
            overall=overall,
            judge_provider="openai",
            judge_model=self.api.model,
            error=None,
        )


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Run cleaner evaluation on zh-CN and yue synthetic datasets."
    )
    parser.add_argument(
        "--cases-zh",
        type=Path,
        default=script_dir / "cases.zh-CN.synthetic.jsonl",
        help="Path to zh-CN cases jsonl.",
    )
    parser.add_argument(
        "--cases-yue",
        type=Path,
        default=script_dir / "cases.yue.synthetic.jsonl",
        help="Path to yue cases jsonl.",
    )
    parser.add_argument(
        "--yue-mode",
        choices=("skip", "force", "both"),
        default="both",
        help="Run yue skip baseline, force cleaner, or both.",
    )
    parser.add_argument(
        "--force-cleaner-provider",
        choices=("local-mlx", "openai", "noop"),
        default="openai",
        help="Cleaner provider for force track.",
    )
    parser.add_argument(
        "--force-cleaner-model-dir",
        type=Path,
        default=Path("models/qwen2.5-0.5b-4bit"),
        help="Local MLX model directory when using local-mlx force cleaner.",
    )
    parser.add_argument(
        "--force-cleaner-model",
        default="gpt-4.1-mini",
        help="OpenAI model for force cleaner when provider=openai.",
    )
    parser.add_argument(
        "--force-cleaner-temperature",
        type=float,
        default=0.1,
        help="Force cleaner temperature.",
    )
    parser.add_argument(
        "--force-cleaner-max-tokens",
        type=int,
        default=256,
        help="Max output tokens for force cleaner.",
    )
    parser.add_argument(
        "--judge-provider",
        choices=("openai", "heuristic"),
        default="openai",
        help="Judge provider.",
    )
    parser.add_argument(
        "--judge-model",
        default="gpt-4.1-mini",
        help="OpenAI model for judge when judge-provider=openai.",
    )
    parser.add_argument(
        "--judge-temperature",
        type=float,
        default=0.0,
        help="Judge temperature.",
    )
    parser.add_argument(
        "--judge-max-tokens",
        type=int,
        default=512,
        help="Max output tokens for judge response.",
    )
    parser.add_argument(
        "--judge-prompt",
        type=Path,
        default=script_dir / "judge_prompt.md",
        help="Prompt template for judge.",
    )
    parser.add_argument(
        "--openai-api-key",
        default=os.getenv("OPENAI_API_KEY", ""),
        help="OpenAI API key. Defaults to OPENAI_API_KEY env.",
    )
    parser.add_argument(
        "--openai-base-url",
        default=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"),
        help="OpenAI base URL.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/eval/cleaner"),
        help="Output directory for reports.",
    )
    parser.add_argument(
        "--max-cases",
        type=int,
        default=0,
        help="Cap case count per language for quick iteration; 0 means all.",
    )
    parser.add_argument(
        "--sleep-ms",
        type=int,
        default=0,
        help="Sleep between samples to avoid request bursts.",
    )
    parser.add_argument(
        "--allow-cleaner-errors",
        action="store_true",
        help="Continue run when force cleaner errors occur (default: fail fast).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Verbose progress logs.",
    )
    return parser.parse_args()


def parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    try:
        obj = json.loads(stripped)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass

    fence_match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", stripped, flags=re.S)
    if fence_match:
        obj = json.loads(fence_match.group(1))
        if isinstance(obj, dict):
            return obj

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start >= 0 and end > start:
        obj = json.loads(stripped[start : end + 1])
        if isinstance(obj, dict):
            return obj

    raise ValueError(f"Could not parse JSON object from response: {text!r}")


def normalize_judge_payload(payload: dict[str, Any]) -> dict[str, Any]:
    def as_float(key: str, default: float = 0.0) -> float:
        value = payload.get(key, default)
        try:
            return float(value)
        except (TypeError, ValueError):
            return float(default)

    def as_bool(key: str, default: bool = False) -> bool:
        value = payload.get(key, default)
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in {"true", "1", "yes", "y"}
        return bool(value)

    must_keep_violations = payload.get("must_keep_violations", [])
    if not isinstance(must_keep_violations, list):
        must_keep_violations = []
    must_keep_violations = [str(x) for x in must_keep_violations]

    notes = payload.get("notes", "")
    if not isinstance(notes, str):
        notes = str(notes)

    return {
        "faithfulness": clamp_score(as_float("faithfulness")),
        "disfluency_cleanup": clamp_score(as_float("disfluency_cleanup")),
        "logic_coherence": clamp_score(as_float("logic_coherence")),
        "readability": clamp_score(as_float("readability")),
        "hallucination_penalty": clamp_penalty(as_float("hallucination_penalty")),
        "must_keep_violation": as_bool("must_keep_violation", False),
        "must_keep_violations": must_keep_violations,
        "hallucination": as_bool("hallucination", False),
        "confidence": clamp_score(as_float("confidence", 3.0)),
        "notes": notes,
    }


def weighted_overall(
    faithfulness: float,
    disfluency_cleanup: float,
    logic_coherence: float,
    readability: float,
    hallucination_penalty: float,
) -> float:
    score = (
        0.4 * faithfulness
        + 0.25 * disfluency_cleanup
        + 0.2 * logic_coherence
        + 0.15 * readability
        - hallucination_penalty
    )
    return round(clamp_score(score), 4)


def clamp_score(value: float) -> float:
    return max(0.0, min(5.0, float(value)))


def clamp_penalty(value: float) -> float:
    return max(0.0, min(2.0, float(value)))


def strip_cleaner_prefix(text: str) -> str:
    candidate = text.strip()
    for prefix in CLEANER_PREFIXES:
        if candidate.startswith(prefix):
            candidate = candidate[len(prefix) :].strip()
            break
    return candidate


def normalize_cleaner_output(raw_text: str, generated_text: str) -> str:
    """
    Normalize noisy cleaner outputs.

    Typical artifacts:
    - "清理后的文本：" style labels
    - "raw_text + cleaned_text" concatenated in one response
    """
    text = generated_text.strip()
    if not text:
        return text

    marker_pattern = r"(?:清理后(?:的)?文本|清理文本|清理结果)\s*[：:]\s*"
    marker_matches = list(re.finditer(marker_pattern, text))
    if marker_matches:
        text = text[marker_matches[-1].end() :].strip()

    raw = raw_text.strip()
    if raw and text.startswith(raw):
        tail = text[len(raw) :].strip()
        if tail:
            text = tail

    return strip_cleaner_prefix(text).strip()


def count_fillers(text: str, locale: str) -> int:
    fillers = YUE_FILLERS if locale.startswith("yue") else ZH_FILLERS
    return sum(text.count(token) for token in fillers)


def char_overlap_ratio(raw_text: str, cleaned_text: str) -> float:
    raw_chars = {c for c in raw_text if not c.isspace()}
    cleaned_chars = {c for c in cleaned_text if not c.isspace()}
    if not raw_chars:
        return 1.0
    return len(raw_chars & cleaned_chars) / len(raw_chars)


def has_heavy_repetition(text: str) -> bool:
    text = text.strip()
    if not text:
        return False
    return bool(re.search(r"(.{2,8})\1{2,}", text))


def build_cleaner_prompt(raw_text: str, locale: str) -> str:
    lang_name = "粤语" if locale.startswith("yue") else "普通话"
    return textwrap.dedent(
        f"""\
        你是语音转文字的后处理助手。请清理以下{lang_name}语音识别文本：
        1. 删除口水话和重复词
        2. 修正明显的语音识别错误
        3. 保留所有实质内容，不要改变原意
        4. 保留时间、数字、药名、地点等关键信息
        5. 只输出清理后的文本，不要加任何前缀或说明

        原文：{raw_text}
        """
    )


def load_cases(path: Path, expected_locale_prefix: str, max_cases: int) -> list[EvalCase]:
    if not path.exists():
        raise FileNotFoundError(f"Cases file not found: {path}")
    cases: list[EvalCase] = []
    with path.open("r", encoding="utf-8") as fp:
        for line_no, line in enumerate(fp, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            obj = json.loads(line)
            locale = str(obj.get("locale", ""))
            if not locale.startswith(expected_locale_prefix):
                raise ValueError(
                    f"{path}:{line_no} locale={locale!r} does not match "
                    f"expected prefix {expected_locale_prefix!r}"
                )
            cases.append(
                EvalCase(
                    id=str(obj["id"]),
                    locale=locale,
                    category=str(obj["category"]),
                    raw_text=str(obj["raw_text"]),
                    must_keep=[str(x) for x in obj.get("must_keep", [])],
                    expected_risks=[str(x) for x in obj.get("expected_risks", [])],
                    notes=str(obj.get("notes", "")),
                )
            )
    if max_cases > 0:
        return cases[:max_cases]
    return cases


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as fp:
        for row in rows:
            fp.write(json.dumps(row, ensure_ascii=False) + "\n")


def summarize_scores(scores: list[JudgeScore], track: str) -> dict[str, Any]:
    if not scores:
        return {
            "track": track,
            "count": 0,
            "avg_overall": 0.0,
            "avg_faithfulness": 0.0,
            "avg_disfluency_cleanup": 0.0,
            "avg_logic_coherence": 0.0,
            "avg_readability": 0.0,
            "must_keep_violation_rate": 0.0,
            "hallucination_rate": 0.0,
            "category_breakdown": {},
            "top_failures": [],
        }

    def mean(values: list[float]) -> float:
        return round(statistics.mean(values), 4)

    by_category: dict[str, list[JudgeScore]] = {}
    for item in scores:
        by_category.setdefault(item.category, []).append(item)

    category_breakdown = {
        category: {
            "count": len(items),
            "avg_overall": mean([x.overall for x in items]),
            "must_keep_violation_rate": round(
                100.0 * sum(1 for x in items if x.must_keep_violation) / len(items), 2
            ),
            "hallucination_rate": round(
                100.0 * sum(1 for x in items if x.hallucination) / len(items), 2
            ),
        }
        for category, items in sorted(by_category.items())
    }

    top_failures = sorted(scores, key=lambda x: (x.overall, x.case_id))[:5]
    return {
        "track": track,
        "count": len(scores),
        "avg_overall": mean([x.overall for x in scores]),
        "avg_faithfulness": mean([x.faithfulness for x in scores]),
        "avg_disfluency_cleanup": mean([x.disfluency_cleanup for x in scores]),
        "avg_logic_coherence": mean([x.logic_coherence for x in scores]),
        "avg_readability": mean([x.readability for x in scores]),
        "must_keep_violation_rate": round(
            100.0 * sum(1 for x in scores if x.must_keep_violation) / len(scores), 2
        ),
        "hallucination_rate": round(
            100.0 * sum(1 for x in scores if x.hallucination) / len(scores), 2
        ),
        "category_breakdown": category_breakdown,
        "top_failures": [
            {
                "case_id": x.case_id,
                "locale": x.locale,
                "category": x.category,
                "overall": x.overall,
                "must_keep_violations": x.must_keep_violations,
                "hallucination": x.hallucination,
                "notes": x.notes,
            }
            for x in top_failures
        ],
    }


def make_track_gate_report(
    zh_force: dict[str, Any] | None,
    yue_skip: dict[str, Any] | None,
    yue_force: dict[str, Any] | None,
) -> dict[str, Any]:
    report: dict[str, Any] = {}
    if zh_force is not None:
        report["zh_force_gate"] = {
            "avg_overall_gte_3_8": zh_force["avg_overall"] >= 3.8,
            "must_keep_violation_rate_lte_8": zh_force["must_keep_violation_rate"] <= 8.0,
            "hallucination_rate_lte_5": zh_force["hallucination_rate"] <= 5.0,
        }
        report["zh_force_pass"] = all(report["zh_force_gate"].values())

    if yue_skip is not None and yue_force is not None:
        report["yue_force_vs_skip_gate"] = {
            "avg_overall_improves_by_0_3": (
                yue_force["avg_overall"] >= yue_skip["avg_overall"] + 0.3
            ),
            "must_keep_violation_not_worse": (
                yue_force["must_keep_violation_rate"]
                <= yue_skip["must_keep_violation_rate"]
            ),
            "hallucination_not_worse_plus_2": (
                yue_force["hallucination_rate"]
                <= yue_skip["hallucination_rate"] + 2.0
            ),
        }
        report["yue_force_recommend_enable"] = all(
            report["yue_force_vs_skip_gate"].values()
        )
    return report


def format_summary_markdown(
    summary: dict[str, Any],
    outputs_path: Path,
    scores_path: Path,
) -> str:
    lines: list[str] = []
    lines.append("# Cleaner Evaluation Summary")
    lines.append("")
    lines.append("## Outputs")
    lines.append(f"- cleaner outputs: `{outputs_path}`")
    lines.append(f"- judge scores: `{scores_path}`")
    lines.append("")

    tracks: list[str] = []
    for key in ("zh_force", "yue_skip", "yue_force"):
        if key in summary:
            tracks.append(key)

    for track_key in tracks:
        s = summary[track_key]
        lines.append(f"## {track_key}")
        lines.append(f"- count: {s['count']}")
        lines.append(f"- avg_overall: {s['avg_overall']}")
        lines.append(f"- avg_faithfulness: {s['avg_faithfulness']}")
        lines.append(f"- avg_disfluency_cleanup: {s['avg_disfluency_cleanup']}")
        lines.append(f"- avg_logic_coherence: {s['avg_logic_coherence']}")
        lines.append(f"- avg_readability: {s['avg_readability']}")
        lines.append(f"- must_keep_violation_rate: {s['must_keep_violation_rate']}%")
        lines.append(f"- hallucination_rate: {s['hallucination_rate']}%")
        lines.append("")

        if s.get("top_failures"):
            lines.append("Top failures:")
            for failure in s["top_failures"]:
                lines.append(
                    "- "
                    f"{failure['case_id']} | overall={failure['overall']} | "
                    f"must_keep_violations={failure['must_keep_violations']} | "
                    f"hallucination={failure['hallucination']}"
                )
            lines.append("")

    if "gate_report" in summary:
        lines.append("## Gates")
        for key, value in summary["gate_report"].items():
            if isinstance(value, dict):
                lines.append(f"- {key}:")
                for sub_key, sub_value in value.items():
                    lines.append(f"  - {sub_key}: {sub_value}")
            else:
                lines.append(f"- {key}: {value}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def to_dict(obj: Any) -> dict[str, Any]:
    return dataclasses.asdict(obj)


def main() -> int:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    prompt_text = ""
    if args.judge_provider == "openai":
        if not args.openai_api_key:
            raise RuntimeError(
                "OPENAI_API_KEY is required when --judge-provider=openai "
                "(or pass --judge-provider heuristic)."
            )
        prompt_text = args.judge_prompt.read_text(encoding="utf-8")

    zh_cases = load_cases(args.cases_zh, expected_locale_prefix="zh", max_cases=args.max_cases)
    yue_cases = load_cases(args.cases_yue, expected_locale_prefix="yue", max_cases=args.max_cases)

    if args.verbose:
        print(f"[eval] loaded zh cases: {len(zh_cases)}")
        print(f"[eval] loaded yue cases: {len(yue_cases)}")

    skip_cleaner = SkipCleanerRunner()

    openai_for_force: OpenAIChatAPI | None = None
    if args.force_cleaner_provider == "openai":
        if not args.openai_api_key:
            raise RuntimeError(
                "OPENAI_API_KEY is required when --force-cleaner-provider=openai "
                "(or switch to local-mlx/noop)."
            )
        openai_for_force = OpenAIChatAPI(
            api_key=args.openai_api_key,
            model=args.force_cleaner_model,
            base_url=args.openai_base_url,
        )

    if args.force_cleaner_provider == "openai":
        force_cleaner: CleanerRunner = OpenAICleanerRunner(
            api=openai_for_force,  # type: ignore[arg-type]
            temperature=args.force_cleaner_temperature,
            max_tokens=args.force_cleaner_max_tokens,
        )
    elif args.force_cleaner_provider == "local-mlx":
        force_cleaner = LocalMLXCleanerRunner(
            model_dir=args.force_cleaner_model_dir,
            temperature=args.force_cleaner_temperature,
            max_tokens=args.force_cleaner_max_tokens,
        )
    else:
        force_cleaner = SkipCleanerRunner()

    if args.judge_provider == "openai":
        judge_api = OpenAIChatAPI(
            api_key=args.openai_api_key,
            model=args.judge_model,
            base_url=args.openai_base_url,
        )
        judge: Judge = OpenAIJudge(
            api=judge_api,
            prompt_text=prompt_text,
            temperature=args.judge_temperature,
            max_tokens=args.judge_max_tokens,
        )
    else:
        judge = HeuristicJudge()

    jobs: list[tuple[str, EvalCase, CleanerRunner, str]] = []
    for case in zh_cases:
        jobs.append(("zh_force", case, force_cleaner, "force"))

    if args.yue_mode in {"skip", "both"}:
        for case in yue_cases:
            jobs.append(("yue_skip", case, skip_cleaner, "skip"))

    if args.yue_mode in {"force", "both"}:
        for case in yue_cases:
            jobs.append(("yue_force", case, force_cleaner, "force"))

    cleaner_outputs: list[CleanerOutput] = []
    judge_scores: list[JudgeScore] = []

    for index, (track, case, runner, mode) in enumerate(jobs, start=1):
        if args.verbose:
            print(
                f"[eval] {index}/{len(jobs)} track={track} case={case.id} "
                f"locale={case.locale} mode={mode}"
            )

        start = time.perf_counter()
        cleaner_error: str | None = None
        try:
            cleaned = runner.clean(case.raw_text, case.locale).strip()
            if not cleaned:
                cleaned = case.raw_text
        except Exception as exc:
            cleaned = case.raw_text
            cleaner_error = str(exc)
            if mode == "force" and not args.allow_cleaner_errors:
                raise RuntimeError(
                    f"force cleaner failed on case={case.id}, track={track}: {cleaner_error}. "
                    "Use --allow-cleaner-errors to continue."
                ) from exc

        elapsed_ms = (time.perf_counter() - start) * 1000.0

        cleaner_output = CleanerOutput(
            case_id=case.id,
            locale=case.locale,
            track=track,
            category=case.category,
            raw_text=case.raw_text,
            cleaned_text=cleaned,
            force_provider=args.force_cleaner_provider if mode == "force" else "skip",
            elapsed_ms=round(elapsed_ms, 2),
            error=cleaner_error,
        )
        cleaner_outputs.append(cleaner_output)

        score_error: str | None = None
        try:
            score = judge.score(case=case, track=track, cleaned_text=cleaned)
        except Exception as exc:
            score_error = str(exc)
            score = JudgeScore(
                case_id=case.id,
                locale=case.locale,
                track=track,
                category=case.category,
                faithfulness=0.0,
                disfluency_cleanup=0.0,
                logic_coherence=0.0,
                readability=0.0,
                hallucination_penalty=0.0,
                must_keep_violation=False,
                must_keep_violations=[],
                hallucination=False,
                confidence=0.0,
                notes="judge_error",
                overall=0.0,
                judge_provider=args.judge_provider,
                judge_model=args.judge_model if args.judge_provider == "openai" else "heuristic-v1",
                error=score_error,
            )
        judge_scores.append(score)

        if args.sleep_ms > 0:
            time.sleep(args.sleep_ms / 1000.0)

    outputs_path = args.out_dir / "cleaner_outputs.jsonl"
    scores_path = args.out_dir / "judge_scores.jsonl"
    write_jsonl(outputs_path, [to_dict(x) for x in cleaner_outputs])
    write_jsonl(scores_path, [to_dict(x) for x in judge_scores])

    by_track: dict[str, list[JudgeScore]] = {}
    for s in judge_scores:
        by_track.setdefault(s.track, []).append(s)

    summary: dict[str, Any] = {}
    if "zh_force" in by_track:
        summary["zh_force"] = summarize_scores(by_track["zh_force"], track="zh_force")
    if "yue_skip" in by_track:
        summary["yue_skip"] = summarize_scores(by_track["yue_skip"], track="yue_skip")
    if "yue_force" in by_track:
        summary["yue_force"] = summarize_scores(by_track["yue_force"], track="yue_force")

    summary["meta"] = {
        "cases_zh": str(args.cases_zh),
        "cases_yue": str(args.cases_yue),
        "yue_mode": args.yue_mode,
        "force_cleaner_provider": args.force_cleaner_provider,
        "judge_provider": args.judge_provider,
        "judge_model": args.judge_model if args.judge_provider == "openai" else "heuristic-v1",
        "force_cleaner_model": args.force_cleaner_model
        if args.force_cleaner_provider == "openai"
        else None,
        "timestamp_epoch": int(time.time()),
    }
    summary["gate_report"] = make_track_gate_report(
        zh_force=summary.get("zh_force"),
        yue_skip=summary.get("yue_skip"),
        yue_force=summary.get("yue_force"),
    )

    (args.out_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    if "zh_force" in summary:
        (args.out_dir / "summary.zh-CN.json").write_text(
            json.dumps(summary["zh_force"], ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    if "yue_skip" in summary:
        (args.out_dir / "summary.yue.skip.json").write_text(
            json.dumps(summary["yue_skip"], ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    if "yue_force" in summary:
        (args.out_dir / "summary.yue.force.json").write_text(
            json.dumps(summary["yue_force"], ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    summary_md = format_summary_markdown(summary, outputs_path=outputs_path, scores_path=scores_path)
    (args.out_dir / "summary.md").write_text(summary_md, encoding="utf-8")

    print(f"[eval] done. outputs: {outputs_path}")
    print(f"[eval] done. scores:  {scores_path}")
    print(f"[eval] done. summary: {args.out_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
