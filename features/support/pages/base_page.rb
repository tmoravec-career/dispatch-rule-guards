# Page objects for the web UI (STEP_GLOSSARY.md section 5, Q42). Step definitions never
# call Capybara themselves; they go through these.
#
# BasePage holds what every page shares: the locator rules (fields by label, buttons and
# links by accessible name, data-testid only for unlabelled things) and the generic
# testid and row assertions. Each subclass adds its path, its identifying container and
# its intent-level methods.
#
# Only Capybara's waiting finders and matchers are used: find, assert_selector,
# assert_no_selector, all(..., count:). Absence is asserted with the no-selector forms.
class BasePage
  include Capybara::DSL
  include Minitest::Assertions

  attr_writer :assertions

  def assertions
    @assertions ||= 0
  end

  # The data-testid of the page container (STEP_GLOSSARY.md, "I am on the {string} page").
  def self.container
    self::CONTAINER
  end

  def load
    visit self.class::PATH
    assert_displayed
    self
  end

  def assert_displayed
    assert_selector(testid(self.class.container))
    self
  end

  def reload
    visit current_url
    self
  end

  # --- forms: fields by label, buttons and links by accessible name -------------------

  def fill_in_field(label, value)
    fill_in label, with: value
  end

  def select_option(option, label)
    select option, from: label
  end

  def check_box(label)
    check label
  end

  # `confirmation` is nil (no dialog), :accept or :dismiss.
  def press(name, confirmation: nil)
    case confirmation
    when nil then click_button(name)
    when :accept then accept_confirm { click_button(name) }
    when :dismiss then dismiss_confirm { click_button(name) }
    else raise ArgumentError, "unknown confirmation #{confirmation.inspect}"
    end
  end

  def follow(name)
    click_link(name)
  end

  # Sets a field found by its label according to its type: select, checkbox or text.
  # A blank value leaves a select on its blank option and a checkbox unchecked.
  def set_field(label, value)
    field = find_field(label)
    if field.tag_name == "select"
      select_option(value, label) unless value.empty?
    elsif field[:type] == "checkbox"
      case value
      when "true" then check(label)
      when "false" then uncheck(label)
      when "" then nil
      else raise ArgumentError, "checkbox #{label.inspect} takes true or false, got #{value.inspect}"
      end
    else
      fill_in label, with: value
    end
  end

  # The labelled field has aria-invalid="true" and every element its aria-describedby
  # names is visible and has text (Q41). The wording is not asserted.
  def assert_field_invalid(label)
    field = find_field(label) { |element| element["aria-invalid"] == "true" }
    described_by = field["aria-describedby"].to_s.split
    refute_empty described_by, "#{label.inspect} is marked invalid but has no aria-describedby"
    described_by.each { |id| find(:id, id, text: /\S/) }
  end

  # --- data-testid values -------------------------------------------------------------

  def testid(id)
    %([data-testid="#{id}"])
  end

  def assert_shows(id, text)
    assert_selector(testid(id), text: text)
  end

  def assert_shows_exactly(id, text)
    assert_selector(testid(id), exact_text: text)
  end

  def assert_visible(id)
    assert_selector(testid(id))
  end

  def assert_not_visible(id)
    assert_no_selector(testid(id))
  end

  def assert_count(id, count)
    assert_selector(testid(id), count: count)
  end

  def assert_no_form_controls(id)
    within(find(testid(id))) { assert_no_selector("input, select, textarea, button", visible: :all) }
  end

  # --- rows: [data-testid="<prefix>-<key>"] -------------------------------------------

  # `expected` maps each key to {cell testid => text}; a blank text means absent or empty.
  def assert_rows_show(prefix, expected)
    expected.each do |key, cells|
      row = find(testid("#{prefix}-#{key}"))
      cells.each do |cell, text|
        if text.empty?
          row.assert_no_selector(testid(cell), text: /\S/)
        else
          row.assert_selector(testid(cell), exact_text: text)
        end
      end
    end
  end

  def assert_rows_exactly(prefix, keys)
    assert_equal keys.sort, row_keys(prefix, keys.size).sort
  end

  def assert_rows_in_order(prefix, keys)
    assert_equal keys, row_keys(prefix, keys.size)
  end

  private

  # Waits for exactly `count` rows, then reads their keys in document order.
  def row_keys(prefix, count)
    selector = %([data-testid^="#{prefix}-"])
    if count.zero?
      assert_no_selector(selector)
      return []
    end
    all(selector, count: count).map { |row| row["data-testid"].delete_prefix("#{prefix}-") }
  end
end
