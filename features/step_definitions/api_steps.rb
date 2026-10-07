# STEP_GLOSSARY.md section 6: the REST API (api_dispatch, api_claims_list, api_claims_stats).

# --- auth ---------------------------------------------------------------------

Given("the API tokens:") do |table|
  DispatchSettings.api_tokens = table.hashes.to_h { |row| [row.fetch("token"), row.fetch("role")] }
end

Given("I use the API token {string}") do |token|
  use_api_token(token)
end

Given("I send no API token") do
  self.api_authorization = nil
end

Given("I send the Authorization header {string}") do |header|
  self.api_authorization = header
end

# --- rate limiting --------------------------------------------------------------

Given("the API rate limit is {int} requests per {int} seconds") do |limit, seconds|
  DispatchSettings.configure_rate_limit(limit: limit, window_seconds: seconds)
end

When("I GET {string} {int} times") do |path, times|
  @statuses = Array.new(times) { api_request(:get, path).status }
end

Then("every response status was {int}") do |status|
  assert_equal [status] * @statuses.size, @statuses
end

# --- requests -------------------------------------------------------------------

When("I POST to {string} with JSON:") do |path, doc_string|
  api_request(:post, path, body: doc_string, content_type: "application/json")
end

When("I POST to {string} with the raw body:") do |path, doc_string|
  api_request(:post, path, body: doc_string, content_type: "application/json")
end

When("I POST to {string} with content type {string} and the raw body:") do |path, content_type, doc_string|
  api_request(:post, path, body: doc_string, content_type: content_type)
end

When("I POST to {string} a valid claim {string}") do |path, claim_number|
  post_json(path, valid_claim(claim_number))
end

When("I POST to {string} a valid claim {string} with {string} set to {json}") do |path, claim_number, key, value|
  post_json(path, valid_claim(claim_number).merge(key => value))
end

When("I POST to {string} a valid claim {string} without {string}") do |path, claim_number, key|
  body = valid_claim(claim_number)
  assert body.key?(key), "the valid claim has no #{key}"
  body.delete(key)
  post_json(path, body)
end

When("I POST to {string}") do |path|
  api_request(:post, path)
end

When("I GET {string}") do |path|
  api_request(:get, path)
end

# --- status, headers, invariant ------------------------------------------------------

Then("the response status is {int}") do |status|
  assert_equal status, api_response.status, "body: #{api_response.body[0, 500]}"
end

Then("the response header {string} starts with {string}") do |name, prefix|
  value = api_response.headers.find { |key, _| key.casecmp?(name) }&.last
  refute_nil value, "no #{name} header in #{api_response.headers.to_h.inspect}"
  assert value.start_with?(prefix), "#{name}: #{value.inspect} does not start with #{prefix.inspect}"
end

Then("the response header {string} is {string}") do |name, expected|
  value = api_response.headers.find { |key, _| key.casecmp?(name) }&.last
  assert_equal expected, value
end

# Q44: 2xx => JSON without "errors"; 4xx => a non-empty errors array whose entries have
# string codes; 5xx always fails.
Then("the response status and body agree") do
  status = api_response.status
  body = response_json
  case status
  when 200..299
    refute body.is_a?(Hash) && body.key?("errors"), "a #{status} body carries errors: #{body.inspect}"
  when 400..499
    errors = body.is_a?(Hash) ? body["errors"] : nil
    assert errors.is_a?(Array) && !errors.empty?, "a #{status} body has no non-empty errors array: #{body.inspect}"
    errors.each { |e| assert e.is_a?(Hash) && e["code"].is_a?(String), "error entry without a string code: #{e.inspect}" }
  else
    flunk "unexpected status #{status}: #{api_response.body[0, 500]}"
  end
end

# --- JSON assertions ------------------------------------------------------------------

Then("the response JSON at {string} is {json}") do |path, expected|
  actual = json_at(response_json, path)
  assert json_typed_equal?(actual, expected), "#{path}: expected #{expected.inspect}, got #{actual.inspect}"
end

Then("the response JSON at {string} is a non-empty string") do |path|
  value = json_at(response_json, path)
  assert value.is_a?(String) && !value.strip.empty?, "#{path}: expected a non-empty string, got #{value.inspect}"
end

Then("the response JSON at {string} has {int} entries") do |path, count|
  value = json_at(response_json, path)
  assert_kind_of Array, value
  assert_equal count, value.size, "#{path}: #{value.inspect}"
