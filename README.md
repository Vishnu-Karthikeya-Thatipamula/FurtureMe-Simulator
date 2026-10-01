FutureMe Simulator — Detailed Working
1. Big picture
FutureMe Simulator is a Streamlit career-simulation app:

User chats / uploads resume -> Gemini AI extracts profile -> asks missing details -> optionally assesses hobby work -> asks salary expectation -> Gemini generates 2-6 branching future scenarios over N years -> app renders report + charts -> everything is saved in MySQL per-user and restored on next login.

Two files do almost everything:

File	Lines	Role
app.py	~1344	Whole app: auth, AI engine, persistence layer, chat flow, report UI
future_db.sql	368	MySQL schema + documented query library for futureme_db
Stack: Streamlit + pandas + plotly.express + mysql-connector-python(use_pure=True) + google-genai + PyPDF2 + python-docx.

Server: MySQL 8.0 localhost:3306, DB futureme_db, utf8mb4_0900_ai_ci, InnoDB.

2. app.py — section by section
2.1 Config + get_db_connection() — L21-39

def get_db_connection():
    return mysql.connector.connect(host="localhost",user="root",
      password="Vishnu@134",database="futureme_db",port=3306,use_pure=True)
Single place where DB credentials live. Every DB function calls it, opens a short connection, commits/rolls back, closes.

Gemini setup:


GEMINI_INTAKE_MODEL="gemini-3.5-flash-lite" # cheap, profile parsing
GEMINI_REPORT_MODEL="gemini-3.8-flash"      # bigger, report generation
GEMINI_FALLBACK_MODELS=(...)
gemini_client=genai.Client(api_key=...)
2.2 st.session_state — L44-56
Streamlit reruns the whole script on every click. session_state is the in-memory RAM:

is_authenticated, user_id, session_id — login
flow_stage — intake -> details -> proficiency? -> salary -> report
messages[] — chat transcript
extracted_profile{} — AI-built profile dict
hobby_assessment{} — Case-III assessment
salary_expectation — raw string, "No idea" allowed
report_data{} — last Gemini report JSON
scenario_history{title: entry} — fast in-memory history, mirrored to MySQL
scenario_count, simulation_years — sidebar sliders
active_history_key, pending_regenerate
2.3 Auth — L61-137
hash_password(pw)=sha256(pw).hexdigest() — 64-char hex. Google rows store sentinel 'GOOGLE_OAUTH' which can never equal a hash, so OAuth rows can't login via password form.
register_user(username,password,email): SELECT user_id FROM users WHERE username=%s -> if exists return False else INSERT INTO users(username,password_hash,email) VALUES(%s,%s,%s) + commit, rollback on error.
authenticate_user(username,password): SELECT user_id,password_hash FROM users WHERE username=%s, compare hash, set session_state, then hydrate_history_from_db().
auth_or_register_google_user(google_name,email):
SELECT user_id,username FROM users WHERE email=%s — returning user?
If new: SELECT user_id FROM users WHERE username=%s — name clash? If clash base_username_{sha256(email)[:4]}.
INSERT INTO users(...) VALUES(...,'GOOGLE_OAUTH',...), lastrowid becomes user_id.
hydrate_history_from_db() + rerun().
logout_user() clears session + scenario_history={}.
Google OAuth code exchange lives at L1214-1226: code in st.query_params -> POST to oauth2.googleapis.com/token -> GET userinfo -> auth_or_register_google_user().

