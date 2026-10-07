require_relative "../test_helper"

# Webhook payload builder (Q23, Q45-Q47) and HMAC signing (Q45).
class WebhookTest < Minitest::Test
  include DispatchFixtures

  EVENT_ID = "6f1c1d6e-6a3b-4b8e-9a51-0c2f5d7e9b10".freeze
  AT = Time.utc(2026, 10, 6, 9, 0, 5)

  def payload_for(claim, open_adj_004: 0, sequence: 1)
    r = roster
    r.set_open_claims("ADJ-004", open_adj_004)
    result = Dispatch::Engine.new(base_config).dispatch(claim, r)
    Dispatch::Webhook.payload(claim, result, event_id: EVENT_ID, occurred_at: AT, sequence: sequence)
  end

  def test_assigned_payload_shape
    payload = payload_for(claim("CLM-1001", "auto", 12_000, 120_000, false, "CA"))
    assert_equal %w[event event_id occurred_at sequence claim dispatch], payload.keys
    assert_equal "claim.assigned", payload["event"]
    assert_equal EVENT_ID, payload["event_id"]
    assert_equal "2026-10-06T09:00:05.000Z", payload["occurred_at"]
    assert_equal 1, payload["sequence"]
    assert_equal({ "claim_number" => "CLM-1001", "line_of_business" => "auto", "estimated_loss" => 12_000,
                   "vehicle_value" => 120_000, "cat_event" => false, "loss_state" => "CA" }, payload["claim"])
    dispatch = payload["dispatch"]
    assert_equal %w[status queue matched_rule adjuster_id reason_code reason], dispatch.keys
    assert_equal ["assigned", "luxury_auto", "luxury_auto", "ADJ-004", "assigned"],
                 dispatch.values_at("status", "queue", "matched_rule", "adjuster_id", "reason_code")
  end

  def test_unassigned_payload
    payload = payload_for(claim("CLM-1011", "liability", 40_000, nil, false, "WY"), sequence: 2)
    assert_equal "claim.unassigned", payload["event"]
    assert_equal 2, payload["sequence"]
    assert_nil payload["claim"]["vehicle_value"]
    assert_equal ["unassigned", "general_intake", nil, nil, "no_qualified_adjuster"],
                 payload["dispatch"].values_at("status", "queue", "matched_rule", "adjuster_id", "reason_code")
  end

  def test_occurred_at_is_utc_with_milliseconds
    claim = claim("C", "auto", 1, nil, false, "TX")
    result = Dispatch::Engine.new(base_config).decide(claim, roster)
    local = Time.new(2026, 10, 6, 11, 0, 5.25r, "+02:00")
    payload = Dispatch::Webhook.payload(claim, result, event_id: EVENT_ID, occurred_at: local, sequence: 1)
    assert_equal "2026-10-06T09:00:05.250Z", payload["occurred_at"]
  end

  def test_sequence_must_be_positive_integer
    claim = claim("C", "auto", 1, nil, false, "TX")
    result = Dispatch::Engine.new(base_config).decide(claim, roster)
    [0, -1, 1.5, "1"].each do |bad|
      assert_raises(ArgumentError) { Dispatch::Webhook.payload(claim, result, event_id: EVENT_ID, occurred_at: AT, sequence: bad) }
    end
  end

  def test_generated_event_ids_are_uuids
    id = Dispatch::Webhook.generate_event_id
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, id)
    refute_equal id, Dispatch::Webhook.generate_event_id
  end

  def test_signature_round_trip
    body = JSON.generate(payload_for(claim("CLM-1001", "auto", 12_000, 120_000, false, "CA")))
    header = Dispatch::Webhook.signature(body, "s3cret")
    assert_match(/\Asha256=\h{64}\z/, header)
    assert Dispatch::Webhook.verify_signature(body, header, "s3cret")
    refute Dispatch::Webhook.verify_signature(body, header, "wrong")
    refute Dispatch::Webhook.verify_signature(body.sub("CLM-1001", "CLM-1002"), header, "s3cret")
    refute Dispatch::Webhook.verify_signature(JSON.pretty_generate(JSON.parse(body)), header, "s3cret")
    refute Dispatch::Webhook.verify_signature(body, nil, "s3cret")
    refute Dispatch::Webhook.verify_signature(body, "sha256=abc", "s3cret")
  end

  def test_signature_matches_known_vector
    # RFC 4231 test case 2.
    assert_equal "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
                 Dispatch::Webhook.signature("what do ya want for nothing?", "Jefe")
  end

  # json_schemer is a gem and takes ~1 s to load, so this check runs under `bundle exec`
  # or with CONTRACTS=1, keeping the plain `ruby -Ilib` engine suite fast and gem-free.
  def test_payload_conforms_to_contract_when_json_schemer_is_available
    skip "contract check runs under bundle exec or CONTRACTS=1" unless defined?(Bundler) || ENV["CONTRACTS"] == "1"
    begin
      require "json_schemer"
    rescue LoadError
      skip "json_schemer not available outside the bundle"
    end
    schema = JSONSchemer.schema(Pathname.new(File.expand_path("../../contracts/claim_dispatched.schema.json", __dir__)),
                                format: true)
    assigned = payload_for(claim("CLM-1001", "auto", 12_000, 120_000, false, "CA"))
    at_capacity = payload_for(claim("CLM-1040", "auto", 12_000, 125_000, false, "CA"), open_adj_004: 2)
    [assigned, at_capacity].each { |p| assert schema.valid?(JSON.parse(JSON.generate(p))), schema.validate(p).to_a.inspect }

    broken = JSON.parse(JSON.generate(assigned))
    broken["occurred_at"] = "yesterday"
    refute schema.valid?(broken)
    broken = JSON.parse(JSON.generate(assigned))
    broken["dispatch"]["adjuster_id"] = nil
    refute schema.valid?(broken)
    broken = JSON.parse(JSON.generate(assigned))
    broken["event"] = "claim.unassigned"
    refute schema.valid?(broken)
  end
end
