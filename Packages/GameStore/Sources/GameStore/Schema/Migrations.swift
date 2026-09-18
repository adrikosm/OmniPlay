import GRDB

/// Schema v1. Every persisted concept the roadmap needs, declared once. JSON columns hold metadata only.
enum Migrations {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE games (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                root_rel_path TEXT NOT NULL DEFAULT '',
                engine TEXT NOT NULL,
                generation TEXT,
                version TEXT,
                runtime TEXT,
                runtime_version TEXT,
                detection_confidence REAL NOT NULL DEFAULT 0,
                compatibility_state INTEGER NOT NULL DEFAULT 1,
                install_bytes INTEGER NOT NULL DEFAULT 0,
                save_family TEXT,
                artwork_path TEXT,
                imported_at DATETIME NOT NULL,
                last_played_at DATETIME,
                play_time_s INTEGER NOT NULL DEFAULT 0,
                favorite INTEGER NOT NULL DEFAULT 0,
                hidden INTEGER NOT NULL DEFAULT 0,
                manual_runtime_override TEXT,
                compat_profile_json TEXT NOT NULL DEFAULT '{"overrides":{}}'
            );
            CREATE INDEX games_title ON games(title);
            CREATE TABLE detection_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                outcome TEXT NOT NULL,
                confidence REAL NOT NULL,
                evidence_json TEXT NOT NULL,
                detector_versions_json TEXT NOT NULL,
                created_at DATETIME NOT NULL
            );
            CREATE INDEX detection_results_game ON detection_results(game_id, created_at);
            CREATE TABLE runtime_selections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                selected_runtime TEXT NOT NULL,
                version TEXT,
                reason TEXT NOT NULL,
                warnings_json TEXT NOT NULL,
                fallbacks_json TEXT NOT NULL,
                created_at DATETIME NOT NULL
            );
            CREATE INDEX runtime_selections_game ON runtime_selections(game_id, created_at);
            CREATE TABLE compat_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                json TEXT NOT NULL
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                runtime TEXT NOT NULL,
                slot TEXT NOT NULL,
                started_at DATETIME NOT NULL,
                ended_at DATETIME,
                teardown_verdict TEXT,
                grade INTEGER,
                peak_footprint INTEGER,
                notes TEXT
            );
            CREATE INDEX sessions_game ON sessions(game_id, started_at);
            CREATE TABLE import_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT REFERENCES games(id) ON DELETE SET NULL,
                source_name TEXT NOT NULL,
                container TEXT NOT NULL,
                source_sha256 TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                outcome TEXT NOT NULL,
                error TEXT,
                created_at DATETIME NOT NULL
            );
            CREATE INDEX import_records_sha ON import_records(source_sha256);
            CREATE TABLE media_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                input_rel TEXT NOT NULL,
                output_rel TEXT NOT NULL,
                source_codec TEXT NOT NULL,
                target_codec TEXT NOT NULL,
                target_runtime TEXT NOT NULL,
                reason TEXT NOT NULL,
                state TEXT NOT NULL,
                progress REAL NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0,
                error TEXT
            );
            CREATE TABLE saves_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                slot_key TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                family TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                modified_at DATETIME NOT NULL,
                provenance_hash TEXT NOT NULL,
                backup_of INTEGER
            );
            CREATE INDEX saves_meta_game ON saves_meta(game_id);
            CREATE TABLE persistent_stores (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                modified_at DATETIME NOT NULL
            );
            CREATE TABLE mods (
                id TEXT PRIMARY KEY NOT NULL,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                source TEXT NOT NULL,
                installed_at DATETIME NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                priority INTEGER NOT NULL DEFAULT 0,
                content_type TEXT NOT NULL,
                engine_compat_json TEXT NOT NULL,
                files_json TEXT NOT NULL,
                conflicts_json TEXT NOT NULL
            );
            CREATE TABLE translation_packs (
                id TEXT PRIMARY KEY NOT NULL,
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                source TEXT NOT NULL,
                installed_at DATETIME NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                priority INTEGER NOT NULL DEFAULT 0,
                content_type TEXT NOT NULL,
                engine_compat_json TEXT NOT NULL,
                files_json TEXT NOT NULL,
                conflicts_json TEXT NOT NULL,
                format TEXT NOT NULL,
                language TEXT NOT NULL
            );
            CREATE TABLE overrides_ledger (
                game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                key TEXT NOT NULL,
                value_json TEXT NOT NULL,
                created_at DATETIME NOT NULL,
                PRIMARY KEY (game_id, key)
            );
            CREATE TABLE slot_ledger (
                process_boot_id TEXT NOT NULL,
                slot TEXT NOT NULL,
                spent INTEGER NOT NULL DEFAULT 0,
                spent_by_game TEXT,
                PRIMARY KEY (process_boot_id, slot)
            );
            """)
            try db.create(virtualTable: "games_fts", using: FTS5()) { t in
                t.synchronize(withTable: "games")
                t.tokenizer = .unicode61()
                t.column("title")
            }
        }
        return m
    }
}
