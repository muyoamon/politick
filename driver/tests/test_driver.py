"""End-to-end driver tests against the real kernel binary, no model
needed: scripted actors prove the loop, a FakeLlm proves the two-turn
compile + kernel-check retry path, and every run must satisfy the M4 exit
criterion (kernel-only replay reproduces the driven digest)."""

import json

from politick_driver.actors import Begin, LlmActor, RandomActor, ScriptedActor
from politick_driver.cli import drive
from politick_driver.kernel import Kernel

WOOL_RELIEF = {
    "name": "wool_relief_act",
    "by": "baron",
    "via": "pass_statute",
    "ops": [
        {"add_rule": {"name": "wool_relief", "on": "tick.quarter", "when": {"lit": True}, "do": [
            {"update": {"schema": "param", "key": [{"lit": "poll_tax_rate"}], "field": "value",
                        "op": "set", "value": {"lit": 0.05}}}
        ]}}
    ],
}

# Same bill, but referencing a schema that does not exist.
PHANTOM_BILL = json.loads(json.dumps(WOOL_RELIEF))
PHANTOM_BILL["ops"][0]["add_rule"]["do"][0]["update"]["schema"] = "tarrif"


class FakeLlm:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def chat(self, system, messages, grammar=None, max_tokens=None, temperature=None):
        self.calls.append({"system": system, "messages": messages, "grammar": grammar})
        return self.responses.pop(0) if self.responses else "PASS"


def committed(reports, name):
    return any(
        c["diff"] == name and c["outcome"] == "committed"
        for r in reports
        for c in r.commits
    )


def test_scripted_bill_passes_and_replays(kernel_bin, legislature_log):
    kernel = Kernel(kernel_bin)
    actor = ScriptedActor("baron", {1: [Begin("pass_statute", WOOL_RELIEF)]})
    reports = drive(kernel, legislature_log, [actor], ticks=8)

    assert committed(reports, "wool_relief_act")
    # The committed rule took effect: rate set at the tick-8 quarter.
    assert ["poll_tax_rate", 0.05] in reports[-1].rows("param")
    # Exit criterion: kernel alone reproduces the driven run.
    assert kernel.digest_chain(legislature_log, 8) == reports[-1].digest


def test_check_verdicts(kernel_bin, legislature_log):
    kernel = Kernel(kernel_bin)
    good = kernel.check(legislature_log, WOOL_RELIEF)
    assert good.ok and good.layers == ["statute"]

    bad = kernel.check(legislature_log, PHANTOM_BILL)
    assert not bad.ok
    assert bad.reason == "dangling_refs"
    assert bad.diag["code"] == "UnknownSchema"
    assert bad.diag["symbol"] == "tarrif"
    assert "tarrif" in bad.retry_feedback()


def test_llm_actor_retries_until_kernel_accepts(kernel_bin, legislature_log):
    kernel = Kernel(kernel_bin)
    fake = FakeLlm([
        "BILL: cut the poll tax to five percent, the north is grumbling",
        "this is not json",              # dropped by json.loads → feedback
        json.dumps(PHANTOM_BILL),        # rejected by kernel check → feedback
        json.dumps(WOOL_RELIEF),         # accepted
    ])
    actor = LlmActor(
        name="baron",
        persona="You are the baron.",
        llm=fake,
        kernel=kernel,
        log_path=legislature_log,
        max_retries=3,
    )
    reports = drive(kernel, legislature_log, [actor], ticks=8)

    assert committed(reports, "wool_relief_act")
    assert kernel.digest_chain(legislature_log, 8) == reports[-1].digest

    # Turn 1 (intent) is unconstrained; every compile turn carries the grammar.
    intent, *compiles = fake.calls[:4]
    assert intent["grammar"] is None
    assert all(c["grammar"] and c["grammar"].startswith("# GBNF") for c in compiles)
    # The retry feedback names the offending symbol from the kernel diag.
    final_feedback = compiles[2]["messages"][-1]["content"]
    assert "tarrif" in final_feedback


def test_llm_actor_abstains_after_max_retries(kernel_bin, legislature_log):
    kernel = Kernel(kernel_bin)
    fake = FakeLlm([
        "BILL: something doomed",
        json.dumps(PHANTOM_BILL),
        json.dumps(PHANTOM_BILL),
    ])
    actor = LlmActor(
        name="baron", persona="p", llm=fake, kernel=kernel,
        log_path=legislature_log, max_retries=2,
    )
    assert actor.act(1, Kernel(kernel_bin).run(legislature_log, 1)[-1]) == []


def test_random_actor_is_deterministic():
    from politick_driver.actors import Event

    mk = lambda: RandomActor("mob", seed=9, events=[Event("petition", ["north", 1])], rate=0.5)
    a, b = mk(), mk()
    seq_a = [a.act(t, None) for t in range(20)]
    seq_b = [b.act(t, None) for t in range(20)]
    assert seq_a == seq_b
