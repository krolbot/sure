require "test_helper"

class Assistant::Function::UpdateBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @category = categories(:food_and_drink)
  end

  test "updates monthly totals and category allocations" do
    result = Assistant::Function::UpdateBudget.new(@user).call(
      "month" => Date.current.strftime("%Y-%m"),
      "budgeted_spending" => 2500,
      "expected_income" => 4000,
      "category_allocations" => [
        { "category_id" => @category.id, "budgeted_spending" => 600 }
      ]
    )

    assert_equal true, result[:success]
    budget = @family.budgets.find(result.dig(:budget, :id))
    assert_equal 2500, budget.budgeted_spending
    assert_equal 4000, budget.expected_income
    assert_equal 600, budget.budget_categories.find_by!(category: @category).budgeted_spending
  end

  test "get_budget exposes category ids used by update_budget" do
    payload = Assistant::Function::GetBudget.new(@user).call
    categories = payload[:months].first[:categories]
    flattened = categories.flat_map { |category| [ category ] + category[:subcategories] }

    assert_includes flattened.pluck(:category_id), @category.id
  end

  test "rejects another family's category" do
    foreign = families(:empty).categories.create!(name: "Foreign", color: "#e99537", lucide_icon: "tag")

    result = Assistant::Function::UpdateBudget.new(@user).call(
      "month" => Date.current.strftime("%Y-%m"),
      "category_allocations" => [ { "category_id" => foreign.id, "budgeted_spending" => 100 } ]
    )

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  test "uses the named month for a custom family month start" do
    @family.update!(month_start_day: 15)

    result = Assistant::Function::UpdateBudget.new(@user).call(
      "month" => "2026-08",
      "budgeted_spending" => 1000
    )

    assert_equal true, result[:success]
    assert_equal Date.new(2026, 8, 15), @family.budgets.find(result.dig(:budget, :id)).start_date
  end
end