end

Then("the response JSON at {string} is of type {string}") do |path, type|
  value = json_at(response_json, path)
  matches =
    case type
    when "string" then value.is_a?(String)
    when "integer" then value.is_a?(Integer) || (value.is_a?(Float) && value == value.floor)
    when "number" then value.is_a?(Numeric)
    when "boolean" then [true, false].include?(value)
    when "null" then value.nil?
    when "array" then value.is_a?(Array)
    when "object" then value.is_a?(Hash)
    else flunk("unknown JSON type #{type.inspect}")
    end
  assert matches, "#{path}: expected #{type}, got #{value.inspect}"
end

Then("every entry in the response JSON at {string} conforms to {string}") do |path, schema|
  entries = json_at(response_json, path)
  assert_kind_of Array, entries
  entries.each { |entry| assert_conforms(entry, schema) }
end

Then("every entry in the response JSON at {string} has {string} equal to {json}") do |path, relative, expected|
  entries = json_at(response_json, path)
  assert_kind_of Array, entries
  entries.each do |entry|
    actual = json_at(entry, relative)
    assert json_typed_equal?(actual, expected), "#{relative}: expected #{expected.inspect}, got #{actual.inspect} in #{entry.inspect}"
  end
end

# Each header is a path inside an entry; cells compare to the value's string form, blank = null.
Then("the response JSON at {string} has these entries, in order:") do |path, table|
  entries = json_at(response_json, path)
  assert_kind_of Array, entries
  headers = table.raw.first
  actual = entries.map { |entry| headers.map { |h| json_at(entry, h).then { |v| v.nil? ? "" : v.to_s } } }
  assert_equal table_rows(table), actual
end

Then("the response pagination is consistent") do
  body = response_json
  total, per_page, page = body.values_at("total", "per_page", "page")
  assert_equal (total + per_page - 1) / per_page, body["total_pages"], "total_pages for #{total} at #{per_page} per page"
  assert_equal (total - ((page - 1) * per_page)).clamp(0, per_page), body["data"].size, "entries on page #{page}"
end

# --- stats ------------------------------------------------------------------------------

Then("the stats match the sums over every page of {string}") do |list_path|
  stats = response_json
  by_queue = Hash.new { |h, k| h[k] = [0, 0] }
  by_status = Hash.new { |h, k| h[k] = [0, 0] }
  page = 1
  loop do
    separator = list_path.include?("?") ? "&" : "?"
    api_request(:get, "#{list_path}#{separator}page=#{page}")
    assert_equal 200, api_response.status
    body = response_json
    body["data"].each do |entry|
      loss = entry.dig("claim", "estimated_loss")
      [by_queue[entry.dig("dispatch", "queue")], by_status[entry.dig("dispatch", "status")]].each do |sums|
        sums[0] += 1
        sums[1] += loss
      end
    end
    break if page >= body["total_pages"]

    page += 1
  end
  stats_queue = stats["by_queue"].to_h { |row| [row["queue"], [row["count"], row["total_estimated_loss"]]] }
  by_queue.each_key { |queue| assert stats_queue.key?(queue), "queue #{queue} is in the list but not in the stats" }
  stats_queue.each { |queue, sums| assert_equal by_queue.fetch(queue, [0, 0]), sums, "by_queue #{queue}" }
  stats["by_status"].each do |row|
    assert_equal by_status.fetch(row["status"], [0, 0]), [row["count"], row["total_estimated_loss"]], "by_status #{row['status']}"
  end
  assert_equal by_status.values.transpose.map(&:sum).then { |s| s.empty? ? [0, 0] : s },
               stats["total"].values_at("count", "total_estimated_loss"), "total"
end

# Counts SELECTs that reference the quoted table identifier, ignoring query-cache hits,
# schema queries and transaction statements.
Then("the last request ran exactly {int} SQL query/queries against {string}") do |count, table|
  quoted = %("#{table}")
  selects = last_request_queries.reject { |q| %w[CACHE SCHEMA TRANSACTION].include?(q[:name]) || q[:cached] }
                                .map { |q| q[:sql] }
                                .select { |sql| sql.match?(/\A\s*SELECT\b/i) && sql.include?(quoted) }
  assert_equal count, selects.size, "SELECTs against #{quoted}:\n#{selects.join("\n")}"
end
