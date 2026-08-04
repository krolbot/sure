class Assistant::Function::UpdateBudget < Assistant::Function
  class << self
    def name = "update_budget"

    def description
      "Creates or updates a monthly budget total, expected income, and per-category allocations. Use get_budget and get_categories first."
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "month" ],
      properties: {
        month: { type: "string", description: "Budget month in YYYY-MM or MMM-YYYY format" },
        budgeted_spending: { type: "number", minimum: 0, description: "Total spending budget" },
        expected_income: { type: "number", minimum: 0, description: "Expected income" },
        category_allocations: {
          type: "array",
          description: "Category limits to set",
          items: {
            type: "object",
            properties: {
              category_id: { type: "string" },
              budgeted_spending: { type: "number", minimum: 0 }
            },
            required: %w[category_id budgeted_spending],
            additionalProperties: false
          }
        }
      }
    )
  end

  def call(params = {})
    changed = params.keys & %w[budgeted_spending expected_income category_allocations]
    return error("no_changes", "Provide a total, expected income, or category allocation.") if changed.empty?

    budget = Budget.find_or_bootstrap(family, start_date: parse_month(params["month"]), user: user)
    return error("invalid_month", "Month is outside Sure's supported budget range.") unless budget

    allocations = Array(params["category_allocations"])
    allocation_ids = allocations.map { |item| item["category_id"].to_s }.uniq
    categories = family.categories.where(id: allocation_ids).index_by { |category| category.id.to_s }
    missing = allocation_ids - categories.keys
    return error("invalid_category", "One or more category ids do not belong to the family.") if missing.any?

    Budget.transaction do
      attrs = {}
      attrs[:budgeted_spending] = non_negative_decimal(params["budgeted_spending"]) if params.key?("budgeted_spending")
      attrs[:expected_income] = non_negative_decimal(params["expected_income"]) if params.key?("expected_income")
      budget.update!(attrs) if attrs.any?

      allocations.each do |item|
        category = categories.fetch(item["category_id"].to_s)
        budget_category = budget.budget_categories.find_by!(category: category)
        budget_category.update_budgeted_spending!(non_negative_decimal(item["budgeted_spending"]))
      end
    end

    budget.reload
    {
      success: true,
      budget: {
        id: budget.id,
        month: budget.to_param,
        budgeted_spending: budget.budgeted_spending,
        expected_income: budget.expected_income,
        allocated_spending: budget.allocated_spending
      },
      message: "Budget for #{budget.to_param} updated."
    }
  rescue Date::Error, ArgumentError => e
    error("invalid_parameters", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def parse_month(raw)
      date = case raw.to_s
      when /\A\d{4}-\d{2}\z/
        Date.strptime(raw, "%Y-%m")
      when /\A[A-Za-z]{3}-\d{4}\z/
        Date.strptime(raw, "%b-%Y")
      else
        raise ArgumentError, "month must use YYYY-MM or MMM-YYYY format"
      end

      family.uses_custom_month_start? ? Date.new(date.year, date.month, family.month_start_day) : date.beginning_of_month
    end

    def non_negative_decimal(value)
      amount = BigDecimal(value.to_s)
      raise ArgumentError, "budget amounts must be finite and non-negative" unless amount.finite? && amount >= 0

      amount
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
