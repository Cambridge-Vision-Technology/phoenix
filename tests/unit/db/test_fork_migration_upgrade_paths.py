"""
Upgrading a database that is already at the fork's migration head.

`test_migration_heads.py` proves a fresh database reaches a single head, and no other
test starts from anything but an empty file. Neither catches the failure that matters
on a sync: a deployed database is stamped at the fork's head, and if a sync slips
upstream migrations in *beneath* that revision, `alembic upgrade head` believes there is
nothing to do. Phoenix then fails at startup on a table that was never created
(`no such table: deployment_secret`, on the November 2026 sync).

So these tests build the schema a deployment actually has, stamp it the way alembic
left it, and upgrade from there:

- **after the August re-point** — media_files chained off `4aad9107d196`, so the
  database has every upstream migration up to it;
- **before it** — media_files chained off `c9d0e1f2a3b4`; the re-point then hid
  `e767d3c57f32` and `4aad9107d196` beneath it, so neither ever ran.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterator

import pytest
import sqlalchemy as sa
import sqlean
from alembic import command
from alembic.config import Config
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory

import phoenix
from phoenix.db.models import Base

_FORK_MEDIA_REVISION = "e0307b79758d"
_PARENT_BEFORE_AUGUST_REPOINT = "c9d0e1f2a3b4"

# One object per upstream migration a stale stamp would skip.
_TABLES_FROM_UPSTREAM = (
    "agent_sessions",  # e767d3c57f32
    "system_state",  # 45c1d8813138
    "deployment_secret",  # f3b8c2d14e70
)


def _alembic_config() -> Config:
    db_package = Path(phoenix.__file__).parent / "db"
    config = Config(str(db_package / "alembic.ini"))
    config.set_main_option("script_location", str(db_package / "migrations"))
    return config


def _upgrade(engine: sa.Engine, revision: str) -> None:
    config = _alembic_config()
    with engine.connect() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, revision)


def _stamp(engine: sa.Engine, revision: str) -> None:
    config = _alembic_config()
    with engine.connect() as connection:
        config.attributes["connection"] = connection
        command.stamp(config, revision, purge=True)


def _head() -> str:
    head = ScriptDirectory.from_config(_alembic_config()).get_current_head()
    assert head is not None
    return head


def _version(engine: sa.Engine) -> str:
    with engine.connect() as connection:
        return str(connection.execute(sa.text("SELECT version_num FROM alembic_version")).scalar())


def _tables(engine: sa.Engine) -> set[str]:
    return set(sa.inspect(engine).get_table_names())


def _indexes(engine: sa.Engine, table: str) -> set[str]:
    # Read from the catalog: the inspector silently skips expression indexes such as
    # `ix_latency`, which would make its absence unprovable.
    with engine.connect() as connection:
        rows = connection.execute(
            sa.text("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = :t"),
            {"t": table},
        )
        return {str(row[0]) for row in rows}


@pytest.fixture
def engine(tmp_path: Path) -> Iterator[sa.Engine]:
    # sqlean, as Phoenix itself uses: upstream migrations run `ALTER TABLE ... DROP
    # CONSTRAINT`, which the stdlib SQLite build rejects.
    engine = sa.create_engine(f"sqlite:///{tmp_path / 'phoenix.db'}", module=sqlean)
    try:
        yield engine
    finally:
        engine.dispose()


def _assert_fully_migrated(engine: sa.Engine) -> None:
    assert _version(engine) == _head()
    assert set(_TABLES_FROM_UPSTREAM) | {"media_files"} <= _tables(engine)
    assert "ix_secrets_user_id" in _indexes(engine, "secrets")  # 4aad9107d196
    assert "ix_latency" not in _indexes(engine, "spans")  # 4aad9107d196


class TestUpgradeFromTheForkHead:
    def test_fresh_database(self, engine: sa.Engine) -> None:
        _upgrade(engine, "head")
        _assert_fully_migrated(engine)

    def test_database_created_after_the_august_repoint(self, engine: sa.Engine) -> None:
        _upgrade(engine, _FORK_MEDIA_REVISION)
        assert not set(_TABLES_FROM_UPSTREAM[1:]) & _tables(engine)

        _upgrade(engine, "head")

        _assert_fully_migrated(engine)

    def test_database_created_before_the_august_repoint(self, engine: sa.Engine) -> None:
        # What a deployment from July 2026 holds: upstream up to `c9d0e1f2a3b4`, then
        # media_files, stamped at the media revision.
        _upgrade(engine, _PARENT_BEFORE_AUGUST_REPOINT)
        media = ScriptDirectory.from_config(_alembic_config()).get_revision(_FORK_MEDIA_REVISION)
        assert media is not None
        with engine.begin() as connection:
            # `env.py`'s metadata, so constraints get Phoenix's naming convention, as
            # they did when the deployment ran this revision for real.
            context = MigrationContext.configure(
                connection, opts={"target_metadata": Base.metadata}
            )
            with Operations.context(context):
                media.module.upgrade()
        _stamp(engine, _FORK_MEDIA_REVISION)
        assert "agent_sessions" not in _tables(engine)
        assert "ix_latency" in _indexes(engine, "spans")

        _upgrade(engine, "head")

        _assert_fully_migrated(engine)

    def test_upgrading_twice_is_a_no_op(self, engine: sa.Engine) -> None:
        _upgrade(engine, "head")
        _upgrade(engine, "head")
        _assert_fully_migrated(engine)
