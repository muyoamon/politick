"""Client for llama.cpp's llama-server (OpenAI-compatible endpoint).

Targets POST {base_url}/v1/chat/completions. The llama.cpp-specific
`grammar` extension field carries a raw GBNF grammar, constraining
sampling to the diff IR wire format exactly — including the recursive
expression production hosted structured-output APIs can't express.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

import httpx

GRAMMAR_PATH = Path(__file__).parent / "grammar" / "diff.gbnf"


def diff_grammar() -> str:
    return GRAMMAR_PATH.read_text(encoding="utf-8")


class Llm(Protocol):
    """What actors need from a model; tests substitute a FakeLlm."""

    def chat(
        self,
        system: str,
        messages: list[dict],
        grammar: str | None = None,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str: ...


class LlamaServer:
    def __init__(
        self,
        base_url: str = "http://127.0.0.1:8080",
        model: str = "",
        temperature: float = 0.7,
        seed: int | None = None,
        max_tokens: int = 2048,
        timeout: float = 300.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.temperature = temperature
        self.seed = seed
        self.max_tokens = max_tokens
        self.client = httpx.Client(timeout=timeout)

    def chat(
        self,
        system: str,
        messages: list[dict],
        grammar: str | None = None,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        body: dict = {
            "model": self.model,
            "messages": [{"role": "system", "content": system}, *messages],
            "temperature": self.temperature if temperature is None else temperature,
            "max_tokens": max_tokens or self.max_tokens,
            # Hybrid-reasoning models (Qwen3 etc.) must not open with a
            # <think> block: it burns minutes of CPU on the intent turn and
            # fights the grammar mask on the compile turn. Honored when
            # llama-server runs with --jinja; ignored otherwise — pair with
            # --reasoning-budget 0 server-side for a hard guarantee.
            "chat_template_kwargs": {"enable_thinking": False},
        }
        if self.seed is not None:
            body["seed"] = self.seed
        if grammar is not None:
            body["grammar"] = grammar
        resp = self.client.post(f"{self.base_url}/v1/chat/completions", json=body)
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]
