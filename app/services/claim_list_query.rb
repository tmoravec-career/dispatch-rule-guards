# GET /api/claims (Q38): filters combined with AND, pagination, newest first.
# Every invalid parameter is reported together.
class ClaimListQuery
  FILTERS = %w[queue status adjuster_id loss_state].freeze
  PARAMS = (FILTERS + %w[page per_page]).freeze
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  Error = Struct.new(:field, :code)

  attr_reader :errors, :page, :per_page

  # `params` are the raw query parameters (string values).
  def initialize(params, rules: DispatchSettings.rules)
    @params = params.to_h
    @rules = rules
    @errors = []
    validate
  end

  def valid?
    errors.empty?
  end

  def result
    scope = Claim.all
    FILTERS.each { |name| scope = scope.where(name => @params[name]) if @params.key?(name) }
    total = scope.count
    data = scope.newest_first.offset((page - 1) * per_page).limit(per_page).to_a
    { "page" => page, "per_page" => per_page, "total" => total,
      "total_pages" => (total + per_page - 1) / per_page, "data" => data.map(&:as_resource) }
  end

  private

  def validate
    @page = integer_param("page", 1, 1..)
    @per_page = integer_param("per_page", DEFAULT_PER_PAGE, 1..MAX_PER_PAGE)
    inclusion("queue") { |v| Claim.known_queue?(v, @rules) }
    inclusion("status") { |v| Claim::STATUSES.include?(v) }
    inclusion("adjuster_id") { |v| Adjuster.exists?(id: v) }
    inclusion("loss_state") { |v| Dispatch::US_STATES.include?(v) }
    (@params.keys - PARAMS).each { |name| errors << Error.new(name, "unknown_field") }
    errors.sort_by! { |e| PARAMS.index(e.field) || PARAMS.size }
  end

  def integer_param(name, default, range)
    return default unless @params.key?(name)

    raw = @params[name]
    value = raw.is_a?(String) && raw.match?(/\A-?\d+\z/) ? Integer(raw, 10) : nil
    if value.nil?
      errors << Error.new(name, "not_an_integer")
    elsif !range.cover?(value)
      errors << Error.new(name, "out_of_range")
    end
    value
  end

  def inclusion(name)
    return unless @params.key?(name)

    value = @params[name]
    errors << Error.new(name, "inclusion") unless value.is_a?(String) && yield(value)
  end
end
