from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class Repo:
    platform: str            # 'github' | 'gitea'
    full_name: str           # 'jwiegley/ledger'
    owner: str
    name: str
    node_id: str
    private: bool
    html_url: str
    has_issues: bool = True   # tracker enabled (Gitea 404s the endpoint if not)
    has_pulls: bool = True    # PR tracker enabled


@dataclass
class Thread:
    platform: str
    node_id: str
    repo_full_name: str
    number: int
    kind: str                # 'issue' | 'pr'
    title: str
    html_url: str
    state: str               # 'open' | 'closed'
    closed_at: str | None
    comment_count: int
    last_comment_id: str | None
    last_comment_at: str | None
    last_commenter: str | None
    last_commenter_is_bot: bool
    author_association: str | None
    updated_at: str | None
    body_excerpt: str = ""   # transient, redacted; NEVER persisted


@dataclass
class NotificationItem:
    platform: str
    repo_full_name: str
    subject_type: str        # Issue | PullRequest | ...
    subject_title: str
    reason: str
    html_url: str | None
    updated_at: str | None
    unread: bool


@dataclass
class AwaitingBundle:
    is_last_commenter_owner: bool
    last_actor_is_bot: bool
    has_owner_response: bool
    hours_since_last_human_comment: float | None
    author_association: str | None


@dataclass
class ThreadDelta:
    thread: Thread
    change: str              # 'new' | 'new_comment' | 'reopened' | 'stale'
    awaiting: AwaitingBundle


@dataclass
class AttentionItem:
    id: str
    severity: str            # 'serious' | 'question' | 'fyi'
    one_line: str


@dataclass
class Coverage:
    repos_scanned: int = 0
    repos_errored: int = 0
    errored_repos: list[str] = field(default_factory=list)
    items_to_triage: int = 0
    items_omitted: int = 0
    llm_status: str = "ok"
    duration_s: float = 0.0
