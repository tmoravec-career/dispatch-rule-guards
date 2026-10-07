# Step glossary

Every distinct step phrase used in `features/*.feature`, grouped by layer. This is the full list of step definitions the developer needs to implement. Phrases are written as [Cucumber Expressions](https://github.com/cucumber/cucumber-expressions). Gherkin keywords (`Given`/`When`/`Then`/`And`) don't count when matching, so a phrase used under both `Given` and `When` is a single definition.

Feature files that use each group:
- **R** = `dispatch_routing`
- **Q** = `work_queue`
- **A** = `api_dispatch`
- **L** = `api_claims_list`
- **S** = `api_claims_stats`
- **G** = `rule_change_gate`
- **K** = `load_and_capacity`

The k6 script's own requirements are in `LOAD_TEST_CRITERIA.md`, not here.

## Custom parameter type

| Name | Matches | Used for |
|---|---|---|
| `{json}` | A JSON literal: `"text"`, `-12`, `12.5`, `true`, `false`, `null`, `[]`, `{}` | Right-hand side of JSON assertions and payload edits. Parse it with `JSON.parse` and compare it **typed**, so `"12000"` is not equal to `12000`. |

Suggested regex: `"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null|\[\]|\{\}`

## Shared table formats

**Rules table** (`the dispatch rules:`, `a rules file … with the dispatch rules:`, `… with the added rule:`)

| Column | Format |
|---|---|
| `priority` | integer; lower is evaluated first |
| `id` | rule id |
| `conditions` | `<field> <op> <value>` clauses separated by `;` and ANDed. `in` takes a comma-separated list (`loss_state in TX,FL,LA`). Booleans are `true`/`false`, numbers are integers, anything else is a string. Blank means no conditions. |
| `queue` | target queue |
| `required_skills` | comma-separated; blank means no skills required |

A rules table with a header and no rows is an empty rule set.

**Roster table** (`the adjuster roster:`, `an adjusters file … with the adjuster roster:`)
Columns: `id | name | active | licensed_states | skills | capacity | open_claims`. Lists are comma-separated, `active` is `true`/`false`, and `capacity` and `open_claims` are integers.

**Claims table** (`a claim is dispatched:`, `these claims are dispatched in order:`, `these claims have been dispatched in order:`, `a claims file … with the claims:`)
Columns: `claim_number | line_of_business | estimated_loss | vehicle_value | cat_event | loss_state`. **A blank cell means the field is absent**, not an empty string. Numbers are integers and `cat_event` is `true`/`false`.

**Dispatch results table** (`the dispatch results are:`)
Columns: `claim_number | queue | matched_rule | adjuster | reason_code`. A blank `matched_rule` means no rule matched (general_intake). A blank `adjuster` means unassigned. Compare all rows in order.

## Scope rules

- `Given the dispatch rules:` and `Given the adjuster roster:` **replace** whatever is active, so a scenario can override the Background.
- For `@engine` scenarios, these steps build plain-Ruby objects only: no Rails, no DB.
- For `@ui` and `@api` scenarios, the same step definitions must also make the data live in the app. For example, a hook keyed on the tag can write the rules to a temp config the app is pointed at and upsert the adjusters into the DB. One definition per phrase, with the per-layer behaviour chosen by tag or World state.
- `adjuster {string} has {int} open claim(s)` **sets** the adjuster's open-claim counter. `adjuster {string} should have {int} open claim(s)` **asserts** it.

---

## 1. Shared setup

| Step | Used in | Notes |
|---|---|---|
| `the dispatch rules:` | R, Q, A, L, S, K | rules table, replaces active rules |
| `the adjuster roster:` | R, Q, A, L, S, K | roster table, replaces roster |
| `adjuster {string} has {int} open claim(s)` | R, Q, A, K | sets the counter directly, bypassing dispatch (K uses this to simulate a lost race) |
| `adjuster {string} is inactive` | R | |
| `rule {string} has condition {string}` | R, A | replaces the condition on the same field in that rule, e.g. `"estimated_loss gt 50000"`. In A it changes the app's **active** rules mid-scenario (re-dispatch uses current rules). |

## 2. Shared assertions

| Step | Used in | Notes |
|---|---|---|
| `adjuster {string} should have {int} open claim(s)` | R, A, K | |
| `claim {string} does not exist` | Q, A | nothing persisted |

## 2a. Controllable clock (A)

The app reads time through one injectable clock (e.g. `Dispatch.clock`), and these steps drive it. Real time never passes, and `sleep` is banned.

| Step | Notes |
|---|---|
| `the clock is frozen at {string}` | ISO-8601 UTC |
| `the clock advances by {int} second(s)` | |

## 3. Engine dispatch (R)

| Step | Notes |
|---|---|
| `a claim is dispatched:` | claims table with exactly one row |
| `these claims are dispatched in order:` | claims table; capacity is consumed between claims |
| `the same claim is dispatched again against a fresh copy of the roster` | re-runs the last claim against the roster as it was **before** the first dispatch |
| `the claim is routed to queue {string} by rule {string}` | |
| `the claim is routed to queue {string} with no matched rule` | matched rule is nil, queue is `general_intake` |
| `the claim is assigned to adjuster {string}` | |
| `the claim is unassigned with reason code {string}` | asserts no adjuster as well as the code |
| `the reason code is {string}` | |
| `the result includes a human-readable reason` | non-empty string. Don't assert the wording. |
| `the dispatch results are:` | dispatch results table |
| `both dispatch results are identical` | |

## 4. Rules config validation (R)

| Step | Notes |
|---|---|
| `I load a rules config:` | doc string (JSON) |
| `I load a rules config with a single rule whose conditions are:` | doc string is the `conditions` array. It is wrapped in `{"rules":[{"id":"r1","priority":1,"queue":"q1","required_skills":[],"conditions":<docstring>}]}` |
| `the rules config loads with {int} rules` | |
| `the rules config is rejected with error {string}` | the error code appears among the errors |
| `the error points at {string}` | the error with that code has this path, e.g. `rules[0].conditions[0].op` |
| `the rules config is rejected with errors:` | table `error \| path`; the exact set of errors, order-insensitive |
| `no rules are loaded` | |

## 5. Web UI (Q)

### Locator priority (decided, OPEN_QUESTIONS.md Q41)

Use the first strategy that applies:

1. **Form fields: visible label.** Use `fill_in "Estimated loss"`, `select "TX", from: "Loss state"`, `check "CAT event"`. Every field must have a real `<label for>`; a placeholder doesn't count.
2. **Buttons and links: accessible name.** Use `click_button "File claim"` and `click_link "CLM-3003"`. The accessible name is the visible text, or `aria-label` for an icon-only control.
3. **`data-testid`: only for things with no user-facing label.** That means page containers, table rows and cells, badges, counts, empty states and displayed values.
4. **Never** use CSS classes, element ids, XPath on structure, or copy text other than a label or accessible name.

If a step needs something that rule 1 or 2 should cover but there's no label, that's a UI defect. Fix the markup; don't add a testid.

### Page objects and waiting (decided, OPEN_QUESTIONS.md Q42)

- **Page objects:** step definitions never call Capybara directly. They go through one page object per page in `features/support/pages/`:
  - `new_claim_page.rb`
  - `claim_page.rb`
  - `work_queue_page.rb`
  - `adjusters_page.rb`
  - `rules_page.rb`

  Each page object owns its locators and exposes intent-level methods, e.g. `WorkQueuePage#filter(queue:, status:)`, `#rows`, `ClaimPage#redispatch`, `#dispatch_value(:queue)`. The generic steps below delegate to the current page object.
- **Waiting:** only Capybara's **waiting** finders and matchers are allowed: `find`, `has_css?`/`have_css`, `have_text`, `have_field`, `have_no_css`, `assert_selector`, `assert_no_selector`, and so on. Don't use non-waiting reads like `all(...).size` or `first` without `minimum:`, or `evaluate_script` polling. Use `have_no_…` for absence, not `!has_…`.
- **`sleep` is banned** in step definitions, page objects and support code, and so are `Timeout.timeout` retry loops. Code review rejects them, and a lint check (`rg -n "\bsleep\b" features/`) must come back empty. (k6 think time is a separate tool with its own rule; see `LOAD_TEST_CRITERIA.md`.)

### Steps

| Step | Notes |
|---|---|
| `these claims have been dispatched in order:` | claims table; dispatches through the app's own dispatch service (not HTTP), so claims are persisted and capacity is consumed. Also used in L, S and K. |
| `I visit the {string} page` | named pages: `new claim`, `work queue`, `adjusters`, `rules` |
| `I visit the claim page for {string}` | |
| `I fill in {string} with {string}` | **field label**, value |
| `I select {string} from {string}` | option text, **field label**. Option text for these selects is the code itself (`auto`, `TX`, `luxury_auto`, `unassigned`, `ADJ-004`). |
| `I check {string}` | **checkbox label** |
| `I press {string}` | **button accessible name** |
| `I press {string} and accept the confirmation` | `accept_confirm { click_button name }`. Needs a JS driver, so tag the scenario `@javascript`; that tag needs the deletion/truncation cleaning and file-based DB described in §9. The result renders **asynchronously**: the next assertions must be waiting matchers. Assert the expected new state (e.g. the history count reaching 2) rather than reading values straight away. |
| `I press {string} and dismiss the confirmation` | `dismiss_confirm { click_button name }`. To prove that *nothing* happened, follow it with `I reload the page` before asserting. A negative check made straight away would pass before a stray async request finished. |
| `I follow {string}` | **link accessible name** |
| `I file a claim through the form with:` | two-column `label \| value` table. Visits `new claim`; for each row, finds the field **by label** and acts on its type: `select` for a `<select>`, `check`/`uncheck` for a checkbox (`true`/`false`), `fill_in` otherwise. Then presses "File claim". Omitted fields stay blank: selects stay on their blank option and the checkbox stays unchecked. |
| `I reload the page` | |
| `I am on the claim page for {string}` | asserts `claim-detail` is present and `claim-claim_number` shows the number. Don't check the URL. |
| `I am on the {string} page` | asserts the page's identifying testid, **not the path**. After a failed submit Rails re-renders the form at `POST /claims`, so the URL is not `/claims/new`. Identifying testids: `new claim` → `claim-form`, `work queue` → `work-queue`, `adjusters` → `adjusters-page`, `rules` → `rules-page` |
| `the {string} field is marked invalid` | **field label**. The field has `aria-invalid="true"` and a **visible** error message linked through `aria-describedby`. The wording isn't asserted. |
| `{string} shows exactly {string}` | data-testid; the element's whitespace-trimmed text **equals** the value. Use it when "contains" would be ambiguous, e.g. `12000` inside `120000`. |
| `{string} contains no form controls` | the testid container has no `input`, `select`, `textarea` or `button`, so the page is read-only |
| `{string} shows {string}` | the data-testid element's text **contains** the value |
| `{string} is visible` | data-testid |
| `{string} is not visible` | data-testid; absent or hidden (use a waiting `have_no_…` matcher) |
| `I see {int} {string} elements` | count of elements with that exact data-testid (`assert_selector … count:`) |
| `the {string} rows show:` | first column `key` → row `[data-testid="<prefix>-<key>"]`. Every other column header is a data-testid inside that row whose text must equal the cell. A blank cell means the element is absent or empty. Rows not listed are not checked. |
| `the {string} rows are exactly:` | table `key`; the set of rows with data-testid `<prefix>-*` equals the listed keys (order-insensitive). A header-only table means none. |
| `the {string} rows appear in this order:` | table `key`; the same set, in this order |

### Labels and accessible names

| Page | Labelled controls |
|---|---|
| New claim | fields "Claim number", "Line of business" (select), "Estimated loss", "Vehicle value", "CAT event" (checkbox), "Loss state" (select); button "File claim" |
| Work queue | selects "Queue" (options: every configured rule queue, plus `general_intake`, plus any queue that still holds claims, such as one removed from the rules; configured queues are offered whether or not they have claims. The API `queue` filter and stats `by_queue` use the same set, Q35), "Status", "Adjuster", "Loss state"; buttons "Apply filters", "Clear filters"; each row's claim number is a link named after the claim number |
| Claim detail | button "Re-dispatch" (opens a JS confirm dialog) |

Money fields ("Estimated loss", "Vehicle value") accept `12000`, `$12,000`, `12,000.00` and `$12,000.00`, and store whole dollars. Non-zero cents, letters, negatives and exponent notation make the field invalid (Q50). Coverage for the form controls: the "CAT event" checkbox is exercised checked and unchecked, and the "Loss state" dropdown with several states, both through the primitive steps and the `I file a claim through the form with:` composite (automation items A3/A4).

### data-testid catalogue (unlabelled things only)

| Page | testids |
|---|---|
| New claim | `claim-form` (page container) |
| Claim detail | `claim-detail` (page container), `claim-<field>` (displayed values), `dispatch-status`, `dispatch-queue`, `dispatch-matched-rule`, `dispatch-no-matched-rule`, `dispatch-adjuster`, `dispatch-reason-code`, `dispatch-reason`, `dispatch-history-entry` (one per dispatch) |
| Work queue | `work-queue` (page container), `queue-count`, `queue-empty`, `claim-row-<claim_number>` containing the cells `row-queue`, `row-status`, `row-adjuster`, `row-reason-code` |
| Adjusters | `adjusters-page` (page container), `adjuster-row-<id>` containing `adjuster-states`, `adjuster-skills` (both sorted alphabetically, `", "`-joined), `adjuster-load` (`open/capacity`), `adjuster-status` (`active`/`inactive`), and the badge `adjuster-at-capacity-<id>` |
| Rules | `rules-page` (page container), `rule-row-<id>` containing `rule-priority`, `rule-conditions` (same clause syntax as the rules table), `rule-queue`, `rule-skills` (sorted, `", "`-joined), plus `rule-row-general_intake` (always last) and the notice `licensing-guardrail` |

## 6. REST API (A, L, S)

Every request sends the `Authorization` header that the auth steps chose. The Background picks the ops token. Scenarios that need throttling lower the rate limit themselves; the test default is high.

### Auth

| Step | Notes |
|---|---|
| `the API tokens:` | table `token \| role` (`ops` / `adjuster`); configures the app's accepted tokens for the scenario |
| `I use the API token {string}` | later requests send `Authorization: Bearer <token>` |
| `I send no API token` | later requests send no `Authorization` header |
| `I send the Authorization header {string}` | later requests send this header verbatim (for malformed or unknown credentials) |
| `the response header {string} starts with {string}` | header lookup is case-insensitive. Used for `Content-Type` → `application/json` and `WWW-Authenticate` → `Bearer`. |
| `the response header {string} is {string}` | exact value, e.g. `Retry-After` → `45` |

### Rate limiting

| Step | Notes |
|---|---|
| `the API rate limit is {int} requests per {int} seconds` | per token; a fixed window that starts at the token's first request |
| `I GET {string} {int} times` | sequential requests; "the response …" steps then refer to the **last** one |
| `every response status was {int}` | across the requests made by the previous step |

### Response invariant (Q44)

| Step | Notes |
|---|---|
| `the response status and body agree` | 2xx ⇒ the body is JSON and has **no** `errors` key. 4xx ⇒ the body has a non-empty `errors` array, and every entry has a string `code`. Any 5xx fails the step. Use it on every error scenario and on representative success scenarios. |

### Stats (S)

| Step | Notes |
|---|---|
| `the stats match the sums over every page of {string}` | follows `page=1..total_pages` of the given list URL, sums `count` and `claim.estimated_loss` per `dispatch.queue` and per `dispatch.status`, and compares them with the **previous** stats response: per queue, per status and the grand total. Queues missing from the list must be zero in the stats. |
| `the last request ran exactly {int} SQL query/queries against {string}` | subscribes to `sql.active_record` around the last request and counts `SELECT` statements whose SQL references the **quoted** table identifier (`"claims"`, as the SQLite adapter quotes it). It ignores events named `CACHE` (query-cache hits), `SCHEMA`, and transaction statements (`BEGIN`/`COMMIT`/`SAVEPOINT`). Matching the quoted identifier avoids false hits on columns like `claims_count`. |

### Requests and assertions

| Step | Notes |
|---|---|
| `I POST to {string} with JSON:` | doc string; `Content-Type: application/json` |
| `I POST to {string} with the raw body:` | doc string sent verbatim as `application/json` |
| `I POST to {string} with content type {string} and the raw body:` | |
| `I POST to {string} a valid claim {string}` | standard valid body (see the `api_dispatch` header comment) with that claim_number |
| `I POST to {string} a valid claim {string} with {string} set to {json}` | sets or adds the top-level key |
| `I POST to {string} a valid claim {string} without {string}` | removes the key |
| `I POST to {string}` | no body |
| `I GET {string}` | |
| `the response status is {int}` | |
| `the response JSON at {string} is {json}` | dotted path with `[n]` |
| `the response JSON at {string} is a non-empty string` | |
| `the response JSON at {string} has {int} entries` | array length |
| `the response JSON at {string} is of type {string}` | one of `string`, `integer`, `number`, `boolean`, `null`, `array`, `object`. `integer` means a JSON number with no fractional part. |
| `every entry in the response JSON at {string} conforms to {string}` | each array element validates against the schema file (format assertion on; schema loading as in §7) |
| `every entry in the response JSON at {string} has {string} equal to {json}` | relative path inside each element. Passes vacuously on an empty array, so pair it with a `total` check. |
| `the response JSON at {string} has these entries, in order:` | table; each header is a path relative to an entry. The array length must equal the row count, and each cell is compared to the value's string form, with a blank cell meaning `null`. |
| `the response pagination is consistent` | for a list response: `total_pages == ceil(total / per_page)` (0 when `total` is 0), and `data.length == clamp(total - (page-1)*per_page, 0, per_page)` |

## 7. Webhook and contracts (A, L)

**Schema loading (all "conforms" steps):** `claim_resource.schema.json` refers to `claim_dispatched.schema.json#/$defs/…` across files, so a schema loaded from a string won't resolve the `$ref`. Load schemas by **`Pathname`**, e.g. `JSONSchemer.schema(Pathname.new("contracts/claim_resource.schema.json"))`, so json_schemer's file ref resolver resolves relative refs against the file's location. Alternatively, pass an explicit `ref_resolver` that only serves files under `contracts/` and raises for anything else; never resolve over the network. In both cases, turn format assertion on.

| Step | Notes |
|---|---|
| `the webhook endpoint responds with status {int}` | a fake receiver (e.g. WebMock) that records requests |
| `the webhook endpoint times out` | |
| `the webhook endpoint refuses connections` | |
| `no webhook endpoint is configured` | unsets the webhook URL; any outbound HTTP must fail the test |
| `the webhook signing secret is {string}` | configures the HMAC secret |
| `the last webhook has header {string} starting with {string}` | |
| `the last webhook signature verifies with secret {string}` | recomputes `sha256=` + hex HMAC-SHA256 of the **raw received body** and compares in constant time |
| `the last webhook signature does not verify with secret {string}` | |
| `the last webhook body is tampered with by replacing {string} with {string}` | a **byte-level** substitution on the recorded raw body (`String#sub` on the bytes, first occurrence). It does **not** parse and re-serialise, so the only difference is the substituted bytes. The original signature header is kept. Fails if the search string isn't in the body. |
| `the last webhook body is re-serialised with different whitespace` | same JSON value, different bytes (parse, then pretty-print); the original header is kept |
| `a valid claim resource payload` | a canonical `{claim, dispatch}` sample for the list endpoint: an **assigned** claim with `dispatch.status "assigned"`, `adjuster_id "ADJ-004"` and `reason_code "assigned"`. The step **asserts it conforms** to `contracts/claim_resource.schema.json` first, so the negative cases can't pass vacuously. The payload-edit steps (`I set … in the payload`, `I remove … from the payload`) and `the payload does not conform to {string}` then apply to it. |
| `a de-duplicating test consumer` | a test double that processes each `event_id` at most once and counts duplicates |
| `the last webhook is delivered to the test consumer {int} times` | replays the recorded delivery (body and headers) |
| `every webhook is delivered to the test consumer` | each recorded delivery once, in order |
| `the test consumer has processed {int} event(s)` | |
| `the test consumer has ignored {int} duplicate(s)` | |
| `the webhooks for claim {string} have strictly increasing {string}` | `sequence` compared as integers, `occurred_at` as timestamps |
| `{int} webhook(s) has/have been sent` | count of delivery attempts |
| `no webhook is sent` | |
| `the last webhook payload conforms to {string}` | validates against the schema file path. **Format assertion must be on**, so `format: date-time` on `occurred_at` is enforced (e.g. `json_schemer` with format validation enabled). The contract example `occurred_at = "yesterday"` depends on it. |
| `every webhook payload conforms to {string}` | |
| `the last webhook payload at {string} is {json}` | |
| `the webhook event IDs are all different` | |
| `the webhook delivery for claim {string} is recorded as {string}` | `delivered` / `failed` |
| `a valid {string} webhook payload` | a canonical sample payload for `claim.assigned` / `claim.unassigned` that **must itself conform**. Assert that in the step, so the negative tests can't pass vacuously. |
| `I set {string} in the payload to {json}` | dotted path; creates the key if missing |
| `I remove {string} from the payload` | |
| `the payload does not conform to {string}` | |

## 8. Rule-change impact gate CLI (G)

**Working directory:** each scenario gets a fresh temp dir. Every "… file" Given step writes its file there, and the gate subprocess runs with **cwd = that temp dir**, so relative paths such as `base.json` resolve. Report paths passed by the run steps (`--json-out`, `--markdown-out`) are also inside it.

**Which report do assertions read?** `the JSON report …`, `the report lists …`, `the report includes …` and `the Markdown report …` read the reports from the **most recent run**. After `I run the impact gate twice …`, they read the **first** run's reports.

| Step | Notes |
|---|---|
| `an adjusters file {string} with the adjuster roster:` | roster table → JSON file in the scenario's temp dir |
| `a rules file {string} with the dispatch rules:` | rules table → valid rules JSON |
| `a claims file {string} with the claims:` | claims table → JSON array, in order |
| `a rules file {string} copied from {string}` | |
| `a rules file {string} copied from {string} with these condition changes:` | table `rule \| condition`; replaces the condition on that field in that rule |
| `a rules file {string} copied from {string} with the added rule:` | rules table (one row) |
| `a rules file {string} copied from {string} without rule {string}` | |
| `a rules file {string} containing:` | doc string written verbatim |
| `the environment has no database configured` | unset `DATABASE_URL`, point any DB config at a nonexistent path |
| `I run the impact gate comparing {string} to {string}` | `--base A --proposed B --claims <last claims file> --adjusters <last adjusters file> --json-out <tmp> --markdown-out <tmp>` as a **subprocess** |
| `I run the impact gate comparing {string} to {string} with flags {string}` | the same, plus the extra flags |
| `I run the impact gate with arguments {string}` | the given args plus `--json-out`/`--markdown-out` to tmp |
| `I run the impact gate with exactly the arguments {string}` | the given args and **nothing else**: no `--json-out`/`--markdown-out` is added. Captures stdout and stderr. |
| `I run the impact gate twice with arguments {string}` | two separate subprocess runs. Run 1 writes `run1/report.json` and `run1/report.md`, run 2 writes `run2/report.json` and `run2/report.md` (each via its own `--json-out`/`--markdown-out`). Later report steps read run 1; the "both …" steps compare the two runs. |
| `the gate exits with status {int}` | |
| `the gate reports these policy breaches:` | table `policy \| threshold \| actual`; exact set, numbers compared numerically. Policy names: `max_new_unassigned`, `max_reroute_pct`, `max_probe_changes` (all three are on by default) |
| `the gate reports no policy breaches` | |
| `the report lists these newly unassigned claims:` | exact set |
| `the report lists these newly assigned claims:` | table `claim_number \| queue \| adjuster`; exact set (`newly_assigned` in the JSON) |
| `the report lists these queue changes:` | exact set; only queues whose count changed |
| `the report lists these rerouted claims:` | exact set |
| `the report lists these boundary probe changes, among others:` | subset |
| `the report lists no boundary probe change for:` | table `field \| value` |
| `the report includes boundary probes for:` | table `field \| values` (comma-separated). It's a **list, not a map**: a field may repeat across rows (e.g. `estimated_loss` for several thresholds). Each row passes when every listed value appears as a probe on that field. Probes not listed are not checked. |
| `the JSON report at {string} is {json}` | |
| `the Markdown report has these sections in order:` | `##` headings, in order |
| `the Markdown report mentions {string}` | |
| `the gate did not load the web application` | e.g. the CLI prints `$LOADED_FEATURES` under a debug env var, or the step asserts `Rails`/`ActiveRecord` were never required |
| `both runs exit with the same status` | |
| `both JSON reports are identical` | byte-for-byte; the report must contain no timestamps or absolute paths |
| `the gate's error output mentions {string}` | stderr |
| `the gate's standard output mentions {string}` | stdout |
| `no report is written` | neither output file exists |

## 9. Load and capacity (K)

### Tags

| Tag | Where it runs |
|---|---|
| `@audit`, `@concurrency` | the normal acceptance job |
| `@k6_pr` | the k6 job on **every PR**: the smoke profile, which gates the PR |
| `@k6_nightly` | the **nightly** k6 job: load, storm, soak, stress, and the latency-breach check |

Neither k6 tag runs in the default Cucumber profile (`--tags "not @k6_pr and not @k6_nightly"`).

### Database setup for out-of-process and multi-threaded scenarios

`@audit`, `@concurrency`, `@k6_pr`, `@k6_nightly` and `@javascript` scenarios touch the database from **another process or thread** (the audit CLI, worker threads, the app server, the browser-driven server). Transactional fixtures would hide their writes or deadlock, so these scenarios need:
- **Cleaning:** `DatabaseCleaner` with **deletion or truncation**, not transactions, for these tags. Other scenarios may keep transactional cleaning.
- **Database file:** a **file-based** SQLite test database (e.g. `db/test.sqlite3`), never `:memory:`, which isn't shared across connections or processes.
- **Connection pool:** at least **N + 1** connections when a concurrency step runs N threads (N workers plus the main test thread). The step sets or checks the pool size before starting and fails fast if it's too small.
- **Busy timeout:** a SQLite **busy timeout** (e.g. `timeout: 5000` ms in `database.yml`), so concurrent writers wait for the write lock instead of failing with `SQLite3::BusyException`.

### Concurrency mechanism (decided, OPEN_QUESTIONS.md Q37)

- **Atomic claim:** dispatch claims a slot with an atomic conditional `UPDATE adjusters SET open_claims = open_claims + 1 WHERE id = ? AND open_claims < capacity`. There is no row lock: SQLite has no `SELECT … FOR UPDATE`, and Rails' `lock` is a no-op there.
- **Losing the race:** if the UPDATE affects 0 rows, that slot was taken by another request. Dispatch **re-selects among the remaining qualified adjusters**, in the same utilization and adjuster-ID order, and retries.
- **Unassigned:** `qualified_adjusters_at_capacity` is returned only when **every** qualified adjuster is full.
- **Transaction boundaries:**
  - **Selection** of the candidate, and therefore the seam below, runs with **no write transaction open**. It's a plain read.
  - **The write:** after the seam, the conditional UPDATE plus the claim/assignment write run in their **own short transaction**. If the UPDATE affects 0 rows, that transaction rolls back.
  - **A re-select** after a lost race does a fresh read and then opens a **new** transaction.
  - **Why it matters:** with `IMMEDIATE` transactions, a thread parked at the barrier while holding the write lock blocks every other thread, giving `BusyException` or a barrier timeout. With `DEFERRED` transactions and WAL, the read-to-write upgrade fails with `SQLITE_BUSY_SNAPSHOT`, which the busy timeout does not retry. The concurrency step should fail with a clear message if it detects an open transaction when the seam fires (e.g. `ActiveRecord::Base.connection.transaction_open?`).

### Race seam (test-only)

The dispatch service exposes a hook called **after candidate selection and before the conditional UPDATE** (e.g. `Dispatch.after_candidate_selection = ->(claim, adjuster) { … }`). It is called with **no transaction open** (see above). It is nil in production and refused outside the test environment.

The concurrency step installs a hook that waits on a barrier until **all N threads have selected a candidate**. Only then does any thread attempt its UPDATE. This makes every thread race for the same snapshot, so the losing-UPDATE and re-select path runs on every test run, not by luck. The barrier has a timeout (e.g. 10 s) that fails the step loudly rather than hanging. The hook only waits on the first selection of each thread, so re-selection after a lost race isn't blocked.

### Steps

| Step | Notes |
|---|---|
| `I run the capacity audit` | runs `bin/capacity_audit` as a subprocess against the scenario's database |
| `the capacity audit exits with status {int}` | 0 = clean, 1 = violations |
| `the capacity audit reports no violations` | |
| `the capacity audit reports these violations:` | table `adjuster \| open_claims \| capacity`; exact set |
| `{int} copies of this claim are dispatched concurrently:` | one-row claims table. Claim numbers get the suffixes `-01`..`-NN`. The copies are dispatched from N threads through the real dispatch service and DB (not stubs), each on its own DB connection (`ActiveRecord::Base.connection_pool.with_connection`). The **race seam** above holds every thread until all N have selected a candidate. The step waits for all threads to finish and re-raises any thread's exception. |
| `{int} of them are assigned to adjuster {string}` | over the concurrent batch |
| `{int} of them are unassigned with reason code {string}` | over the concurrent batch |
| `the app is running with the seed roster and rules` | boots the app (or targets `K6_BASE_URL`) with the seed data reset |
| `the app adds {int} ms of latency to every API response` | a test-only setting (e.g. `DISPATCH_TEST_LATENCY_MS`), refused in production |
| `I run the k6 {string} profile` | `k6 run -e K6_PROFILE=<p> --summary-export … load/dispatch.js` |
| `I run the k6 {string} profile with duration {string}` | additionally passes `K6_SOAK_DURATION` |
| `k6 exits with status {int}` | 0 = pass, 99 = threshold failed |
| `the k6 summary reports threshold {string} as {string}` | `passed` / `failed`, read from the summary export |
| `every claim created during the k6 run has a terminal dispatch result` | a DB check over the run's claim-number prefix: `assigned` with an adjuster, or `unassigned` with one of the two reason codes. Nothing is null or pending. |
| `the k6 run created CAT-event property claims in each of {string}` | comma-separated states |
| `the k6 run lasted between {int} and {int} seconds` | from the summary's `state.testRunDurationMs` |
| `I run the stress runner` | `bin/stress_run` |
| `the stress runner exits with status {int}` | |
| `the stress report includes {string}` | the key is present in `stress_report.json` (its value may be null) |
| `the stress report at {string} is {json}` | |

---

**Totals:** 161 distinct step phrases:

| Group | Phrases |
|---|---|
| Shared setup | 5 |
| Shared assertions | 2 |
| Clock | 2 |
| Engine | 11 |
| Validation | 7 |
| UI | 24 |
| API: auth, rate limit, invariant, requests, list, stats | 29 |
| Webhook / contract / integrity (incl. the claim-resource sample) | 28 |
| Gate | 33 |
| Load / capacity | 20 |

Most are thin wrappers over a handful of helpers:
- table builders for rules, roster and claims
- a JSON-path reader
- the page objects
- a recorded-HTTP webhook sink with a test consumer
- a subprocess runner (gate, audit, k6)
