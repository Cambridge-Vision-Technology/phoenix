"""
Every migration applied and rolled back, over the fork's branched migration graph.

Upstream's `test_up_and_down_migrations.py` steps through the history one edge at a
time, which is the coverage worth having, but it also asserts the history is *linear*.
The fork's cannot be: its migrations hang off one upstream revision and are joined to
upstream's later ones by merge revisions, because moving a fork migration onto upstream's
new head makes every deployed database skip the upstream migrations moved beneath it
(see `tests/unit/db/test_fork_migration_upgrade_paths.py` and `scripts/sync_fork.py`).

So the fork's pre-merge workflow deselects upstream's test and runs this one: the same
full cycle and the same up-down-up-down of every step, taken over each parent-to-child
edge of the graph rather than over consecutive pairs of a single line. A merge revision
is therefore stepped down to each of its parents in turn.

Kept in its own file so upstream's stays byte-identical.
"""

from __future__ import annotations

import pytest
from alembic import command
from alembic.config import Config
from alembic.script import Script, ScriptDirectory
from sqlalchemy import Connection, text
from sqlalchemy.ext.asyncio import AsyncEngine

from . import _down, _run_async, _up, _verify_clean_state


def _parents(revision: Script) -> tuple[str, ...]:
    down = revision.down_revision
    if down is None:
        return ()
    return (down,) if isinstance(down, str) else tuple(down)


async def _current(engine: AsyncEngine, schema: str) -> set[str]:
    """Every row of `alembic_version` — two while a branch is applied on its own."""
    table = f"{schema}.alembic_version" if schema else "alembic_version"

    def _do(conn: Connection) -> set[str]:
        return {str(row[0]) for row in conn.execute(text(f"SELECT version_num FROM {table}"))}

    return await _run_async(engine, _do)


@pytest.mark.parametrize(
    "migrate_index_concurrently",
    [
        pytest.param(False, id="default"),
        pytest.param(
            True,
            id="concurrently",
            marks=pytest.mark.skipif(
                "os.environ.get('CI_TEST_DB_BACKEND', 'sqlite').lower() != 'postgresql'",
                reason="CONCURRENTLY only applies to PostgreSQL",
            ),
        ),
    ],
)
async def test_up_and_down_every_migration_edge(
    _engine: AsyncEngine,
    _alembic_config: Config,
    _schema: str,
    migrate_index_concurrently: bool,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    if migrate_index_concurrently:
        monkeypatch.setenv("PHOENIX_MIGRATE_INDEX_CONCURRENTLY", "true")
    else:
        monkeypatch.delenv("PHOENIX_MIGRATE_INDEX_CONCURRENTLY", raising=False)

    await _verify_clean_state(_engine, _schema)
    await _up(_engine, _alembic_config, "head", _schema)
    await _down(_engine, _alembic_config, "base", _schema)

    script = ScriptDirectory.from_config(_alembic_config)
    assert len(script.get_heads()) == 1, f"Expected one head, found {script.get_heads()}"
    # Parents before children, as upstream's test walks them.
    revisions = list(reversed(list(script.walk_revisions())))

    async def reach(revision: str) -> None:
        """Leave the database at exactly ``revision``, whatever branch it is on now."""
        current = await _current(_engine, _schema)
        if current == {revision}:
            return
        ancestors = {r.revision for r in script.iterate_revisions(revision, "base")}
        if current <= ancestors:
            await _up(_engine, _alembic_config, revision, _schema)
            return
        # On a sibling branch, where an upgrade would leave two rows: start over.
        await _down(_engine, _alembic_config, "base", _schema)
        await _up(_engine, _alembic_config, revision, _schema)

    async def step_down_from_merge(merge: Script, parents: tuple[str, ...]) -> None:
        # Downgrading a merge to either parent removes only the merge itself, leaving
        # every parent applied — two `alembic_version` rows, which `_down` rejects.
        def _do(conn: Connection) -> None:
            _alembic_config.attributes["connection"] = conn
            command.downgrade(_alembic_config, parents[0])

        await _run_async(_engine, _do)
        assert await _current(_engine, _schema) == set(parents), merge.revision

    assert len(revisions) > 1, "no migrations found"
    for child in revisions:
        parents = _parents(child)
        if not parents:
            continue
        if len(parents) == 1:
            await reach(parents[0])
            for _ in range(2):
                await _up(_engine, _alembic_config, child.revision, _schema)
                await _down(_engine, _alembic_config, parents[0], _schema)
        else:
            await reach(child.revision)
            for _ in range(2):
                await step_down_from_merge(child, parents)
                await _up(_engine, _alembic_config, child.revision, _schema)
