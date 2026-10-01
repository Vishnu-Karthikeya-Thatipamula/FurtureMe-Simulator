-- ============================================================================
-- FutureMe Simulator - MySQL schema and query library (rewritten to match app.py)
-- ============================================================================
--
-- SCOPE OF THIS REWRITE
--   * FILE ONLY: this rewrite changes future_db.sql. The live `futureme_db`
--     database is not altered, dropped, migrated, or re-imported.
--   * LIVE QUERIES: app.py still executes only the six `users` statements
--     listed below. Nothing else in this file is executed by the app today.
--   * YEARS SETTING: the sidebar "No. of years" value is
--     st.session_state.simulation_years; save_to_history() stores it as
--     history_entry["simulation_years"]; ai_generate_report() forces every
--     scenario's timeline_years onto it. The schema below stores that value
--     once per report and once per scenario so a future DB-backed history can
--     preserve it exactly.
--
-- LIVE QUERIES (the only statements app.py executes today):
--
--   get_db_connection()
--     mysql.connector.connect(host="localhost", user="root",
--       password="Vishnu@134", database="futureme_db", port=3306,
--       use_pure=True)
--   register_user(username, password, email)
--     SELECT user_id FROM users WHERE username = %s;
--     INSERT INTO users (username, password_hash, email)
--     VALUES (%s, %s, %s);
--   authenticate_user(username, password)
--     SELECT user_id, password_hash FROM users WHERE username = %s;
--   auth_or_register_google_user(google_name, email)
--     SELECT user_id, username FROM users WHERE email = %s;
--     SELECT user_id FROM users WHERE username = %s;
--     INSERT INTO users (username, password_hash, email)
--     VALUES (%s, %s, %s);  -- password_hash is the literal 'GOOGLE_OAUTH'
--
-- CONVENTIONS
--   Target:  MySQL 8.0 (checked against 8.0.46).
--   Charset: utf8mb4 / utf8mb4_0900_ai_ci.
--   Engine:  InnoDB.
--   Placeholders in the commented templates use %s (mysql.connector style).
--
-- HOW TO USE THIS FILE
--   1. Fresh install: run this script top to bottom.
--   2. Live database: do NOT run the commented DROP statements at the end.
--   3. The commented SELECT/INSERT/DELETE templates are a wiring-ready query
--      library; they are comments on purpose so sourcing this file never
--      inserts, updates, or deletes user data.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS futureme_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE futureme_db;

-- ----------------------------------------------------------------------------
-- users - the only table the application queries
-- ----------------------------------------------------------------------------
-- How app.py uses each column:
--   user_id       AUTO_INCREMENT PK; authenticate_user() reads result[0] into
--                 st.session_state.user_id; the Google path reads
--                 cursor.lastrowid after its INSERT.
--   username      VARCHAR(100) NOT NULL, UNIQUE uq_users_username. Both
--                 register paths filter with WHERE username = %s, so the
--                 column must be indexed - the UNIQUE key serves that lookup.
--                 100 (not 50) is deliberate: the Google path can append
--                 f"_{sha256(email)[:4]}" (5 extra chars) to a long Google
--                 display name, and this server runs STRICT_TRANS_TABLES, so a
--                 too-narrow column raises an error instead of truncating.
--   password_hash VARCHAR(255) NOT NULL. Local accounts store the 64-char
--                 sha256 hex digest (hashlib.sha256(...).hexdigest());
--                 Google accounts store the 12-char sentinel 'GOOGLE_OAUTH',
--                 which a sha256 digest can never equal, so OAuth rows cannot
--                 be signed into via the password form. 255 leaves room for a
--                 later switch to bcrypt/argon2 without another ALTER.
--   email         VARCHAR(255) NULL DEFAULT NULL. RFC 5321 permits up to 254
--                 characters, so 100 would reject long addresses. NULL-able
--                 because register_user() stores whatever the form submits -
--                 including an empty string when the user skips the field.
--   idx_users_email             A plain KEY, intentionally NOT UNIQUE.
--                 auth_or_register_google_user() assumes an email identifies
--                 one account, but registration inserts the submitted email
--                 verbatim (no dedupe, no lower-casing), so two rows can
--                 already share an address. Declaring UNIQUE here would make
--                 future INSERTs fail; the KEY still speeds the WHERE email
--                 lookup. Enforce uniqueness in app.py first if you want it.
--   created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP. Never read by
--                 app.py; audit trail only.
--
-- LIVE QUERY TEMPLATES (commented so sourcing this file is side-effect free
-- beyond the CREATEs; copy them verbatim into app.py if you refactor):
--   -- register_user: duplicate check
--   -- SELECT user_id FROM users WHERE username = %s;
--   -- register_user / google_user: create row
--   -- INSERT INTO users (username, password_hash, email)
--   -- VALUES (%s, %s, %s);
--   -- authenticate_user: fetch credentials
--   -- SELECT user_id, password_hash FROM users WHERE username = %s;
--   -- google_user: returning user?
--   -- SELECT user_id, username FROM users WHERE email = %s;
--   -- google_user: name clash?
--   -- SELECT user_id FROM users WHERE username = %s;
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    user_id       INT          NOT NULL AUTO_INCREMENT,
    username      VARCHAR(100) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    email         VARCHAR(255)     NULL DEFAULT NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_username (username),
    KEY idx_users_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================================
