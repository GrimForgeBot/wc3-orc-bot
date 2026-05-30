"""InputExecutor — the single thread that drives WC3Input.

One executor, one WC3Input, one event stream.

Preemption
──────────
Between any two ActionSteps, the executor checks whether a higher-priority
action is waiting. If yes, the remaining steps of the current action are
re-queued at the same priority (with label suffix "[resume]") and the
high-priority action executes immediately.

Example: a MACRO build sequence is mid-execution (step 2/4) when a MICRO
hero-ability action arrives → hero ability fires first, then build resumes.

The first step of any action is never preempted — it is considered committed
(e.g. a click that already selected a unit must be followed by the command).
"""
from __future__ import annotations
import threading
import time
from typing import TYPE_CHECKING

from wc3bot.core.action_queue import ActionQueue, Action

if TYPE_CHECKING:
    pass


class InputExecutor(threading.Thread):
    """Single consumer thread for the ActionQueue.

    Start it with executor.start() once; it runs until executor.stop().
    All WC3Input (inp.*) calls must go through this thread — never call
    inp.key/click/etc. from any other thread.
    """

    def __init__(self, q: ActionQueue) -> None:
        super().__init__(name="InputExecutor", daemon=True)
        self._q       = q
        self._stop_ev = threading.Event()
        self._current: str | None = None  # label of action in flight (for logs)

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def stop(self) -> None:
        """Signal the executor to stop after the current action completes."""
        self._stop_ev.set()

    def run(self) -> None:
        while not self._stop_ev.is_set():
            action = self._q.get(timeout=0.05)
            if action is None:
                continue
            self._execute(action)

    # ── Execution ──────────────────────────────────────────────────────────────

    def _execute(self, action: Action) -> None:
        self._current = action.label
        steps = action.steps

        for i, step in enumerate(steps):
            # ── Preemption check (never on step 0 — first step is committed) ──
            if i > 0:
                top_prio = self._q.peek_priority()
                if top_prio is not None and top_prio < action.priority:
                    remaining = Action(
                        priority=action.priority,
                        label=f"{action.label}[resume@{i}]",
                        steps=steps[i:],
                    )
                    self._q.task_done()   # original action consumed — mark done
                    self._q.submit(remaining)   # resume action re-enters queue
                    print(f"  [Executor] preempt {action.label!r} "
                          f"step {i}/{len(steps)} → prio {top_prio} waiting")
                    self._current = None
                    return

            # ── Execute step ──────────────────────────────────────────────────
            step.fn(*step.args, **step.kwargs)
            if step.delay_after > 0:
                time.sleep(step.delay_after)

        self._q.task_done()
        self._current = None

    # ── Status ─────────────────────────────────────────────────────────────────

    @property
    def current_action(self) -> str | None:
        return self._current

    def status(self) -> str:
        cur = self._current or "idle"
        return f"InputExecutor  current={cur!r}  queue={self._q.qsize()}"
