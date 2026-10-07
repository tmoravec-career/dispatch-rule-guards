# JSON-path reading and typed comparison shared by the report (and later API) assertions.
module JsonHelpers
  # "summary.reroute_pct", "data[0].claim.claim_number". A missing key fails rather than
  # reading as null, so `is null` can't pass on an absent field.
  def json_at(document, path)
    path.scan(/[^.\[\]]+|\[\d+\]/).reduce(document) do |node, token|
      if (index = token[/\A\[(\d+)\]\z/, 1])
        raise KeyError, "#{path}: not an array at #{token}" unless node.is_a?(Array)

        node.fetch(Integer(index, 10))
      else
        raise KeyError, "#{path}: not an object at #{token}" unless node.is_a?(Hash)

        node.fetch(token)
      end
    end
  end

  # Typed equality: 10 and 10.0 differ, as do "12000" and 12000.
  def json_typed_equal?(actual, expected)
    case expected
    when Hash
      actual.is_a?(Hash) && actual.keys.sort == expected.keys.sort &&
        expected.all? { |k, v| json_typed_equal?(actual[k], v) }
    when Array
      actual.is_a?(Array) && actual.size == expected.size &&
        actual.zip(expected).all? { |a, e| json_typed_equal?(a, e) }
    else
      actual.class == expected.class && actual == expected
    end
  end

  # Projects entries onto the table's columns as strings (nil -> "").
  def project(entries, headers)
    entries.map { |entry| headers.map { |h| entry.fetch(h).nil? ? "" : entry.fetch(h).to_s } }
  end

  def table_rows(table)
    table.raw.drop(1).map { |row| row.map { |cell| cell.to_s.strip } }
  end

  def assert_same_rows(entries, table)
    headers = table.raw.first
    assert_equal table_rows(table).sort, project(entries, headers).sort
  end

  def assert_rows_included(entries, table)
    headers = table.raw.first
    actual = project(entries, headers)
    table_rows(table).each do |row|
      assert_includes actual, row, "expected #{headers.zip(row).to_h} among #{actual.inspect}"
    end
  end
end

World(JsonHelpers)
