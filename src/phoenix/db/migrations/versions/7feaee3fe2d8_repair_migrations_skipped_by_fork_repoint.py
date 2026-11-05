"""repair migrations skipped by the fork's August re-point

Revision ID: 7feaee3fe2d8
Revises: e0307b79758d
Create Date: 2026-11-05 11:00:00.000000

Until 2026-08-13 ``e0307b79758d`` (media_files) chained off ``c9d0e1f2a3b4``. The
August sync re-pointed it onto ``4aad9107d196``, slipping two upstream migrations in
*beneath* it: ``e767d3c57f32`` (agent session tables) and ``4aad9107d196`` (FK indexes,
drop ``ix_latency``). A database that had already applied ``e0307b79758d`` was stamped
at what alembic then considered the head, so ``upgrade head`` ran neither of them.

``alembic_version`` cannot tell such a database apart from one created after the
re-point — both read ``e0307b79758d`` — so this looks at the schema instead and runs
upstream's own ``upgrade()`` for whichever step is missing. On every database created
after 2026-08-13 it is a no-op.

Moving a fork migration's parent is what causes this, so the fork no longer does it:
``scripts/sync_fork.py`` adds a merge revision on each sync instead.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "7feaee3fe2d8"
down_revision: Union[str, None] = "e0307b79758d"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_AGENT_SESSIONS_REVISION = "e767d3c57f32"
_FK_INDEXES_REVISION = "4aad9107d196"

# Created by `4aad9107d196`; its upgrade is idempotent (`if_not_exists`), so running it
# when only some are present is safe.
_FK_INDEXES = {
    "experiment_prompt_tasks": {
        "ix_experiment_prompt_tasks_custom_provider_id",
        "ix_experiment_prompt_tasks_prompt_version_id",
    },
    "dataset_evaluators": {"ix_dataset_evaluators_user_id"},
    "generative_model_custom_providers": {"ix_generative_model_custom_providers_user_id"},
    "secrets": {"ix_secrets_user_id"},
}


def _run_upstream_upgrade(revision_id: str) -> None:
    script = op.get_context().script
    assert script is not None, "alembic did not hand the migration its script directory"
    revision_script = script.get_revision(revision_id)
    assert revision_script is not None, f"upstream migration {revision_id} not found"
    revision_script.module.upgrade()


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table("agent_sessions"):
        _run_upstream_upgrade(_AGENT_SESSIONS_REVISION)
    if any(
        not names <= {index["name"] for index in inspector.get_indexes(table)}
        for table, names in _FK_INDEXES.items()
    ):
        _run_upstream_upgrade(_FK_INDEXES_REVISION)


def downgrade() -> None:
    # Whatever this added belongs to upstream's revisions, which own its removal.
    pass
