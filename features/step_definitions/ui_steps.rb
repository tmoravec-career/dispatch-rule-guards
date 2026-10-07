# STEP_GLOSSARY.md section 5: the web UI (work_queue.feature). Every step goes through a
# page object (features/support/pages/); none calls Capybara directly. "these claims have
# been dispatched in order:" and "claim {string} does not exist" are shared steps.

# --- navigation -------------------------------------------------------------------------

When("I visit the {string} page") do |name|
  on_page(page_class(name).new.load)
end

When("I visit the claim page for {string}") do |claim_number|
  on_page(ClaimPage.new(claim_number).load)
end

When("I reload the page") do
  current_page.reload
end

Then("I am on the {string} page") do |name|
  on_page(page_class(name).new.assert_displayed)
end

Then("I am on the claim page for {string}") do |claim_number|
  on_page(ClaimPage.new.assert_showing(claim_number))
end

# --- fields by label, buttons and links by accessible name -------------------------------

When("I fill in {string} with {string}") do |label, value|
  current_page.fill_in_field(label, value)
end

When("I select {string} from {string}") do |option, label|
  current_page.select_option(option, label)
end

When("I check {string}") do |label|
  current_page.check_box(label)
end

When("I press {string}") do |name|
  current_page.press(name)
end

When("I press {string} and accept the confirmation") do |name|
  current_page.press(name, confirmation: :accept)
end

When("I press {string} and dismiss the confirmation") do |name|
  current_page.press(name, confirmation: :dismiss)
end

When("I follow {string}") do |name|
  current_page.follow(name)
end

When("I file a claim through the form with:") do |table|
  on_page(NewClaimPage.new).file_claim(table.raw.map { |label, value| [label.strip, value.to_s.strip] })
end

Then("the {string} field is marked invalid") do |label|
  current_page.assert_field_invalid(label)
end

# --- data-testid values --------------------------------------------------------------------

Then("{string} shows exactly {string}") do |testid, text|
  current_page.assert_shows_exactly(testid, text)
end

Then("{string} contains no form controls") do |testid|
  current_page.assert_no_form_controls(testid)
end

Then("{string} shows {string}") do |testid, text|
  current_page.assert_shows(testid, text)
end

Then("{string} is visible") do |testid|
  current_page.assert_visible(testid)
end

Then("{string} is not visible") do |testid|
  current_page.assert_not_visible(testid)
end

Then("I see {int} {string} elements") do |count, testid|
  current_page.assert_count(testid, count)
end

# --- rows: [data-testid="<prefix>-<key>"] -----------------------------------------------------

Then("the {string} rows show:") do |prefix, table|
  expected = table.hashes.to_h do |row|
    cells = row.except("key").transform_values { |text| text.to_s.strip }
    [row.fetch("key").strip, cells]
  end
  current_page.assert_rows_show(prefix, expected)
end

Then("the {string} rows are exactly:") do |prefix, table|
  current_page.assert_rows_exactly(prefix, table.raw.drop(1).map { |(key)| key.strip })
end

Then("the {string} rows appear in this order:") do |prefix, table|
  current_page.assert_rows_in_order(prefix, table.raw.drop(1).map { |(key)| key.strip })
end