-- DOCUMENTATION-ONLY TABLES (never queried by the current app.py)
-- ============================================================================
-- Everything below is a persistence blueprint, not live schema. CREATE TABLE
-- IF NOT EXISTS makes it safe on a fresh server and a no-op for `users` on
-- the live server - but profiles/reports/scenarios do not exist in this shape
-- on the live server, and app.py never SELECTs/INSERTs them (history lives in
-- st.session_state.scenario_history). Column names mirror save_to_history()
-- and REPORT_SCHEMA so a future commit can persist without renaming.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- profiles - one row per saved simulation's intake snapshot
-- ----------------------------------------------------------------------------
-- Mirrors INTAKE_SCHEMA (ai_parse_intake) plus the case label the report
-- prompt derives via case_label(profile). st.session_state.extracted_profile
-- holds exactly these keys; user_id ties the row back to users on login.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS profiles (
    profile_id      INT          NOT NULL AUTO_INCREMENT,
    user_id         INT              NULL DEFAULT NULL,
    case_type       VARCHAR(50)      NULL DEFAULT NULL,
    current_job     VARCHAR(200)     NULL DEFAULT NULL,
    education       VARCHAR(200)     NULL DEFAULT NULL,
    graduation_year VARCHAR(10)      NULL DEFAULT NULL,
    current_company VARCHAR(200)     NULL DEFAULT NULL,
    current_salary  VARCHAR(100)     NULL DEFAULT NULL,
    skills          TEXT                 NULL DEFAULT NULL,
    experience      VARCHAR(200)     NULL DEFAULT NULL,
    hobby           VARCHAR(200)     NULL DEFAULT NULL,
    hobby_evidence  TEXT                 NULL DEFAULT NULL,
    target_role     VARCHAR(200)     NULL DEFAULT NULL,
    notes           TEXT                 NULL DEFAULT NULL,
    salary_expectation VARCHAR(200)  NULL DEFAULT NULL,
    created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (profile_id),
    KEY idx_profiles_user (user_id),
    CONSTRAINT fk_profiles_user FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- profiles: VARCHAR sizing follows app.py, not guesswork.
--   * INTAKE_SCHEMA values are free-typed chat answers, so every text column
--     is NULL-able (the model uses "" for anything not stated, and the "skip"
--     path writes "Not provided by user" into detail fields).
--   * VARCHAR(200) for job/company answers: above the old prototype's
--     VARCHAR(100) without paying for TEXT indexing nobody queries.
--     skills/hobby_evidence/notes are TEXT: a pasted resume line can exceed
--     200 chars.
--   * current_salary and salary_expectation are VARCHAR, not FLOAT: app.py
--     keeps them as raw strings ("No idea", "12 LPA") and only the AI
--     interprets them; a numeric column would reject real input.
--   * graduation_year is VARCHAR(10) ("2024") - the model returns a year
--     string, never an INT.
--
-- FUTURE QUERY TEMPLATES (wiring-ready, commented out):
--   -- save intake snapshot after handle_turn() fills extracted_profile
--   -- INSERT INTO profiles (user_id, case_type, current_job, education,
--   --     graduation_year, current_company, current_salary, skills,
--   --     experience, hobby, hobby_evidence, target_role, notes,
--   --     salary_expectation)
--   -- VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);
--   -- reload on login
--   -- SELECT profile_id, case_type, current_job, education, graduation_year,
--   --        current_company, current_salary, skills, experience, hobby,
--   --        hobby_evidence, target_role, notes, salary_expectation
--   --   FROM profiles WHERE user_id = %s ORDER BY profile_id DESC LIMIT 1;
-- ----------------------------------------------------------------------------
-- reports - one row per generated report (one save_to_history() call)
-- ----------------------------------------------------------------------------
-- Holds the report-level fields: the history title becomes run_key, the two
-- sidebar settings become scenario_count/simulation_years, and the three
-- verdict fields come straight from REPORT_SCHEMA. profile_id points at the
-- intake snapshot; scenarios below point back here via report_id.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reports (
    report_id            INT          NOT NULL AUTO_INCREMENT,
    user_id              INT              NULL DEFAULT NULL,
    profile_id           INT              NULL DEFAULT NULL,
    run_key              VARCHAR(150) NOT NULL,
    scenario_count       TINYINT      NOT NULL DEFAULT 4,
    simulation_years     TINYINT      NOT NULL DEFAULT 5,
    salary_expectation   VARCHAR(200)     NULL DEFAULT NULL,
    objective_verdict    TEXT             NULL DEFAULT NULL,
    recommended_scenario VARCHAR(200)     NULL DEFAULT NULL,
    decision_note        TEXT             NULL DEFAULT NULL,
    created_at           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (report_id),
    UNIQUE KEY uq_reports_user_run (user_id, run_key),
    KEY idx_reports_profile (profile_id),
    CONSTRAINT fk_reports_user FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_reports_profile FOREIGN KEY (profile_id) REFERENCES profiles (profile_id)
        ON DELETE SET NULL,
    CONSTRAINT chk_reports_scenario_count CHECK (scenario_count BETWEEN 2 AND 6),
    CONSTRAINT chk_reports_simulation_years CHECK (simulation_years BETWEEN 1 AND 10)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- reports: why these definitions.
--   * run_key groups one report with its scenarios. It is the history title
--     from save_to_history(): "%d %b %Y, %H:%M" plus " - <target role>".
--     150 chars covers a 17-char stamp plus a long role.
--     UNIQUE(user_id, run_key) mirrors st.session_state.scenario_history:
--     titles are unique per user session, and two saves within the same
--     minute collide - the second save then replaces the first, exactly
--     like the dict overwrite does today.
--   * scenario_count TINYINT 2-6 mirrors the "Future scenarios to compare"
--     slider (MIN/MAX_SCENARIO_COUNT) and DEFAULT_SCENARIO_COUNT = 4.
--   * simulation_years TINYINT 1-10 is the "No. of years" slider
--     (MIN/MAX_SIMULATION_YEARS, DEFAULT_SIMULATION_YEARS = 5). Stored once
--     here AND once per scenario so a single scenario row stays truthful
--     even if the report row is deleted.
--   * salary_expectation VARCHAR(200): the raw salary answer used for this
--     run (or "No idea"), kept verbatim like app.py does.
--   * objective_verdict / decision_note are TEXT (model prose);
--     recommended_scenario is VARCHAR(200) because it must exactly equal
--     one scenario name ("Scenario B: ...") or 'No clear winner'.
--
-- FUTURE QUERY TEMPLATES (wiring-ready, commented out):
--   -- persist a generated report
--   -- INSERT INTO reports (user_id, profile_id, run_key, scenario_count,
--   --     simulation_years, salary_expectation, objective_verdict,
--   --     recommended_scenario, decision_note)
--   -- VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s);
--   -- sidebar history list (replaces st.session_state.scenario_history keys)
--   -- SELECT report_id, run_key, scenario_count, simulation_years, created_at
--   --   FROM reports WHERE user_id = %s ORDER BY report_id DESC;
--   -- reopen a saved simulation (replaces load_history_entry)
--   -- SELECT r.*, p.case_type, p.current_job, p.education, p.graduation_year,
--   --        p.current_company, p.current_salary, p.skills, p.experience,
--   --        p.hobby, p.hobby_evidence, p.target_role, p.notes
--   --   FROM reports r LEFT JOIN profiles p ON p.profile_id = r.profile_id
--   --  WHERE r.user_id = %s AND r.run_key = %s;
--   -- delete one saved simulation (scenarios cascade)
--   -- DELETE FROM reports WHERE user_id = %s AND run_key = %s;
-- ----------------------------------------------------------------------------
-- scenarios - one row per scenario inside a report (2-6 rows per run)
-- ----------------------------------------------------------------------------
-- Mirrors one entry of ai_generate_report()["scenarios"]. report_id points
-- at the report above; run_key is denormalised so rows stay grouped even if
-- the parent report row is deleted.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scenarios (
    scenario_id      INT          NOT NULL AUTO_INCREMENT,
    report_id        INT              NULL DEFAULT NULL,
    user_id          INT              NULL DEFAULT NULL,
    run_key          VARCHAR(150) NOT NULL,
    name             VARCHAR(200) NOT NULL,
    archetype        VARCHAR(100)     NULL DEFAULT NULL,
    risk_level       VARCHAR(20)      NULL DEFAULT NULL,
    target_role      VARCHAR(200)     NULL DEFAULT NULL,
    timeline_years   TINYINT      NOT NULL DEFAULT 5,
    expected_salary  BIGINT           NULL DEFAULT NULL,
    expected_savings BIGINT           NULL DEFAULT NULL,
    present_vs_future TEXT            NULL DEFAULT NULL,
    benefits         JSON                 NULL DEFAULT NULL,
    trade_offs       JSON                 NULL DEFAULT NULL,
    created_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (scenario_id),
    KEY idx_scenarios_report (report_id),
    KEY idx_scenarios_user (user_id),
    KEY idx_scenarios_run (user_id, run_key),
    CONSTRAINT fk_scenarios_report FOREIGN KEY (report_id) REFERENCES reports (report_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_scenarios_user FOREIGN KEY (user_id) REFERENCES users (user_id)
-- scenarios: why these definitions.
--   * name VARCHAR(200) NOT NULL: "Scenario A: [Role Name]" - the ordering
--     letter plus a role; NOT NULL because recommended_scenario must match
--     it exactly and the cards render it as their heading.
--   * archetype VARCHAR(100): one of the 7 REPORT_SCHEMA archetypes
--     ("Steady Specialist", ..., "Hybrid / Side-by-Side" - longest is 26
--     chars); 100 leaves room for the longer sidebar labels in ARCHETYPES.
--   * risk_level VARCHAR(20): "Low" | "Medium" | "High" (no CHECK - a future
--     model wording change should not break INSERTs).
--   * target_role VARCHAR(200): the distinct role per scenario.
--   * timeline_years TINYINT 1-10 NOT NULL: THE years setting, forced onto
--     every scenario by _apply_horizon(). create_financial_charts() divides
--     expected_savings by this value, so 0/NULL would break the chart -
--     hence NOT NULL with DEFAULT 5 (= DEFAULT_SIMULATION_YEARS).
--   * expected_salary / expected_savings BIGINT (not FLOAT): REPORT_SCHEMA
--     declares "[Integer in INR]"; the old prototype's FLOAT lost paise on
--     crore-scale projections. BIGINT holds any realistic INR figure
--     exactly; NULL when the model omits it.
--   * benefits / trade_offs JSON: REPORT_SCHEMA declares them as string
--     arrays; JSON keeps counts queryable with JSON_LENGTH() instead of
--     opaque TEXT blobs.
--   * run_key denormalised (same 150-char history title as reports): lets a
--     single-row query rebuild the sidebar entry after its parent is gone.
--   * report_id NULL-able with ON DELETE CASCADE: normal deletes flow
--     through the FK; the NULL default only matters for manual backfills.
--
-- FUTURE QUERY TEMPLATES (wiring-ready, commented out):
--   -- persist one scenario of a fresh report (one INSERT per scenario)
--   -- INSERT INTO scenarios (report_id, user_id, run_key, name, archetype,
--   --     risk_level, target_role, timeline_years, expected_salary,
--   --     expected_savings, present_vs_future, benefits, trade_offs)
--   -- VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
--   --     CAST(%s AS JSON), CAST(%s AS JSON));
--   -- render cards + comparison table + wealth chart for one run
--   -- SELECT name, archetype, risk_level, target_role, timeline_years,
--   --        expected_salary, expected_savings, present_vs_future, benefits,
--   --        trade_offs
--   --   FROM scenarios WHERE user_id = %s AND run_key = %s ORDER BY name;
--   -- wealth-trajectory input in one query (no Python loop needed)
--   -- SELECT name, timeline_years,
--   --        (expected_savings / NULLIF(timeline_years, 0)) AS annual_savings
--   --   FROM scenarios WHERE user_id = %s AND run_key = %s;
        ON DELETE CASCADE,
    CONSTRAINT chk_scenarios_timeline CHECK (timeline_years BETWEEN 1 AND 10)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ----------------------------------------------------------------------------
-- Upgrading an existing database (DOCUMENTATION - not executed)
-- ----------------------------------------------------------------------------
-- If futureme_db already exists from the earlier prototype, CREATE TABLE IF
-- NOT EXISTS skips the stale tables and the old columns remain. The live
-- database on this machine is in exactly that state. Widen the app-visible
-- columns like this (safe to re-run):
--
--   ALTER TABLE users
--       MODIFY COLUMN username      VARCHAR(100) NOT NULL,
--       MODIFY COLUMN password_hash VARCHAR(255) NOT NULL,
--       MODIFY COLUMN email         VARCHAR(255) NULL DEFAULT NULL,
--       ADD COLUMN    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--       ADD UNIQUE KEY uq_users_username (username),
--       ADD KEY idx_users_email (email);
--
-- Nothing else is required for the current app: profiles, reports and
-- scenarios are never queried, so their legacy/retired columns can stay
-- until persistence is added. When you do realign them, prefer rebuilding
-- from the definitions above (retired prototype columns such as
-- current_savings, monthly_expenses, target_skills, projected_total and
-- goal_reached have no equivalent in app.py):
--
--   RENAME TABLE profiles  TO profiles_legacy;
--   RENAME TABLE scenarios TO scenarios_legacy;
--   -- then re-run the CREATE TABLE statements above, migrate what you need,
--   -- verify, and only then DROP TABLE profiles_legacy, scenarios_legacy;
--
-- NOTE: only the database that holds real sign-ups needs these. This machine
-- holds live accounts, so widen columns / rename aside rather than dropping.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Optional: reset everything (DESTRUCTIVE - review before running)
-- ----------------------------------------------------------------------------
-- Uncomment only when you intend to wipe all accounts and history. Order
-- matters: children reference users/reports, so they drop first.
--
-- DROP TABLE IF EXISTS scenarios;
-- DROP TABLE IF EXISTS reports;
-- DROP TABLE IF EXISTS profiles;
-- DROP TABLE IF EXISTS users;
-- DROP DATABASE IF EXISTS futureme_db;
-- ============================================================================