2.4 AI helpers — L142-177
_to_float(v,default) — safe float coercion for chart math.
_extract_json(raw) — strips ```json fences, regex \{.*\} DOTALL, json.loads.
_generate_content(model,contents) — retry loop: 3 tries on main model + 1 try per fallback for 429,500,502,503,504 with sleep 2*(attempt+1), else re-raise. This is why transient Gemini 503 high demand doesn't kill the app.
2.5 Case model — L183-227
Three cases:


CASE_LABELS={unemployed_graduate, corporate_shift, hobby_to_career}
CASE_DETAIL_FIELDS={
 unemployed_graduate:[education,graduation_year,skills,experience,target_role],
 corporate_shift:[current_company,current_salary,skills,experience,target_role],
 hobby_to_career:[hobby,target_role]
}
_is_unknown(v) treats "",-,n/a,not sure,unknown,not provided... as missing. missing_detail_fields(profile) = what to still ask. profile_summary(profile) = markdown bullets for UI.

2.6 File/media intake — L253-302
UPLOAD_TYPES=txt,csv,pdf,docx,png,jpg,jpeg,webp,mp4,mov,webm

load_uploaded_file() returns (text, gemini_part, label):

txt/csv -> decode(utf-8,ignore)
pdf -> PyPDF2.PdfReader join pages
docx -> docx.Document join paragraphs
image -> genai_types.Part.from_bytes(...)
video -> temp file -> gemini_client.files.upload() -> wait_for_file_active(timeout=180) polling ACTIVE vs PROCESSING.
build_contents(prompt,media_part) = [media,prompt] if media else prompt.

2.7 ai_parse_intake() — L324-360 + INTAKE_SCHEMA L307-322
Prompt tells Gemini: you are intake analyst, merge existing_profile + new message + file text + media, pick case_type, report only facts, "" for unknown, never invent, respond strictly with INTAKE_SCHEMA JSON (case_type,current_job,education,graduation_year,current_company,current_salary,skills,experience,hobby,hobby_evidence,target_role,notes).

Then Python merges: only non-unknown values overwrite, and case_type fallback to case_key(existing).

2.8 ai_assess_hobby_proficiency() — L377-397 + PROFICIENCY_SCHEMA
Only for hobby_to_career. Prompt: judge technique/finish/complexity, weigh attached image/video harder than self-description. Returns {proficiency,years_experience,tools,strengths[],gaps[],portfolio_quality,summary}.

2.9 Persistence layer — L444-642 — the fix for data-loss
This is why user-data now survives refresh/restart:

PROFILE_COLUMNS — 12 keys that map 1:1 to profiles columns.
_opt_int(v) — INR -> int, None if omitted. _close_quietly() — always close cursor+conn.
persist_simulation(user_id,profile,salary,report,scenario_count,horizon_years):
Clamp scenario_count 2-6, horizon_years 1-10.
Build title="01 Oct 2026, 16:19 · Data Analyst" from time.strftime("%d %b %Y, %H:%M") + target_role.
In ONE transaction: DELETE FROM reports WHERE user_id=%s AND run_key=%s (dict-overwrite semantics) -> INSERT INTO profiles(...) -> INSERT INTO reports(user_id,profile_id,run_key,scenario_count,simulation_years,...) -> loop INSERT INTO scenarios(report_id,user_id,run_key,name,archetype,risk_level,target_role,timeline_years,expected_salary,expected_savings,present_vs_future,CAST(%s AS JSON),CAST(%s AS JSON)) per scenario. commit, else rollback+raise.
fetch_history_titles(user_id) — SELECT run_key,scenario_count,simulation_years FROM reports WHERE user_id=%s ORDER BY report_id DESC.
fetch_simulation(user_id,run_key) — reports LEFT JOIN profiles for header+profile + SELECT ... FROM scenarios ... ORDER BY scenario_id, json.loads for benefits/trade_offs, rebuilds exact save_to_history() dict shape {report,profile,hobby_assessment:None,salary,scenario_count,simulation_years}.
hydrate_history_from_db() — on every login, reloads all titles+entries into st.session_state.scenario_history.
2.10 Report generation — L644-726
_apply_horizon(report,horizon) forces every scenario[timeline_years]=horizon so a stray model value can't desync cards/table/chart.
ai_generate_report(profile,salary,hobby_assessment,scenario_count,horizon_years): clamps counts/years, builds archetype_menu from ARCHETYPES[:count+1], handles "No idea" salary by telling model to use market range in INR, injects Create exactly {N} DIFFERENT scenarios each spanning {Y} year horizon... Every scenario must set timeline_years={Y}, demands distinct role/salary/risk/tradeoff, asks for present_vs_future, benefits[3], trade_offs[2], then objective_verdict(3 sentences) + recommended_scenario(exact name or 'No clear winner') + decision_note(2 warm sentences), Respond strictly with REPORT_SCHEMA JSON, _extract_json + _apply_horizon.
REPORT_SCHEMA L399-419 defines each scenario: name("Scenario A: ..."),archetype(7 options),risk_level,target_role,timeline_years(1-10),expected_salary(INT INR),expected_savings(INT INR 30% rate),present_vs_future,benefits[],trade_offs[].

DEFAULT_SCENARIO_COUNT=4 (2-6), DEFAULT_SIMULATION_YEARS=5 (1-10).

2.11 Charts — L731-751
create_financial_charts(scenarios): annual_savings=expected_savings/timeline_years, years=[0..Y], trajectory=[0, annual*1, annual*2...], pd.DataFrame(Year,Accumulated_Savings,Scenario) per scenario, pd.concat + px.line(...,color="Scenario",markers=True). So chart X-axis automatically follows timeline_years.

2.12 Chat flow — L841-1063
start_new_simulation() resets profile/report/messages/stage.
load_history_entry(key) — dict first, else fetch_simulation() from DB, then restores report_data, extracted_profile, salary, scenario_count, simulation_years, flow_stage="report".
save_to_history(...) — calls persist_simulation() for durable MySQL copy, then mirrors same entry to in-memory dict. DB failure → warning, session copy still kept.
prompt_bar() — attach popover + text form. newly_attached() dedupes by name:size so re-render doesn't double-process.
render_prompt_stage() — suggestions on intake, skip-hints on later stages.
handle_turn(text,uploaded_file) — the state machine:
intake/details: ai_parse_intake() -> show profile_summary() -> if hobby case + artifact present, assess immediately -> compute_next_stage() -> ask stage_question() -> rerun().
proficiency: ai_assess_hobby_proficiency() -> show summary -> advance("salary").
salary: save salary_expectation (None if in NO_SALARY_ANSWERS) -> ai_generate_report(profile,text,assessment,scenario_count,simulation_years) with spinner Simulating N futures over Y years... -> report_data=report -> save_to_history(...) -> flow_stage="report".
request_regenerate() sets flag (callback-safe), run_regeneration() re-runs ai_generate_report with current sidebar sliders + save_to_history.
render_report() — Section A baseline (st.info), salary caption, hobby expander, Section B cards (2-col, badges for risk/archetype/timeline/salary/savings, present_vs_future, benefits/tradeoffs), Section C comparison st.dataframe + wealth st.plotly_chart, Section D decision_note + 3 buttons (Regenerate / Simulate another / Logout).
2.13 UI root — L1212-1344
st.set_page_config(...).
If not is_authenticated: login/register tabs + Google button (auth_url with client_id, redirect_uri=http://localhost:8501, scope=email profile). Login button -> authenticate_user() -> rerun(); Register -> register_user().
Else (authenticated): dark CSS, sidebar 🎛️ Simulation Settings with two sliders bound to st.session_state.scenario_count/simulation_years (Future scenarios 2-6, No. of years 1-10), 📚 History buttons (✅ active else 📄, on_click=load_history_entry), Logout/Reset buttons, transcript loop st.chat_message, stage router render_report() if flow_stage=="report" else render_prompt_stage().
3. future_db.sql — what it is and why
Executable part is only 6 statements: CREATE DATABASE futureme_db + USE + CREATE TABLE users/profiles/reports/scenarios. Everything else is comments on purpose, so sourcing the file never inserts/updates/deletes user data.

3.1 users — the ONLY table app.py queried before the persistence fix, still the auth table

CREATE TABLE users(
 user_id INT AUTO_INCREMENT PK,
 username VARCHAR(100) NOT NULL UNIQUE uq_users_username,
 password_hash VARCHAR(255) NOT NULL,
 email VARCHAR(255) NULL DEFAULT NULL KEY idx_users_email,
 created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
username(100) not 50: Google fallback name_{sha256(email)[:4]} adds 5 chars; server is STRICT_TRANS_TABLES so narrow column would error instead of truncate.
password_hash(255) holds 64-char sha256 today, 255 leaves room for bcrypt/argon2 later; Google rows hold 'GOOGLE_OAUTH'.
email(255) nullable because register form allows empty; KEY not UNIQUE because app inserts verbatim without dedupe — UNIQUE would break future inserts. Uniqueness must be enforced in app.py first.
Live templates documented verbatim: SELECT user_id FROM users WHERE username=%s, INSERT INTO users(username,password_hash,email) VALUES(%s,%s,%s), SELECT user_id,password_hash FROM users WHERE username=%s, SELECT user_id,username FROM users WHERE email=%s.
3.2 profiles — one row per simulation's intake snapshot
Mirrors INTAKE_SCHEMA: profile_id PK, user_id FK->users CASCADE, case_type VARCHAR(50), current_job/education/current_company/skills/experience/hobby/target_role VARCHAR(200), graduation_year VARCHAR(10), current_salary VARCHAR(100), salary_expectation VARCHAR(200), hobby_evidence/skills/notes TEXT, created_at.

Why strings not numbers: current_salary/salary_expectation keep raw "No idea","12 LPA" — only AI interprets them; FLOAT would reject real input. graduation_year VARCHAR(10) because model returns "2024" string. TEXT for resume-length fields.

3.3 reports — NEW, home for the years setting

CREATE TABLE reports(
 report_id PK, user_id FK CASCADE, profile_id FK SET NULL,
 run_key VARCHAR(150) NOT NULL, -- "01 Oct 2026, 16:19 · Data Analyst"
 scenario_count TINYINT DEFAULT 4 CHECK(2-6),
 simulation_years TINYINT DEFAULT 5 CHECK(1-10), -- <-- No. of years slider
 salary_expectation VARCHAR(200),
 objective_verdict TEXT, recommended_scenario VARCHAR(200), decision_note TEXT,
 UNIQUE(user_id,run_key)
);
run_key is history title; UNIQUE(user_id,run_key) mirrors dict-key uniqueness — two saves in same minute collide and second replaces first. simulation_years stored here AND per-scenario so one scenario row stays truthful if parent deleted. recommended_scenario VARCHAR(200) must exactly equal a scenario name or 'No clear winner'.

3.4 scenarios — one row per scenario (2-6 rows per report_id)
Mirrors one REPORT_SCHEMA entry: scenario_id PK, report_id FK->reports CASCADE, user_id FK CASCADE, run_key VARCHAR(150) denormalised, name VARCHAR(200) NOT NULL ("Scenario A: ..."), archetype VARCHAR(100), risk_level VARCHAR(20) no CHECK (future wording shouldn't break INSERTs), target_role VARCHAR(200), timeline_years TINYINT NOT NULL DEFAULT 5 CHECK(1-10) — THE years value forced by _apply_horizon(), expected_salary/expected_savings BIGINT (not FLOAT, exact INR, NULL if omitted), present_vs_future TEXT, benefits/trade_offs JSON (queryable via JSON_LENGTH()), indexes on report/user/(user,run_key).

Chart math expected_savings/timeline_years is why timeline_years is NOT NULL: 0/NULL would break it.

3.5 Rest of file
Future query templates (commented SELECT/INSERT/DELETE with %s placeholders) for save/list/reopen/delete — wiring-ready, copy-paste into app.py.
Upgrade notes: live DB was old shape (users VARCHAR(50), profiles.current_savings FLOAT, scenarios.target_skills/projected_total/goal_reached); instructions to ALTER TABLE users ... / RENAME ..._legacy rather than drop live accounts.
Destructive reset at end (commented DROP TABLE scenarios/reports/profiles/users + DROP DATABASE) — child-first order because of FKs.
4. End-to-end data flow (example)
Register Kanyarasi -> users(2,'Kanyarasi',sha256,email).
Login -> authenticate_user() -> hydrate_history_from_db() loads her reports/scenarios into sidebar.
Types I am corporate IT... + attaches resume.pdf -> load_uploaded_file() extracts text -> ai_parse_intake() returns {case_type:corporate_shift, skills:Python,...} -> extracted_profile updated.
Answers missing current_company, skills... or skip -> compute_next_stage().
Salary No idea -> salary_expectation="No idea", sliders scenario_count=4, simulation_years=7 -> ai_generate_report(...,4,7) prompts Create exactly 4 scenarios each spanning 7 year horizon... timeline_years=7 -> returns 4 scenarios -> _apply_horizon() forces all to 7.
save_to_history() -> persist_simulation(2,profile,"No idea",report,4,7) writes 1 profiles + 1 reports(simulation_years=7) + 4 scenarios(timeline_years=7) in one transaction -> title 01 Oct 2026, 16:19 · Python Full-stack Developer appears in sidebar + in-memory dict.
render_report() shows baseline, 4 cards, dataframe table, Plotly wealth lines 0..7 years, verdict + recommended_scenario.
Logout clears RAM; next login re-hydrates same title from MySQL; click reopens full report. Refresh/server restart no longer loses it.
Change No. of years 7->3 + 🔄 Regenerate -> run_regeneration() re-calls AI with 3, persists new run_key row.
Known gaps (no columns yet): hobby_assessment and chat messages[] don't survive re-login — only profile/report/scenarios do.
